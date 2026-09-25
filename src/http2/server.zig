const std = @import("std");
const connection_module = @import("connection.zig");
const hpack = @import("hpack.zig");
const request_module = @import("../http/request.zig");
const Request = request_module.Request;

/// HTTP/2 error codes emitted by the bounded server session.
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    enhance_your_calm = 0xb,
};

/// Writes frame parts; must consume or copy every part before returning.
pub const WriteFn = *const fn (*anyopaque, []const []const u8) anyerror!void;
/// Delivers a session-owned request for one stream.
pub const RequestFn = *const fn (*anyopaque, *Request, u32) anyerror!void;
/// Handles one inbound WebSocket payload; returns whether it was consumed.
pub const WsDataFn = *const fn (*anyopaque, u32, []u8, bool) bool;
/// Reports that one stream slot closed with its HTTP/2 error code.
pub const StreamClosedFn = *const fn (*anyopaque, u32, u16) void;

/// Synchronous transport and request callbacks used by a server session.
///
/// `write_fn` must consume or copy every part before returning because frame
/// headers use stack storage. `error.WouldBlock` must consume no bytes so the
/// session can retry the frame. Stream DATA retries through the pending
/// response state, but control frames (SETTINGS/PING acknowledgements,
/// RST_STREAM, GOAWAY) are not buffered: a `WouldBlock` while sending one
/// closes the connection instead of growing an unbounded control queue.
/// `request_fn` receives a session-owned request that stays valid until the
/// corresponding stream slot is released.
pub const Callbacks = struct {
    context: *anyopaque,
    write_fn: WriteFn,
    request_fn: RequestFn,
    ws_data_fn: ?WsDataFn = null,
    stream_closed_fn: ?StreamClosedFn = null,
    /// Largest nonempty frame payload that can fit an otherwise empty transport.
    max_frame_payload: usize = connection_module.maximum_frame_size,
};

