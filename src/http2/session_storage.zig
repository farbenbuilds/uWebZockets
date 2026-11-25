const std = @import("std");
const connection_module = @import("connection.zig");
const hpack = @import("hpack.zig");
const request_module = @import("../http/request.zig");
const Request = request_module.Request;

/// Checked layout and borrowed storage for a fixed number of HTTP/2 streams.
/// The caller owns the region and must keep it stable while a session borrows it.
pub fn session_storage(comptime max_streams: usize) type {
    if (max_streams == 0) @compileError("HTTP/2 server stream capacity must be positive");

    return struct {
        /// RFC 7541 4.1 per-entry overhead used to size dynamic-table metadata.
        const dynamic_entry_overhead = 32;

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
            /// Route-capture slots per stream beyond the inline arrays.
            route_param_extra_capacity: usize = 0,
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
            /// Flat per-stream route-capture name pointer slots.
            route_param_names: [][]const u8,
            /// Flat per-stream route-capture value pointer slots.
            route_param_values: [][]const u8,
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
            route_param_names: Span,
            route_param_values: Span,
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
            const route_param_slot_count = std.math.mul(
                usize,
                max_streams,
                capacities.route_param_extra_capacity,
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
            plan.route_param_names = try reserve(
                &cursor,
                route_param_slot_count,
                @sizeOf([]const u8),
                @alignOf([]const u8),
            );
            plan.route_param_values = try reserve(
                &cursor,
                route_param_slot_count,
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
                .route_param_names = carved_slice(
                    []const u8,
                    region,
                    prefix,
                    plan.route_param_names,
                ),
                .route_param_values = carved_slice(
                    []const u8,
                    region,
                    prefix,
                    plan.route_param_values,
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
                route_param_names: [max_streams * capacities.route_param_extra_capacity][]const u8 = undefined,
                route_param_values: [max_streams * capacities.route_param_extra_capacity][]const u8 = undefined,

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
                        .route_param_names = &self.route_param_names,
                        .route_param_values = &self.route_param_values,
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
    };
}