/// Returns an allocation-free HTTP/2 server session over caller-carved storage.
///
/// `max_streams` stays compile-time because the embedded connection state and
/// producer arrays are sized by it. Every byte matrix is carved from `Storage`,
/// so runtime capacities are planned once by `storage_bytes`/`carve_storage` or
/// `Bundle`. Call `reset` only after the value reaches its stable
/// connection-owned address because the HPACK table borrows the carved
/// dynamic-table slices.
pub fn server_session(comptime max_streams: usize) type {
    if (max_streams == 0) @compileError("HTTP/2 server stream capacity must be positive");

    return struct {
        const Self = @This();
        const Connection = connection_module.connection(max_streams);
        /// RFC 7541 4.1 per-entry overhead used to size dynamic-table metadata.
        const dynamic_entry_overhead = 32;
        const DiscardedHeaderAction = enum {
            ignore,
            refuse,
            stream_closed,
        };

        /// Runtime capacity configuration for one session's carved storage.
        pub const Capacities = struct {
            /// Largest cumulative header-block fragments per request.
            header_block_size: usize = 16 * 1024,
            /// Per-stream bytes for the request first line and header fields.
            request_header_size: usize = 16 * 1024,
            /// Per-stream bytes for one request body and one response body.
            body_size: usize = 16 * 1024,
            /// Per-stream bytes for one encoded response header block.
            response_header_size: usize = 4 * 1024,
            /// Response header metadata slots per session.
            response_header_count: usize = 32,
            /// Maximum decoded request header fields per header block.
            decoded_header_count: usize = 64,
            /// HPACK dynamic table bytes; zero disables dynamic indexing.
            dynamic_table_size: usize = 4096,
        };

        /// Borrowed typed storage for one session.
        ///
        /// The per-stream request first line, header bytes, header-overflow
        /// pointer slots, and body bytes are carved as fixed strides; the
        /// stride fields and `header_extra_capacity` template one stream's
        /// slices. `carve_storage` and `Bundle.storage` produce aligned,
        /// non-overlapping spans that the session borrows for its lifetime.
        pub const Storage = struct {
            /// Per-stream request metadata slots.
            requests: []Request,
            /// Flat per-stream request first-line and header bytes.
            request_storage: []u8,
            /// Flat per-stream request body bytes.
            body_storage: []u8,
            /// Flat per-stream encoded response header bytes.
            response_header_storage: []u8,
            /// Flat per-stream response body bytes.
            response_body_storage: []u8,
            /// Decoded request header metadata for one header block.
            decoded_headers: []hpack.Header,
            /// Decoded request header bytes for one header block.
            decoded_header_bytes: []u8,
            /// HPACK dynamic-table metadata slots.
            dynamic_entries: []hpack.DynamicEntry,
            /// HPACK dynamic-table packed name/value bytes.
            dynamic_bytes: []u8,
            /// Cumulative header-block fragment bytes for one request.
            header_block: []u8,
            /// Frame header and payload bytes for one inbound frame.
            frame_buffer: []u8,
            /// Response header metadata for one encoded response.
            response_fields: []hpack.Header,
            /// Encoded response header block bytes for one response.
            response_encode: []u8,
            /// Lowercased response field names for one encoded response.
            lowercase_names: []u8,
            /// Flat per-stream header-overflow name pointer slots.
            header_extra_names: [][]const u8,
            /// Flat per-stream header-overflow value pointer slots.
            header_extra_values: [][]const u8,
            /// Byte distance between consecutive request-header slabs.
            request_header_stride: usize,
            /// Byte distance between consecutive body slabs.
            body_stride: usize,
            /// Byte distance between consecutive response-header slabs.
            response_header_stride: usize,
            /// Header-overflow pointer slots per stream.
            header_extra_capacity: usize,
        };

        /// Alignment every carved region base must satisfy for `storage_bytes`
        /// to be the exact consumed size.
        pub const storage_alignment = @alignOf(Storage);

        /// Failures raised while binding caller-carved session storage.
        pub const SessionError = hpack.Error || error{
            InvalidHttp2Capacity,
            InvalidSessionStorage,
        };

        /// Aligned byte span inside a carved session region.
        const Span = struct {
            start: usize,
            end: usize,
        };

        /// Byte span of every carved sub-array plus the total region size.
        const StoragePlan = struct {
            requests: Span,
            request_storage: Span,
            body_storage: Span,
            response_body_storage: Span,
            response_header_storage: Span,
            decoded_headers: Span,
            decoded_header_bytes: Span,
            dynamic_entries: Span,
            dynamic_bytes: Span,
            header_block: Span,
            frame_buffer: Span,
            response_fields: Span,
            response_encode: Span,
            lowercase_names: Span,
            header_extra_names: Span,
            header_extra_values: Span,
            total: usize,
        };

        /// Metadata slots the RFC 7541 dynamic table needs for its byte limit.
        fn dynamic_entry_count(dynamic_table_size: usize) usize {
            return dynamic_table_size / dynamic_entry_overhead +
                @as(usize, @intFromBool(dynamic_table_size % dynamic_entry_overhead != 0));
        }

        /// Header-overflow pointer slots per stream beyond the inline arrays.
        fn header_extra_capacity_for(capacities: Capacities) usize {
            if (capacities.decoded_header_count <= request_module.max_headers) return 0;
            return capacities.decoded_header_count - request_module.max_headers;
        }

        /// Validates one capacity set; every rejection marks a configuration
        /// the session cannot represent or use.
        fn validate_capacities(capacities: Capacities) error{InvalidHttp2Capacity}!void {
            if (capacities.header_block_size == 0) return error.InvalidHttp2Capacity;
            if (capacities.request_header_size == 0) return error.InvalidHttp2Capacity;
            if (capacities.body_size == 0) return error.InvalidHttp2Capacity;
            if (capacities.response_header_size == 0) return error.InvalidHttp2Capacity;
            if (capacities.response_header_count == 0) return error.InvalidHttp2Capacity;
            if (capacities.decoded_header_count == 0) return error.InvalidHttp2Capacity;
        }

        /// Reserves `count` elements in a carved region; `element_bytes` is
        /// explicit so untyped byte ranges share checked arithmetic.
        fn reserve(
            cursor: *usize,
            count: usize,
            element_bytes: usize,
            alignment: usize,
        ) error{InvalidHttp2Capacity}!Span {
            const bytes = std.math.mul(usize, count, element_bytes) catch {
                return error.InvalidHttp2Capacity;
            };
            const remainder = cursor.* % alignment;
            const padding = if (remainder == 0) 0 else alignment - remainder;
            const start = std.math.add(usize, cursor.*, padding) catch {
                return error.InvalidHttp2Capacity;
            };
            const end = std.math.add(usize, start, bytes) catch return error.InvalidHttp2Capacity;
            cursor.* = end;
            return .{ .start = start, .end = end };
        }

        /// Plans the exact carve layout; `storage_bytes` and `carve_storage`
        /// both use this plan so region size and offsets cannot drift.
        fn plan_storage(capacities: Capacities) error{InvalidHttp2Capacity}!StoragePlan {
            try validate_capacities(capacities);
            const extra_capacity = header_extra_capacity_for(capacities);
            const extra_slot_count = std.math.mul(
                usize,
                max_streams,
                extra_capacity,
            ) catch return error.InvalidHttp2Capacity;

            var cursor: usize = 0;
            var plan: StoragePlan = undefined;
            plan.requests = try reserve(
                &cursor,
                max_streams,
                @sizeOf(Request),
                @alignOf(Request),
            );
            plan.request_storage = try reserve(
                &cursor,
                max_streams,
                capacities.request_header_size,
                1,
            );
            plan.body_storage = try reserve(&cursor, max_streams, capacities.body_size, 1);
            plan.response_body_storage = try reserve(
                &cursor,
                max_streams,
                capacities.body_size,
                1,
            );
            plan.response_header_storage = try reserve(
                &cursor,
                max_streams,
                capacities.response_header_size,
                1,
            );
            plan.decoded_headers = try reserve(
                &cursor,
                capacities.decoded_header_count,
                @sizeOf(hpack.Header),
                @alignOf(hpack.Header),
            );
            plan.decoded_header_bytes = try reserve(
                &cursor,
                capacities.request_header_size,
                1,
                1,
            );
            plan.dynamic_entries = try reserve(
                &cursor,
                dynamic_entry_count(capacities.dynamic_table_size),
                @sizeOf(hpack.DynamicEntry),
                @alignOf(hpack.DynamicEntry),
            );
            plan.dynamic_bytes = try reserve(&cursor, capacities.dynamic_table_size, 1, 1);
            plan.header_block = try reserve(&cursor, capacities.header_block_size, 1, 1);
            plan.frame_buffer = try reserve(
                &cursor,
                9 + connection_module.default_max_frame_size,
                1,
                1,
            );
            plan.response_fields = try reserve(
                &cursor,
                capacities.response_header_count,
                @sizeOf(hpack.Header),
                @alignOf(hpack.Header),
            );
            plan.response_encode = try reserve(&cursor, capacities.response_header_size, 1, 1);
            plan.lowercase_names = try reserve(&cursor, capacities.response_header_size, 1, 1);
            plan.header_extra_names = try reserve(
                &cursor,
                extra_slot_count,
                @sizeOf([]const u8),
                @alignOf([]const u8),
            );
            plan.header_extra_values = try reserve(
                &cursor,
                extra_slot_count,
                @sizeOf([]const u8),
                @alignOf([]const u8),
            );
            plan.total = cursor;
            return plan;
        }

        /// Total bytes required for `carve_storage`, with every sub-array aligned.
        pub fn storage_bytes(capacities: Capacities) error{InvalidHttp2Capacity}!usize {
            return (try plan_storage(capacities)).total;
        }

        /// Re-tags one planned byte span; `carve_storage` proved the pointer aligned.
        fn carved_slice(comptime T: type, region: []u8, prefix: usize, span: Span) []T {
            const bytes = region[prefix + span.start .. prefix + span.end];
            const aligned = @as([*]align(@alignOf(T)) u8, @alignCast(bytes.ptr));
            const pointer: [*]T = @ptrCast(aligned);
            return pointer[0 .. bytes.len / @sizeOf(T)];
        }

        /// Carves `region` into typed, aligned slices for `capacities`.
        ///
        /// The carved layout consumes exactly `storage_bytes` bytes from the
        /// first address in `region` that satisfies `storage_alignment`; a
        /// misaligned base therefore needs up to `storage_alignment - 1` extra
        /// bytes.
        pub fn carve_storage(
            region: []u8,
            capacities: Capacities,
        ) error{InvalidHttp2Capacity}!Storage {
            const plan = try plan_storage(capacities);
            const base = @intFromPtr(region.ptr);
            const padded = std.math.add(usize, base, storage_alignment - 1) catch {
                return error.InvalidHttp2Capacity;
            };
            const start = padded - (padded % storage_alignment);
            const prefix = start - base;
            if (prefix > region.len) return error.InvalidHttp2Capacity;
            if (plan.total > region.len - prefix) return error.InvalidHttp2Capacity;

            return .{
                .requests = carved_slice(Request, region, prefix, plan.requests),
                .request_storage = carved_slice(u8, region, prefix, plan.request_storage),
                .body_storage = carved_slice(u8, region, prefix, plan.body_storage),
                .response_header_storage = carved_slice(
                    u8,
                    region,
                    prefix,
                    plan.response_header_storage,
                ),
                .response_body_storage = carved_slice(
                    u8,
                    region,
                    prefix,
                    plan.response_body_storage,
                ),
                .decoded_headers = carved_slice(
                    hpack.Header,
                    region,
                    prefix,
                    plan.decoded_headers,
                ),
                .decoded_header_bytes = carved_slice(
                    u8,
                    region,
                    prefix,
                    plan.decoded_header_bytes,
                ),
                .dynamic_entries = carved_slice(
                    hpack.DynamicEntry,
                    region,
                    prefix,
                    plan.dynamic_entries,
                ),
                .dynamic_bytes = carved_slice(u8, region, prefix, plan.dynamic_bytes),
                .header_block = carved_slice(u8, region, prefix, plan.header_block),
                .frame_buffer = carved_slice(u8, region, prefix, plan.frame_buffer),
                .response_fields = carved_slice(
                    hpack.Header,
                    region,
                    prefix,
                    plan.response_fields,
                ),
                .response_encode = carved_slice(u8, region, prefix, plan.response_encode),
                .lowercase_names = carved_slice(u8, region, prefix, plan.lowercase_names),
                .header_extra_names = carved_slice(
                    []const u8,
                    region,
                    prefix,
                    plan.header_extra_names,
                ),
                .header_extra_values = carved_slice(
                    []const u8,
                    region,
                    prefix,
                    plan.header_extra_values,
                ),
                .request_header_stride = capacities.request_header_size,
                .body_stride = capacities.body_size,
                .response_header_stride = capacities.response_header_size,
                .header_extra_capacity = header_extra_capacity_for(capacities),
            };
        }

        /// Inline storage for tests and stack callers; `storage()` yields the slices.
        pub fn bundle(comptime capacities: Capacities) type {
            comptime {
                _ = storage_bytes(capacities) catch
                    @compileError("invalid HTTP/2 session capacities");
            }
            const extra_capacity = header_extra_capacity_for(capacities);
            const extra_slot_count = max_streams * extra_capacity;
            return struct {
                const BundleSelf = @This();

                requests: [max_streams]Request = undefined,
                request_storage: [max_streams * capacities.request_header_size]u8 = undefined,
                body_storage: [max_streams * capacities.body_size]u8 = undefined,
                response_header_storage: [max_streams * capacities.response_header_size]u8 = undefined,
                response_body_storage: [max_streams * capacities.body_size]u8 = undefined,
                decoded_headers: [capacities.decoded_header_count]hpack.Header = undefined,
                decoded_header_bytes: [capacities.request_header_size]u8 = undefined,
                dynamic_entries: [dynamic_entry_count(capacities.dynamic_table_size)]hpack.DynamicEntry = undefined,
                dynamic_bytes: [capacities.dynamic_table_size]u8 = undefined,
                header_block: [capacities.header_block_size]u8 = undefined,
                frame_buffer: [9 + connection_module.default_max_frame_size]u8 = undefined,
                response_fields: [capacities.response_header_count]hpack.Header = undefined,
                response_encode: [capacities.response_header_size]u8 = undefined,
                lowercase_names: [capacities.response_header_size]u8 = undefined,
                header_extra_names: [extra_slot_count][]const u8 = undefined,
                header_extra_values: [extra_slot_count][]const u8 = undefined,

                comptime {
                    // `storage_bytes` already rejected bad capacities at
                    // instantiation; this guards against field-layout drift.
                    if (@sizeOf(BundleSelf) < (storage_bytes(capacities) catch unreachable)) {
                        @compileError("HTTP/2 session bundle layout must cover carve_storage");
                    }
                }

                /// Borrows the bundle's inline arrays as session storage.
                pub fn storage(self: *BundleSelf) Storage {
                    return .{
                        .requests = &self.requests,
                        .request_storage = &self.request_storage,
                        .body_storage = &self.body_storage,
                        .response_header_storage = &self.response_header_storage,
                        .response_body_storage = &self.response_body_storage,
                        .decoded_headers = &self.decoded_headers,
                        .decoded_header_bytes = &self.decoded_header_bytes,
                        .dynamic_entries = &self.dynamic_entries,
                        .dynamic_bytes = &self.dynamic_bytes,
                        .header_block = &self.header_block,
                        .frame_buffer = &self.frame_buffer,
                        .response_fields = &self.response_fields,
                        .response_encode = &self.response_encode,
                        .lowercase_names = &self.lowercase_names,
                        .header_extra_names = &self.header_extra_names,
                        .header_extra_values = &self.header_extra_values,
                        .request_header_stride = capacities.request_header_size,
                        .body_stride = capacities.body_size,
                        .response_header_stride = capacities.response_header_size,
                        .header_extra_capacity = extra_capacity,
                    };
                }
            };
        }

        /// Inline storage for tests and stack callers.
        pub const Bundle = bundle;
        /// Default session capacity configuration.
        pub const default_capacities = Capacities{};

        connection: Connection = .{},
        dynamic_table: ?hpack.DynamicTable = null,

        requests: []Request = &.{},
        request_storage: []u8 = &.{},
        body_storage: []u8 = &.{},
        response_header_storage: []u8 = &.{},
        response_body_storage: []u8 = &.{},
        decoded_headers: []hpack.Header = &.{},
        decoded_header_bytes: []u8 = &.{},
        dynamic_entries: []hpack.DynamicEntry = &.{},
        dynamic_bytes: []u8 = &.{},
        header_block: []u8 = &.{},
        frame_buffer: []u8 = &.{},
        response_fields: []hpack.Header = &.{},
        response_encode: []u8 = &.{},
        lowercase_names: []u8 = &.{},
        header_extra_names: [][]const u8 = &.{},
        header_extra_values: [][]const u8 = &.{},
        request_header_stride: usize = 0,
        body_stride: usize = 0,
        response_header_stride: usize = 0,
        header_extra_capacity: usize = 0,

        request_storage_lengths: [max_streams]usize = .{0} ** max_streams,
        body_lengths: [max_streams]usize = .{0} ** max_streams,
        /// Runtime request-body ceiling applied by `ServerConfig.max_body_size`.
        /// The carved `body_stride` remains the hard upper bound.
        request_body_limit: usize = 0,
        pending_header_lengths: [max_streams]usize = .{0} ** max_streams,
        pending_body_lengths: [max_streams]usize = .{0} ** max_streams,
        pending_body_offsets: [max_streams]usize = .{0} ** max_streams,
        expected_content_lengths: [max_streams]?usize = .{null} ** max_streams,
        headers_ready: [max_streams]bool = .{false} ** max_streams,
        // Tracks whether the initial header block was seen, so a second HEADERS
        // section is treated as trailers instead of a fresh request.
        initial_seen: [max_streams]bool = .{false} ** max_streams,
        dispatched: [max_streams]bool = .{false} ** max_streams,
        callback_active: [max_streams]bool = .{false} ** max_streams,
        response_started: [max_streams]bool = .{false} ** max_streams,
        pending_header_ready: [max_streams]bool = .{false} ** max_streams,
        pending_response_active: [max_streams]bool = .{false} ** max_streams,
        pending_stream_end: [max_streams]bool = .{false} ** max_streams,
        stream_write_retry_required: [max_streams]bool = .{false} ** max_streams,

        header_block_length: usize = 0,
        header_stream_index: ?u16 = null,
        refused_header_stream_id: ?u32 = null,
        local_reset_header_stream_id: ?u32 = null,
        closed_header_stream_id: ?u32 = null,
        header_end_stream: bool = false,
        header_is_trailer: bool = false,

        frame_length: usize = 0,
        frame_target_length: usize = 9,
        settings_sent: bool = false,
        closed: bool = false,

        /// Binds caller-carved storage and arms every protocol field.
        pub fn init(storage: Storage) SessionError!Self {
            try validate_storage(storage);
            var session = Self{
                .requests = storage.requests,
                .request_storage = storage.request_storage,
                .body_storage = storage.body_storage,
                .response_header_storage = storage.response_header_storage,
                .response_body_storage = storage.response_body_storage,
                .decoded_headers = storage.decoded_headers,
                .decoded_header_bytes = storage.decoded_header_bytes,
                .dynamic_entries = storage.dynamic_entries,
                .dynamic_bytes = storage.dynamic_bytes,
                .header_block = storage.header_block,
                .frame_buffer = storage.frame_buffer,
                .response_fields = storage.response_fields,
                .response_encode = storage.response_encode,
                .lowercase_names = storage.lowercase_names,
                .header_extra_names = storage.header_extra_names,
                .header_extra_values = storage.header_extra_values,
                .request_header_stride = storage.request_header_stride,
                .body_stride = storage.body_stride,
                .response_header_stride = storage.response_header_stride,
                .header_extra_capacity = storage.header_extra_capacity,
            };
            try session.reset();
            return session;
        }

        /// Rejects storage whose slices cannot back every runtime capacity.
        fn validate_storage(storage: Storage) error{InvalidSessionStorage}!void {
            if (storage.requests.len != max_streams) return error.InvalidSessionStorage;
            if (storage.request_header_stride == 0) return error.InvalidSessionStorage;
            if (storage.body_stride == 0) return error.InvalidSessionStorage;
            if (storage.response_header_stride == 0) return error.InvalidSessionStorage;
            if (storage.request_header_stride > storage.request_storage.len / max_streams) {
                return error.InvalidSessionStorage;
            }
            if (storage.body_stride > storage.body_storage.len / max_streams) {
                return error.InvalidSessionStorage;
            }
            if (storage.body_stride > storage.response_body_storage.len / max_streams) {
                return error.InvalidSessionStorage;
            }
            if (storage.response_header_stride > storage.response_header_storage.len / max_streams) {
                return error.InvalidSessionStorage;
            }
            if (storage.header_extra_names.len % max_streams != 0) {
                return error.InvalidSessionStorage;
            }
            if (storage.header_extra_capacity != storage.header_extra_names.len / max_streams) {
                return error.InvalidSessionStorage;
            }
            if (storage.header_extra_names.len != storage.header_extra_values.len) {
                return error.InvalidSessionStorage;
            }
            if (storage.decoded_headers.len == 0) return error.InvalidSessionStorage;
            if (storage.decoded_header_bytes.len == 0) return error.InvalidSessionStorage;
            if (storage.header_block.len == 0) return error.InvalidSessionStorage;
            if (storage.frame_buffer.len < 9 + connection_module.default_max_frame_size) {
                return error.InvalidSessionStorage;
            }
            if (storage.response_fields.len == 0) return error.InvalidSessionStorage;
            if (storage.response_encode.len == 0) return error.InvalidSessionStorage;
            if (storage.lowercase_names.len == 0) return error.InvalidSessionStorage;
        }

        /// Reinitializes all protocol state at a stable memory address.
        pub fn reset(self: *Self) hpack.Error!void {
            self.connection = .{};
            self.dynamic_table = try hpack.DynamicTable.init(
                self.dynamic_entries,
                self.dynamic_bytes,
                self.dynamic_bytes.len,
            );
            self.header_block_length = 0;
            self.header_stream_index = null;
            self.refused_header_stream_id = null;
            self.local_reset_header_stream_id = null;
            self.closed_header_stream_id = null;
            self.header_end_stream = false;
            self.header_is_trailer = false;
            self.frame_length = 0;
            self.frame_target_length = 9;
            self.settings_sent = false;
            self.closed = false;
            @memset(&self.request_storage_lengths, 0);
            @memset(&self.body_lengths, 0);
            self.request_body_limit = self.body_stride;
            @memset(&self.pending_header_lengths, 0);
            @memset(&self.pending_body_lengths, 0);
            @memset(&self.pending_body_offsets, 0);
            @memset(&self.expected_content_lengths, null);
            @memset(&self.headers_ready, false);
            @memset(&self.initial_seen, false);
            @memset(&self.dispatched, false);
            @memset(&self.callback_active, false);
            @memset(&self.response_started, false);
            @memset(&self.pending_header_ready, false);
            @memset(&self.pending_response_active, false);
            @memset(&self.pending_stream_end, false);
            @memset(&self.stream_write_retry_required, false);
            for (self.requests) |*request| request.* = .{};
        }

        /// Incrementally consumes plaintext HTTP/2 bytes and emits output.
        ///
        /// Protocol violations generate GOAWAY or RST_STREAM internally. The
        /// error return is reserved for transport output failures or use before
        /// `reset`, allowing the listener to close when bytes cannot be queued.
        pub fn receive(self: *Self, input: []const u8, callbacks: Callbacks) !void {
            if (self.dynamic_table == null) return error.SessionNotInitialized;
            if (self.requests.len != max_streams) return error.SessionNotInitialized;
            if (self.closed) return error.ConnectionClosed;

            var offset: usize = 0;
            if (!self.connection.preface_complete()) {
                const consumed = self.connection.consume_preface(input) catch {
                    try self.send_goaway(.protocol_error, callbacks);
                    return;
                };
                offset += consumed;
                if (!self.connection.preface_complete()) return;
                try self.send_settings(callbacks);
            }

            while (offset < input.len and !self.closed) {
                const needed = self.frame_target_length - self.frame_length;
                const copied = @min(needed, input.len - offset);
                @memcpy(
                    self.frame_buffer[self.frame_length .. self.frame_length + copied],
                    input[offset .. offset + copied],
                );
                self.frame_length += copied;
                offset += copied;

                if (self.frame_length < self.frame_target_length) continue;
                if (self.frame_target_length == 9) {
                    const header = connection_module.FrameHeader.parse(
                        self.frame_buffer[0..9],
                    ) catch {
                        try self.send_goaway(.protocol_error, callbacks);
                        return;
                    };
                    if (header.payload_length > connection_module.default_max_frame_size) {
                        try self.send_goaway(.frame_size_error, callbacks);
                        return;
                    }
                    self.frame_target_length = 9 + header.payload_length;
                    if (self.frame_target_length != 9) continue;
                }

                try self.process_frame(
                    self.frame_buffer[0..self.frame_target_length],
                    callbacks,
                );
                self.frame_length = 0;
                self.frame_target_length = 9;
            }
        }

        /// Sends one complete response and closes the local stream side.
        pub fn send_response(
            self: *Self,
            stream_id: u32,
            status: []const u8,
            raw_headers: []const u8,
            body: []const u8,
            callbacks: Callbacks,
        ) !void {
            const index = self.connection.streams.find(stream_id) orelse
                return error.StreamClosed;
            if (self.response_started[index]) return error.ResponseAlreadyStarted;

            const code = parse_status(status) orelse return error.InvalidStatus;
            if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

            var content_length_buffer: [24]u8 = undefined;
            const field_count = try response_fields(
                raw_headers,
                body.len,
                !status_forbids_body(code),
                self.response_fields,
                self.lowercase_names,
                &content_length_buffer,
            );
            const block = try hpack.encode_response(
                code,
                self.response_fields[0..field_count],
                self.response_encode,
            );

            const suppress_body = std.mem.eql(u8, self.requests[index].method, "HEAD") or
                status_forbids_body(code);
            const transmitted_body = if (suppress_body) "" else body;
            if (transmitted_body.len > self.body_stride) {
                return error.ResponseBodyTooLarge;
            }
            try self.validate_response_headers(block.len, callbacks);
            if (transmitted_body.len != 0 and self.data_frame_capacity(callbacks) == 0) {
                return error.ResponseDataTooLarge;
            }
            @memcpy(self.response_header_bytes(index)[0..block.len], block);
            @memcpy(
                self.response_body_bytes(index)[0..transmitted_body.len],
                transmitted_body,
            );
            self.pending_header_lengths[index] = block.len;
            self.pending_body_lengths[index] = transmitted_body.len;
            self.pending_body_offsets[index] = 0;
            self.pending_header_ready[index] = true;
            self.pending_response_active[index] = true;
            self.response_started[index] = true;
            try self.flush_pending_stream(index, callbacks);
        }

        /// Retries every buffered response after transport capacity becomes available.
        pub fn flush_pending(self: *Self, callbacks: Callbacks) !void {
            for (0..max_streams) |index| {
                if (!self.pending_response_active[index] and
                    !self.pending_stream_end[index]) continue;
                try self.flush_pending_stream(@intCast(index), callbacks);
            }
        }

        /// Starts a streaming response without HTTP/1 chunk framing.
        pub fn begin_response(
            self: *Self,
            stream_id: u32,
            status: []const u8,
            raw_headers: []const u8,
            callbacks: Callbacks,
        ) !void {
            const index = self.connection.streams.find(stream_id) orelse
                return error.StreamClosed;
            if (self.response_started[index]) return error.ResponseAlreadyStarted;
            if (std.mem.eql(u8, self.requests[index].method, "HEAD")) {
                return error.BodyNotAllowed;
            }

            const code = parse_status(status) orelse return error.InvalidStatus;
            if (status_forbids_body(code)) return error.BodyNotAllowed;
            var content_length_buffer: [24]u8 = undefined;
            const field_count = try response_fields(
                raw_headers,
                0,
                false,
                self.response_fields,
                self.lowercase_names,
                &content_length_buffer,
            );
            const block = try hpack.encode_response(
                code,
                self.response_fields[0..field_count],
                self.response_encode,
            );
            try self.validate_response_headers(block.len, callbacks);
            try self.send_headers(stream_id, block, false, callbacks);
            self.response_started[index] = true;
            self.stream_write_retry_required[index] = false;
        }

        /// Writes one atomic streaming DATA frame within transport and flow credit.
        ///
        /// On error no payload bytes or flow credit are committed. Retry the same
        /// nonempty slice successfully before calling `finish_response`.
        pub fn write_response_data(
            self: *Self,
            stream_id: u32,
            bytes: []const u8,
            callbacks: Callbacks,
        ) !void {
            const index = self.connection.streams.find(stream_id) orelse
                return error.StreamClosed;
            if (!self.response_started[index]) return error.ResponseNotStarted;
            if (std.mem.eql(u8, self.requests[index].method, "HEAD")) {
                return error.BodyNotAllowed;
            }
            if (self.pending_stream_end[index]) return error.ResponseAlreadyFinished;
            self.send_data(index, stream_id, bytes, callbacks) catch |err| {
                if (bytes.len != 0) self.stream_write_retry_required[index] = true;
                return err;
            };
            if (bytes.len != 0) self.stream_write_retry_required[index] = false;
        }

        /// Ends a previously started streaming response.
        pub fn finish_response(
            self: *Self,
            stream_id: u32,
            callbacks: Callbacks,
        ) !void {
            const index = self.connection.streams.find(stream_id) orelse
                return error.StreamClosed;
            if (!self.response_started[index]) return error.ResponseNotStarted;
            if (self.stream_write_retry_required[index]) return error.ResponseWritePending;
            if (self.pending_stream_end[index]) {
                try self.flush_pending_stream(index, callbacks);
                return;
            }
            self.pending_stream_end[index] = true;
            try self.flush_pending_stream(index, callbacks);
        }

        /// Reports whether a fatal connection error has emitted GOAWAY.
        pub fn is_closed(self: *const Self) bool {
            return self.closed;
        }

        /// Terminates one active stream and invalidates its retained callback state.
        pub fn reset_stream(
            self: *Self,
            stream_id: u32,
            code: ErrorCode,
            callbacks: Callbacks,
        ) !void {
            if (self.connection.streams.find(stream_id) == null) return error.StreamClosed;
            try self.send_reset(stream_id, code, callbacks);
        }

        fn process_frame(self: *Self, frame: []const u8, callbacks: Callbacks) !void {
            const header = connection_module.FrameHeader.parse(frame[0..9]) catch {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            };
            if (!self.connection.peer_settings_seen and
                (header.frame_type != @intFromEnum(connection_module.FrameType.settings) or
                    header.flags & 0x1 != 0))
            {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            }

            const event = self.connection.receive_frame(frame) catch |err| {
                try self.handle_frame_error(header.stream_id, err, callbacks);
                return;
            };
            switch (event) {
                .ignored, .settings_ack, .ping_ack, .goaway => {},
                .settings => {
                    try self.send_empty_frame(.settings, 0x1, 0, callbacks);
                    try self.flush_pending(callbacks);
                },
                .window_update => |update| {
                    if (update.stream_index) |index| {
                        try self.flush_pending_stream(index, callbacks);
                    } else {
                        try self.flush_pending(callbacks);
                    }
                },
                .ping => |ping_data| try self.send_frame(.ping, 0x1, 0, &ping_data, callbacks),
                .stream_reset => |reset_event| {
                    self.notify_stream_closed(
                        reset_event.stream_id,
                        reset_event.stream_index,
                        callbacks,
                    );
                    self.clear_stream(reset_event.stream_index);
                },
                .headers => |headers| try self.receive_headers(headers, callbacks),
                .refused_headers => |headers| {
                    try self.receive_refused_headers(headers, callbacks);
                },
                .locally_reset_headers => |headers| {
                    try self.receive_locally_reset_headers(headers, callbacks);
                },
                .closed_headers => |headers| {
                    try self.receive_closed_headers(headers, callbacks);
                },
                .continuation => |continuation| {
                    try self.receive_continuation(continuation, callbacks);
                },
                .refused_continuation => |continuation| {
                    try self.receive_refused_continuation(continuation, callbacks);
                },
                .locally_reset_continuation => |continuation| {
                    try self.receive_locally_reset_continuation(continuation, callbacks);
                },
                .closed_continuation => |continuation| {
                    try self.receive_closed_continuation(continuation, callbacks);
                },
                .data => |data| {
                    try self.receive_data(header.payload_length, data, callbacks);
                },
                .discarded_data => |data| {
                    const increment = try self.connection.restore_connection_receive_credit(
                        data.flow_length,
                    );
                    if (increment != 0) try self.send_window_update(0, increment, callbacks);
                },
            }
        }

        fn receive_headers(
            self: *Self,
            event: connection_module.HeadersEvent,
            callbacks: Callbacks,
        ) !void {
            const is_trailer = self.initial_seen[event.stream_index];
            if (!is_trailer) {
                self.clear_stream(event.stream_index);
                self.initial_seen[event.stream_index] = true;
            }
            self.header_block_length = 0;
            self.header_stream_index = event.stream_index;
            self.header_end_stream = event.end_stream;
            self.header_is_trailer = is_trailer;
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_headers(event.stream_index, event.end_stream, callbacks);
        }

        fn receive_continuation(
            self: *Self,
            event: connection_module.HeadersContinuationEvent,
            callbacks: Callbacks,
        ) !void {
            const index = self.header_stream_index orelse {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            };
            if (index != event.stream_index) {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            }
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_headers(index, self.header_end_stream, callbacks);
        }

        fn receive_refused_headers(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            self.header_block_length = 0;
            self.header_stream_index = null;
            self.refused_header_stream_id = event.stream_id;
            self.header_end_stream = false;
            self.header_is_trailer = false;
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(event.stream_id, .refuse, callbacks);
        }

        fn receive_refused_continuation(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            const stream_id = self.refused_header_stream_id orelse {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            };
            if (stream_id != event.stream_id) {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            }
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(stream_id, .refuse, callbacks);
        }

        fn receive_locally_reset_headers(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            self.header_block_length = 0;
            self.header_stream_index = null;
            self.local_reset_header_stream_id = event.stream_id;
            self.header_end_stream = false;
            self.header_is_trailer = false;
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(event.stream_id, .ignore, callbacks);
        }

        fn receive_locally_reset_continuation(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            const stream_id = self.local_reset_header_stream_id orelse {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            };
            if (stream_id != event.stream_id) {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            }
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(stream_id, .ignore, callbacks);
        }

        fn receive_closed_headers(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            self.header_block_length = 0;
            self.header_stream_index = null;
            self.closed_header_stream_id = event.stream_id;
            self.header_end_stream = false;
            self.header_is_trailer = false;
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(event.stream_id, .stream_closed, callbacks);
        }

        fn receive_closed_continuation(
            self: *Self,
            event: connection_module.DiscardedHeadersEvent,
            callbacks: Callbacks,
        ) !void {
            const stream_id = self.closed_header_stream_id orelse {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            };
            if (stream_id != event.stream_id) {
                try self.send_goaway(.protocol_error, callbacks);
                return;
            }
            if (!try self.append_header_block(event.block, callbacks)) return;
            if (!event.end_headers) return;
            try self.complete_discarded_headers(stream_id, .stream_closed, callbacks);
        }

        fn append_header_block(
            self: *Self,
            fragment: []const u8,
            callbacks: Callbacks,
        ) !bool {
            if (fragment.len > self.header_block.len - self.header_block_length) {
                try self.send_goaway(.compression_error, callbacks);
                return false;
            }
            @memcpy(
                self.header_block[self.header_block_length .. self.header_block_length + fragment.len],
                fragment,
            );
            self.header_block_length += fragment.len;
            return true;
        }

        fn complete_headers(
            self: *Self,
            index: u16,
            end_stream: bool,
            callbacks: Callbacks,
        ) !void {
            const table = &(self.dynamic_table orelse return error.SessionNotInitialized);
            var decoder = hpack.Decoder.init(table, self.request_header_stride);
            if (self.header_is_trailer) {
                const fields = decoder.decode_fields(
                    self.header_block[0..self.header_block_length],
                    self.decoded_headers,
                    self.decoded_header_bytes,
                ) catch |err| {
                    self.finish_header_block();
                    switch (err) {
                        error.HeaderCapacityExceeded,
                        error.HeaderListTooLarge,
                        error.OutputTooSmall,
                        => try self.send_goaway(.enhance_your_calm, callbacks),
                        else => try self.send_goaway(.compression_error, callbacks),
                    }
                    return;
                };
                hpack.validate_trailers(fields) catch {
                    const stream_id = self.connection.streams.stream_ids[index];
                    self.finish_header_block();
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                };
                self.finish_header_block();
                if (!end_stream) {
                    const stream_id = self.connection.streams.stream_ids[index];
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
                if (!self.headers_ready[index]) {
                    // Trailers arrived without a completed initial request.
                    const stream_id = self.connection.streams.stream_ids[index];
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
                try self.dispatch(index, callbacks);
                const trailer_stream_id = self.connection.streams.stream_ids[index];
                if (trailer_stream_id != 0) {
                    try self.finish_remote(index, trailer_stream_id, callbacks);
                }
                return;
            }
            const decoded = decoder.decode_request(
                self.header_block[0..self.header_block_length],
                self.decoded_headers,
                self.decoded_header_bytes,
            ) catch |err| {
                self.finish_header_block();
                switch (err) {
                    error.HeaderCapacityExceeded,
                    error.HeaderListTooLarge,
                    error.OutputTooSmall,
                    => try self.send_goaway(.enhance_your_calm, callbacks),
                    error.EmptyHeaderName,
                    error.UppercaseHeaderName,
                    error.InvalidHeaderName,
                    error.InvalidHeaderValue,
                    error.InvalidPseudoHeader,
                    error.DuplicatePseudoHeader,
                    error.DuplicateHost,
                    error.AuthorityHostMismatch,
                    error.PseudoHeaderAfterRegular,
                    error.MissingMethod,
                    error.MissingScheme,
                    error.MissingPath,
                    error.MissingAuthority,
                    error.InvalidMethod,
                    error.InvalidScheme,
                    error.InvalidAuthority,
                    error.InvalidPath,
                    error.InvalidConnectPseudoHeaders,
                    error.InvalidExtendedConnectPseudoHeaders,
                    error.ConnectionSpecificHeader,
                    error.InvalidTe,
                    => {
                        const stream_id = self.connection.streams.stream_ids[index];
                        try self.send_reset(stream_id, .protocol_error, callbacks);
                    },
                    else => try self.send_goaway(.compression_error, callbacks),
                }
                return;
            };

            if (std.mem.eql(u8, decoded.method, "CONNECT") and decoded.protocol == null) {
                const stream_id = self.connection.streams.stream_ids[index];
                self.finish_header_block();
                try self.send_response(
                    stream_id,
                    "501 Not Implemented",
                    "Content-Type: text/plain\r\n",
                    "CONNECT is not supported",
                    callbacks,
                );
                if (end_stream and stream_id != 0) {
                    try self.finish_remote(index, stream_id, callbacks);
                }
                return;
            }

            self.copy_request(index, decoded) catch |err| {
                const stream_id = self.connection.streams.stream_ids[index];
                const code: ErrorCode = switch (err) {
                    error.InvalidContentLength,
                    error.ExtendedConnectDisabled,
                    error.UnsupportedConnect,
                    => .protocol_error,
                    else => .enhance_your_calm,
                };
                try self.send_reset(stream_id, code, callbacks);
                self.finish_header_block();
                return;
            };
            self.headers_ready[index] = true;
            self.finish_header_block();
            if (end_stream or decoded.protocol != null) try self.dispatch(index, callbacks);
            if (end_stream) {
                const stream_id = self.connection.streams.stream_ids[index];
                if (stream_id != 0) try self.finish_remote(index, stream_id, callbacks);
            }
        }

        fn complete_discarded_headers(
            self: *Self,
            stream_id: u32,
            action: DiscardedHeaderAction,
            callbacks: Callbacks,
        ) !void {
            const table = &(self.dynamic_table orelse return error.SessionNotInitialized);
            var decoder = hpack.Decoder.init(table, self.request_header_stride);
            _ = decoder.decode_fields(
                self.header_block[0..self.header_block_length],
                self.decoded_headers,
                self.decoded_header_bytes,
            ) catch |err| {
                self.finish_header_block();
                switch (err) {
                    error.HeaderCapacityExceeded,
                    error.HeaderListTooLarge,
                    error.OutputTooSmall,
                    => try self.send_goaway(.enhance_your_calm, callbacks),
                    else => try self.send_goaway(.compression_error, callbacks),
                }
                return;
            };
            self.finish_header_block();
            switch (action) {
                .ignore => {},
                .refuse => try self.send_reset(stream_id, .refused_stream, callbacks),
                .stream_closed => try self.send_reset(stream_id, .stream_closed, callbacks),
            }
        }

        fn receive_data(
            self: *Self,
            flow_length: u32,
            event: connection_module.DataEvent,
            callbacks: Callbacks,
        ) !void {
            const index = event.stream_index;
            const stream_id = self.connection.streams.stream_ids[index];
            if (!self.headers_ready[index] or (self.dispatched[index] and self.requests[index].protocol.len == 0)) {
                try self.send_reset(stream_id, .protocol_error, callbacks);
                return;
            }

            const increment = try self.connection.restore_receive_credit(index, flow_length);
            if (increment != 0) {
                try self.send_window_update(0, increment, callbacks);
                try self.send_window_update(stream_id, increment, callbacks);
            }
            if (self.dispatched[index] and self.requests[index].protocol.len > 0) {
                const ws_data_fn = callbacks.ws_data_fn orelse {
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                };
                if (!ws_data_fn(
                    callbacks.context,
                    stream_id,
                    @constCast(event.bytes),
                    event.end_stream,
                )) {
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
                if (event.end_stream) try self.finish_remote(index, stream_id, callbacks);
                return;
            }

            if (self.body_lengths[index] > self.request_body_limit or
                event.bytes.len > self.request_body_limit - self.body_lengths[index])
            {
                try self.send_reset(stream_id, .enhance_your_calm, callbacks);
                return;
            }
            if (event.bytes.len > self.body_stride - self.body_lengths[index]) {
                try self.send_reset(stream_id, .enhance_your_calm, callbacks);
                return;
            }
            if (self.expected_content_lengths[index]) |expected| {
                if (event.bytes.len > expected -| self.body_lengths[index]) {
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
            }
            @memcpy(
                self.body_bytes(index)[self.body_lengths[index] .. self.body_lengths[index] + event.bytes.len],
                event.bytes,
            );
            self.body_lengths[index] += event.bytes.len;
            if (event.end_stream) {
                try self.dispatch(index, callbacks);
                try self.finish_remote(index, stream_id, callbacks);
            }
        }

        fn dispatch(self: *Self, index: u16, callbacks: Callbacks) !void {
            if (self.dispatched[index]) return;
            const stream_id = self.connection.streams.stream_ids[index];
            // A released slot reports stream 0; never dispatch a stale stream.
            if (stream_id == 0) return;
            if (self.expected_content_lengths[index]) |expected| {
                if (expected != self.body_lengths[index]) {
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
            }
            self.dispatched[index] = true;
            self.requests[index].body = self.body_bytes(index)[0..self.body_lengths[index]];
            self.callback_active[index] = true;
            callbacks.request_fn(callbacks.context, &self.requests[index], stream_id) catch {
                self.callback_active[index] = false;
                if (self.connection.streams.find(stream_id) != null) {
                    try self.send_reset(stream_id, .internal_error, callbacks);
                }
                return;
            };
            self.callback_active[index] = false;
            if (self.connection.streams.find(stream_id) == null) self.clear_stream(index);
        }

        fn copy_request(self: *Self, index: u16, decoded: hpack.Request) !void {
            if (decoded.protocol != null and !self.connection.local_settings.enable_connect_protocol) {
                return error.ExtendedConnectDisabled;
            }
            const raw_target = decoded.path orelse return error.UnsupportedConnect;
            self.requests[index] = .{};
            const extra_start = @as(usize, index) * self.header_extra_capacity;
            self.requests[index].extra_header_names = self.header_extra_names[extra_start..][0..self.header_extra_capacity];
            self.requests[index].extra_header_values = self.header_extra_values[extra_start..][0..self.header_extra_capacity];
            self.request_storage_lengths[index] = 0;
            self.body_lengths[index] = 0;
            self.expected_content_lengths[index] = null;
            self.dispatched[index] = false;
            self.response_started[index] = false;

            self.requests[index].method = try self.copy_request_bytes(index, decoded.method);
            if (decoded.protocol) |protocol| {
                self.requests[index].protocol = try self.copy_request_bytes(index, protocol);
            }
            const target = try self.copy_request_bytes(index, raw_target);
            self.requests[index].target = target;
            const query_offset = std.mem.indexOfScalar(u8, target, '?');
            if (query_offset) |offset| {
                self.requests[index].path = target[0..offset];
                self.requests[index].query = target[offset + 1 ..];
            } else {
                self.requests[index].path = target;
            }

            var has_host = false;
            for (decoded.fields) |field| {
                const name = try self.copy_request_bytes(index, field.name);
                const value = try self.copy_request_bytes(index, field.value);
                self.requests[index].add_header(name, value) catch |err| switch (err) {
                    error.HeaderCapacityReached => return error.HeaderCapacityExceeded,
                };
                if (std.mem.eql(u8, field.name, "host")) has_host = true;
                if (std.mem.eql(u8, field.name, "content-length")) {
                    if (self.expected_content_lengths[index] != null) {
                        return error.InvalidContentLength;
                    }
                    const content_length = try parse_content_length(field.value);
                    if (content_length > self.request_body_limit) return error.RequestBodyTooLarge;
                    self.expected_content_lengths[index] = content_length;
                }
            }
            if (has_host or decoded.authority == null) return;
            const host_name = try self.copy_request_bytes(index, "host");
            const host_value = try self.copy_request_bytes(index, decoded.authority.?);
            self.requests[index].add_header(host_name, host_value) catch |err| switch (err) {
                error.HeaderCapacityReached => return error.HeaderCapacityExceeded,
            };
        }

        fn copy_request_bytes(self: *Self, index: u16, bytes: []const u8) ![]const u8 {
            const start = self.request_storage_lengths[index];
            const storage = self.request_bytes(index);
            if (bytes.len > storage.len - start) {
                return error.RequestStorageExceeded;
            }
            const end = start + bytes.len;
            @memcpy(storage[start..end], bytes);
            self.request_storage_lengths[index] = end;
            return storage[start..end];
        }

        fn send_settings(self: *Self, callbacks: Callbacks) !void {
            if (self.settings_sent) return;
            var payload: [24]u8 = undefined;
            write_setting(payload[0..6], 0x2, 0);
            write_setting(payload[6..12], 0x3, @intCast(max_streams));
            write_setting(
                payload[12..18],
                0x6,
                @intCast(@min(self.request_header_stride, std.math.maxInt(u32))),
            );
            write_setting(payload[18..24], 0x8, 1);
            try self.send_frame(.settings, 0, 0, &payload, callbacks);
            self.settings_sent = true;
        }

        fn send_headers(
            self: *Self,
            stream_id: u32,
            block: []const u8,
            end_stream: bool,
            callbacks: Callbacks,
        ) !void {
            try self.validate_response_headers(block.len, callbacks);
            const flags: u8 = 0x4 | @as(u8, @intFromBool(end_stream));
            try self.send_frame(.headers, flags, stream_id, block, callbacks);
        }

        fn validate_response_headers(
            self: *const Self,
            block_length: usize,
            callbacks: Callbacks,
        ) !void {
            if (block_length > self.response_header_stride) {
                return error.ResponseHeadersTooLarge;
            }
            if (block_length > self.connection.peer_settings.max_frame_size or
                block_length > callbacks.max_frame_payload)
            {
                return error.ResponseHeadersTooLarge;
            }
        }

        /// Largest DATA payload accepted by the peer and transport for this call.
        pub fn data_frame_capacity(self: *const Self, callbacks: Callbacks) usize {
            return @min(
                @as(usize, self.connection.peer_settings.max_frame_size),
                callbacks.max_frame_payload,
            );
        }

        fn send_data(
            self: *Self,
            index: u16,
            stream_id: u32,
            bytes: []const u8,
            callbacks: Callbacks,
        ) !void {
            if (bytes.len == 0) return;
            if (bytes.len > self.data_frame_capacity(callbacks)) {
                return error.ResponseDataTooLarge;
            }
            try self.send_data_frame(index, stream_id, bytes, 0, callbacks);
        }

        fn flush_pending_stream(
            self: *Self,
            index: u16,
            callbacks: Callbacks,
        ) !void {
            if (index >= max_streams) return;
            if (!self.pending_response_active[index] and !self.pending_stream_end[index]) {
                return;
            }
            if (!self.connection.streams.active[index]) {
                self.clear_pending_response(index);
                return;
            }
            const stream_id = self.connection.streams.stream_ids[index];
            if (self.pending_response_active[index] and self.pending_header_ready[index]) {
                const header_block = self.response_header_bytes(index)[0..self.pending_header_lengths[index]];
                const end_stream = self.pending_body_lengths[index] == 0;
                self.send_headers(stream_id, header_block, end_stream, callbacks) catch |err| {
                    if (err == error.WouldBlock) return;
                    return err;
                };
                self.pending_header_ready[index] = false;
                if (end_stream) {
                    self.clear_pending_response(index);
                    try self.finish_local(index, callbacks);
                    return;
                }
            }

            const frame_capacity = self.data_frame_capacity(callbacks);
            while (self.pending_response_active[index] and
                self.pending_body_offsets[index] < self.pending_body_lengths[index])
            {
                const connection_credit = self.connection.connection_send_window;
                const stream_credit = self.connection.streams.send_windows[index];
                const available_credit = @min(connection_credit, stream_credit);
                if (available_credit <= 0 or frame_capacity == 0) return;

                const offset = self.pending_body_offsets[index];
                const remaining = self.pending_body_lengths[index] - offset;
                const frame_size = @min(
                    remaining,
                    @min(
                        frame_capacity,
                        @as(usize, @intCast(available_credit)),
                    ),
                );
                const final = frame_size == remaining;
                const flags: u8 = @intFromBool(final);
                self.send_data_frame(
                    index,
                    stream_id,
                    self.response_body_bytes(index)[offset .. offset + frame_size],
                    flags,
                    callbacks,
                ) catch |err| {
                    if (err == error.WouldBlock) return;
                    return err;
                };
                self.pending_body_offsets[index] += frame_size;
                if (!final) continue;

                self.clear_pending_response(index);
                try self.finish_local(index, callbacks);
                return;
            }

            if (!self.pending_stream_end[index]) return;
            self.send_empty_frame(.data, 0x1, stream_id, callbacks) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };
            self.pending_stream_end[index] = false;
            try self.finish_local(index, callbacks);
        }

        fn send_data_frame(
            self: *Self,
            index: u16,
            stream_id: u32,
            bytes: []const u8,
            flags: u8,
            callbacks: Callbacks,
        ) !void {
            try self.connection.reserve_send_credit(index, bytes.len);
            self.send_frame(.data, flags, stream_id, bytes, callbacks) catch |err| {
                self.connection.refund_send_credit(index, bytes.len);
                return err;
            };
        }

        fn finish_local(self: *Self, index: u16, callbacks: Callbacks) !void {
            const stream_id = self.connection.streams.stream_ids[index];
            const released = try self.connection.close_local(index);
            if (!released) return;
            self.notify_stream_closed(stream_id, index, callbacks);
            if (!self.callback_active[index]) self.clear_stream(index);
        }

        fn finish_remote(
            self: *Self,
            index: u16,
            stream_id: u32,
            callbacks: Callbacks,
        ) !void {
            const active_index = self.connection.streams.find(stream_id) orelse return;
            if (active_index != index) return;
            const released = try self.connection.finish_remote(index);
            if (!released) return;
            self.notify_stream_closed(stream_id, index, callbacks);
            if (!self.callback_active[index]) self.clear_stream(index);
        }

        fn send_window_update(
            self: *Self,
            stream_id: u32,
            increment: u32,
            callbacks: Callbacks,
        ) !void {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, &payload, increment, .big);
            try self.send_frame(.window_update, 0, stream_id, &payload, callbacks);
        }

        fn send_reset(
            self: *Self,
            stream_id: u32,
            code: ErrorCode,
            callbacks: Callbacks,
        ) !void {
            // RST_STREAM on stream 0 is a connection error; refuse to emit it.
            if (stream_id == 0) return;
            if (self.connection.streams.find(stream_id)) |index| {
                self.notify_stream_closed(stream_id, index, callbacks);
                _ = self.connection.reset_local(index);
                self.clear_stream(index);
            } else {
                self.connection.record_local_reset(stream_id);
            }
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, &payload, @intFromEnum(code), .big);
            try self.send_frame(.rst_stream, 0, stream_id, &payload, callbacks);
        }

        fn send_goaway(self: *Self, code: ErrorCode, callbacks: Callbacks) !void {
            if (self.closed) return;
            self.closed = true;
            var payload: [8]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], self.connection.highest_peer_stream_id, .big);
            std.mem.writeInt(u32, payload[4..8], @intFromEnum(code), .big);
            try self.send_frame(.goaway, 0, 0, &payload, callbacks);
        }

        fn handle_frame_error(
            self: *Self,
            stream_id: u32,
            err: anyerror,
            callbacks: Callbacks,
        ) !void {
            switch (err) {
                error.IdleStream => try self.send_goaway(.protocol_error, callbacks),
                error.StreamCapacityReached => try self.send_reset(
                    stream_id,
                    .refused_stream,
                    callbacks,
                ),
                error.StreamClosed => try self.send_reset(stream_id, .stream_closed, callbacks),
                error.StreamFlowControlError => try self.send_reset(
                    stream_id,
                    .flow_control_error,
                    callbacks,
                ),
                error.StreamProtocolError => try self.send_reset(
                    stream_id,
                    .protocol_error,
                    callbacks,
                ),
                error.FlowControlError,
                error.ConnectionFlowControlError,
                => try self.send_goaway(.flow_control_error, callbacks),
                error.FrameTooLarge, error.InvalidFrameSize => {
                    try self.send_goaway(.frame_size_error, callbacks);
                },
                else => try self.send_goaway(.protocol_error, callbacks),
            }
        }

        fn send_empty_frame(
            self: *Self,
            frame_type: connection_module.FrameType,
            flags: u8,
            stream_id: u32,
            callbacks: Callbacks,
        ) !void {
            try self.send_frame(frame_type, flags, stream_id, "", callbacks);
        }

        fn send_frame(
            self: *Self,
            frame_type: connection_module.FrameType,
            flags: u8,
            stream_id: u32,
            payload: []const u8,
            callbacks: Callbacks,
        ) !void {
            _ = self;
            var frame_header: [9]u8 = undefined;
            try (connection_module.FrameHeader{
                .payload_length = @intCast(payload.len),
                .frame_type = @intFromEnum(frame_type),
                .flags = flags,
                .stream_id = stream_id,
            }).encode(&frame_header);
            try callbacks.write_fn(callbacks.context, &.{ &frame_header, payload });
        }

        fn clear_stream(self: *Self, index: u16) void {
            if (index >= max_streams) return;
            self.requests[index] = .{};
            self.request_storage_lengths[index] = 0;
            self.body_lengths[index] = 0;
            self.expected_content_lengths[index] = null;
            self.headers_ready[index] = false;
            self.initial_seen[index] = false;
            self.dispatched[index] = false;
            self.callback_active[index] = false;
            self.response_started[index] = false;
            self.stream_write_retry_required[index] = false;
            self.clear_pending_response(index);
            if (self.header_stream_index == index) {
                self.finish_header_block();
            }
        }

        fn clear_pending_response(self: *Self, index: u16) void {
            self.pending_header_lengths[index] = 0;
            self.pending_body_lengths[index] = 0;
            self.pending_body_offsets[index] = 0;
            self.pending_header_ready[index] = false;
            self.pending_response_active[index] = false;
            self.pending_stream_end[index] = false;
        }

        fn finish_header_block(self: *Self) void {
            self.header_stream_index = null;
            self.refused_header_stream_id = null;
            self.local_reset_header_stream_id = null;
            self.closed_header_stream_id = null;
            self.header_block_length = 0;
            self.header_end_stream = false;
            self.header_is_trailer = false;
        }

        fn notify_stream_closed(
            self: *Self,
            stream_id: u32,
            index: u16,
            callbacks: Callbacks,
        ) void {
            _ = self;
            const callback = callbacks.stream_closed_fn orelse return;
            callback(callbacks.context, stream_id, index);
        }

        fn request_bytes(self: *Self, index: u16) []u8 {
            const start = @as(usize, index) * self.request_header_stride;
            return self.request_storage[start .. start + self.request_header_stride];
        }

        fn body_bytes(self: *Self, index: u16) []u8 {
            const start = @as(usize, index) * self.body_stride;
            return self.body_storage[start .. start + self.body_stride];
        }

        fn response_header_bytes(self: *Self, index: u16) []u8 {
            const start = @as(usize, index) * self.response_header_stride;
            return self.response_header_storage[start .. start + self.response_header_stride];
        }

        fn response_body_bytes(self: *Self, index: u16) []u8 {
            const start = @as(usize, index) * self.body_stride;
            return self.response_body_storage[start .. start + self.body_stride];
        }
    };
}

fn write_setting(output: *[6]u8, identifier: u16, value: u32) void {
    std.mem.writeInt(u16, output[0..2], identifier, .big);
    std.mem.writeInt(u32, output[2..6], value, .big);
}

fn parse_status(status: []const u8) ?u16 {
    if (status.len < 3) return null;
    for (status[0..3]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    if (status.len > 3 and status[3] != ' ') return null;
    const code = std.fmt.parseInt(u16, status[0..3], 10) catch return null;
    if (code < 200 or code > 599) return null;
    return code;
}

fn status_forbids_body(code: u16) bool {
    return code == 204 or code == 205 or code == 304;
}

fn parse_content_length(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidContentLength;
    var result: usize = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidContentLength;
        result = std.math.mul(usize, result, 10) catch
            return error.InvalidContentLength;
        result = std.math.add(usize, result, byte - '0') catch
            return error.InvalidContentLength;
    }
    return result;
}

fn response_fields(
    raw_headers: []const u8,
    body_length: usize,
    include_content_length: bool,
    fields: []hpack.Header,
    lowercase_names: []u8,
    content_length_buffer: []u8,
) !usize {
    var field_count: usize = 0;
    var name_length: usize = 0;
    var has_content_length = false;
    var lines = std.mem.splitSequence(u8, raw_headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (field_count == fields.len) return error.ResponseHeaderCapacityExceeded;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidHeaders;
        if (colon == 0 or colon > lowercase_names.len - name_length) {
            return error.InvalidHeaders;
        }
        const name = lowercase_names[name_length .. name_length + colon];
        for (line[0..colon], name) |source, *destination| {
            destination.* = std.ascii.toLower(source);
        }
        name_length += colon;
        const forbidden = [_][]const u8{
            "connection",
            "keep-alive",
            "proxy-connection",
            "transfer-encoding",
            "upgrade",
            "te",
        };
        for (forbidden) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return error.InvalidHeaders;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, name, "content-length")) {
            if (has_content_length or !include_content_length) return error.InvalidHeaders;
            const declared_length = parse_content_length(value) catch
                return error.InvalidHeaders;
            if (declared_length != body_length) return error.InvalidHeaders;
            has_content_length = true;
        }
        fields[field_count] = .{
            .name = name,
            .value = value,
        };
        field_count += 1;
    }

    if (!include_content_length or has_content_length) return field_count;
    if (field_count == fields.len) return error.ResponseHeaderCapacityExceeded;
    const value = try std.fmt.bufPrint(content_length_buffer, "{d}", .{body_length});
    fields[field_count] = .{ .name = "content-length", .value = value };
    return field_count + 1;
}
