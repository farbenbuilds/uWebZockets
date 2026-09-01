const std = @import("std");
const connection_module = @import("connection.zig");
const hpack = @import("hpack.zig");
const Request = @import("../http/request.zig").Request;

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

/// Synchronous transport and request callbacks used by a server session.
///
/// `write_fn` must consume or copy every part before returning because frame
/// headers use stack storage. `error.WouldBlock` must consume no bytes so the
/// session can retry the frame. `request_fn` receives a session-owned request
/// that stays valid until the corresponding stream slot is released.
pub const Callbacks = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const []const u8) anyerror!void,
    request_fn: *const fn (*anyopaque, *Request, u32) anyerror!void,
    stream_closed_fn: ?*const fn (*anyopaque, u32, u16) void = null,
    /// Largest nonempty frame payload that can fit an otherwise empty transport.
    max_frame_payload: usize = connection_module.maximum_frame_size,
};

/// Returns an allocation-free HTTP/2 server session with fixed capacities.
///
/// The session uses one connection-wide HPACK table and contiguous per-stream
/// request/body slabs. Call `reset` only after the value reaches its stable
/// connection-owned address because the HPACK table borrows inline storage.
pub fn server_session(
    comptime max_streams: usize,
    comptime max_header_block_size: usize,
    comptime request_storage_capacity: usize,
    comptime body_capacity: usize,
) type {
    if (max_streams == 0) @compileError("HTTP/2 server stream capacity must be positive");
    if (max_header_block_size == 0) @compileError("HTTP/2 header block capacity must be positive");
    if (request_storage_capacity == 0) @compileError("HTTP/2 request storage must be positive");
    if (body_capacity == 0) @compileError("HTTP/2 body capacity must be positive");

    return struct {
        const Self = @This();
        const Connection = connection_module.connection(max_streams);
        const dynamic_table_size = 4096;
        const dynamic_entry_count = dynamic_table_size / 32;
        const max_decoded_headers = 64;
        const max_response_headers = 32;
        const max_response_header_bytes = 4096;
        const DiscardedHeaderAction = enum {
            ignore,
            refuse,
            stream_closed,
        };

        connection: Connection = .{},
        dynamic_table: ?hpack.DynamicTable = null,

        requests: [max_streams]Request = .{Request{}} ** max_streams,
        request_storage: [max_streams][request_storage_capacity]u8 = undefined,
        body_storage: [max_streams][body_capacity]u8 = undefined,
        response_header_storage: [max_streams][max_response_header_bytes]u8 = undefined,
        response_body_storage: [max_streams][body_capacity]u8 = undefined,
        request_storage_lengths: [max_streams]usize = .{0} ** max_streams,
        body_lengths: [max_streams]usize = .{0} ** max_streams,
        pending_header_lengths: [max_streams]usize = .{0} ** max_streams,
        pending_body_lengths: [max_streams]usize = .{0} ** max_streams,
        pending_body_offsets: [max_streams]usize = .{0} ** max_streams,
        expected_content_lengths: [max_streams]?usize = .{null} ** max_streams,
        headers_ready: [max_streams]bool = .{false} ** max_streams,
        dispatched: [max_streams]bool = .{false} ** max_streams,
        callback_active: [max_streams]bool = .{false} ** max_streams,
        response_started: [max_streams]bool = .{false} ** max_streams,
        pending_header_ready: [max_streams]bool = .{false} ** max_streams,
        pending_response_active: [max_streams]bool = .{false} ** max_streams,
        pending_stream_end: [max_streams]bool = .{false} ** max_streams,
        stream_write_retry_required: [max_streams]bool = .{false} ** max_streams,

        dynamic_entries: [dynamic_entry_count]hpack.DynamicEntry = undefined,
        dynamic_bytes: [dynamic_table_size]u8 = undefined,
        decoded_headers: [max_decoded_headers]hpack.Header = undefined,
        decoded_header_bytes: [request_storage_capacity]u8 = undefined,
        header_block: [max_header_block_size]u8 = undefined,
        header_block_length: usize = 0,
        header_stream_index: ?u16 = null,
        refused_header_stream_id: ?u32 = null,
        local_reset_header_stream_id: ?u32 = null,
        closed_header_stream_id: ?u32 = null,
        header_end_stream: bool = false,
        header_is_trailer: bool = false,

        frame_buffer: [9 + connection_module.default_max_frame_size]u8 = undefined,
        frame_length: usize = 0,
        frame_target_length: usize = 9,
        settings_sent: bool = false,
        closed: bool = false,

        /// Reinitializes all protocol state at a stable memory address.
        pub fn reset(self: *Self) !void {
            self.connection = .{};
            self.dynamic_table = try hpack.DynamicTable.init(
                &self.dynamic_entries,
                &self.dynamic_bytes,
                dynamic_table_size,
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
            @memset(&self.pending_header_lengths, 0);
            @memset(&self.pending_body_lengths, 0);
            @memset(&self.pending_body_offsets, 0);
            @memset(&self.expected_content_lengths, null);
            @memset(&self.headers_ready, false);
            @memset(&self.dispatched, false);
            @memset(&self.callback_active, false);
            @memset(&self.response_started, false);
            @memset(&self.pending_header_ready, false);
            @memset(&self.pending_response_active, false);
            @memset(&self.pending_stream_end, false);
            @memset(&self.stream_write_retry_required, false);
            for (&self.requests) |*request| request.* = .{};
        }

        /// Incrementally consumes plaintext HTTP/2 bytes and emits output.
        ///
        /// Protocol violations generate GOAWAY or RST_STREAM internally. The
        /// error return is reserved for transport output failures or use before
        /// `reset`, allowing the listener to close when bytes cannot be queued.
        pub fn receive(self: *Self, input: []const u8, callbacks: Callbacks) !void {
            if (self.dynamic_table == null) return error.SessionNotInitialized;
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

            var fields: [max_response_headers]hpack.Header = undefined;
            var lowercase_names: [1024]u8 = undefined;
            var content_length_buffer: [24]u8 = undefined;
            const field_count = try response_fields(
                raw_headers,
                body.len,
                !status_forbids_body(code),
                &fields,
                &lowercase_names,
                &content_length_buffer,
            );
            var encoded: [max_response_header_bytes]u8 = undefined;
            const block = try hpack.encode_response(code, fields[0..field_count], &encoded);

            const suppress_body = std.mem.eql(u8, self.requests[index].method, "HEAD") or
                status_forbids_body(code);
            const transmitted_body = if (suppress_body) "" else body;
            if (transmitted_body.len > self.response_body_storage[index].len) {
                return error.ResponseBodyTooLarge;
            }
            try self.validate_response_headers(block.len, callbacks);
            if (transmitted_body.len != 0 and self.data_frame_capacity(callbacks) == 0) {
                return error.ResponseDataTooLarge;
            }
            @memcpy(self.response_header_storage[index][0..block.len], block);
            @memcpy(
                self.response_body_storage[index][0..transmitted_body.len],
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
            var fields: [max_response_headers]hpack.Header = undefined;
            var lowercase_names: [1024]u8 = undefined;
            var unused_length: [24]u8 = undefined;
            const field_count = try response_fields(
                raw_headers,
                0,
                false,
                &fields,
                &lowercase_names,
                &unused_length,
            );
            var encoded: [max_response_header_bytes]u8 = undefined;
            const block = try hpack.encode_response(code, fields[0..field_count], &encoded);
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
            event: anytype,
            callbacks: Callbacks,
        ) !void {
            const is_trailer = self.headers_ready[event.stream_index];
            if (!is_trailer) self.clear_stream(event.stream_index);
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
            event: anytype,
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
            event: anytype,
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
            event: anytype,
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
            event: anytype,
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
            event: anytype,
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
            event: anytype,
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
            event: anytype,
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
            var decoder = hpack.Decoder.init(table, request_storage_capacity);
            if (self.header_is_trailer) {
                const fields = decoder.decode_fields(
                    self.header_block[0..self.header_block_length],
                    &self.decoded_headers,
                    &self.decoded_header_bytes,
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
                try self.dispatch(index, callbacks);
                return;
            }
            const decoded = decoder.decode_request(
                self.header_block[0..self.header_block_length],
                &self.decoded_headers,
                &self.decoded_header_bytes,
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
            if (end_stream) try self.dispatch(index, callbacks);
        }

        fn complete_discarded_headers(
            self: *Self,
            stream_id: u32,
            action: DiscardedHeaderAction,
            callbacks: Callbacks,
        ) !void {
            const table = &(self.dynamic_table orelse return error.SessionNotInitialized);
            var decoder = hpack.Decoder.init(table, request_storage_capacity);
            _ = decoder.decode_fields(
                self.header_block[0..self.header_block_length],
                &self.decoded_headers,
                &self.decoded_header_bytes,
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
            event: anytype,
            callbacks: Callbacks,
        ) !void {
            const index = event.stream_index;
            const stream_id = self.connection.streams.stream_ids[index];
            if (!self.headers_ready[index] or self.dispatched[index]) {
                try self.send_reset(stream_id, .protocol_error, callbacks);
                return;
            }

            const increment = try self.connection.restore_receive_credit(index, flow_length);
            if (increment != 0) {
                try self.send_window_update(0, increment, callbacks);
                try self.send_window_update(stream_id, increment, callbacks);
            }
            if (event.bytes.len > self.body_storage[index].len - self.body_lengths[index]) {
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
                self.body_storage[index][self.body_lengths[index] .. self.body_lengths[index] + event.bytes.len],
                event.bytes,
            );
            self.body_lengths[index] += event.bytes.len;
            if (event.end_stream) try self.dispatch(index, callbacks);
        }

        fn dispatch(self: *Self, index: u16, callbacks: Callbacks) !void {
            if (self.dispatched[index]) return;
            if (self.expected_content_lengths[index]) |expected| {
                if (expected != self.body_lengths[index]) {
                    const stream_id = self.connection.streams.stream_ids[index];
                    try self.send_reset(stream_id, .protocol_error, callbacks);
                    return;
                }
            }
            self.dispatched[index] = true;
            self.requests[index].body = self.body_storage[index][0..self.body_lengths[index]];
            const stream_id = self.connection.streams.stream_ids[index];
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
            if (decoded.protocol != null) return error.ExtendedConnectDisabled;
            const raw_target = decoded.path orelse return error.UnsupportedConnect;
            self.requests[index] = .{};
            self.request_storage_lengths[index] = 0;
            self.body_lengths[index] = 0;
            self.expected_content_lengths[index] = null;
            self.dispatched[index] = false;
            self.response_started[index] = false;

            self.requests[index].method = try self.copy_request_bytes(index, decoded.method);
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
                if (self.requests[index].header_count == self.requests[index].header_names.len) {
                    return error.HeaderCapacityExceeded;
                }
                const header_index = self.requests[index].header_count;
                self.requests[index].header_names[header_index] = try self.copy_request_bytes(
                    index,
                    field.name,
                );
                self.requests[index].header_values[header_index] = try self.copy_request_bytes(
                    index,
                    field.value,
                );
                self.requests[index].header_count += 1;
                if (std.mem.eql(u8, field.name, "host")) has_host = true;
                if (std.mem.eql(u8, field.name, "content-length")) {
                    if (self.expected_content_lengths[index] != null) {
                        return error.InvalidContentLength;
                    }
                    const content_length = try parse_content_length(field.value);
                    if (content_length > body_capacity) return error.RequestBodyTooLarge;
                    self.expected_content_lengths[index] = content_length;
                }
            }
            if (has_host or decoded.authority == null) return;
            if (self.requests[index].header_count == self.requests[index].header_names.len) {
                return error.HeaderCapacityExceeded;
            }
            const header_index = self.requests[index].header_count;
            self.requests[index].header_names[header_index] = try self.copy_request_bytes(
                index,
                "host",
            );
            self.requests[index].header_values[header_index] = try self.copy_request_bytes(
                index,
                decoded.authority.?,
            );
            self.requests[index].header_count += 1;
        }

        fn copy_request_bytes(self: *Self, index: u16, bytes: []const u8) ![]const u8 {
            const start = self.request_storage_lengths[index];
            if (bytes.len > self.request_storage[index].len - start) {
                return error.RequestStorageExceeded;
            }
            const end = start + bytes.len;
            @memcpy(self.request_storage[index][start..end], bytes);
            self.request_storage_lengths[index] = end;
            return self.request_storage[index][start..end];
        }

        fn send_settings(self: *Self, callbacks: Callbacks) !void {
            if (self.settings_sent) return;
            var payload: [18]u8 = undefined;
            write_setting(payload[0..6], 0x2, 0);
            write_setting(payload[6..12], 0x3, @intCast(max_streams));
            write_setting(
                payload[12..18],
                0x6,
                @intCast(@min(request_storage_capacity, std.math.maxInt(u32))),
            );
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
            if (block_length > self.connection.peer_settings.max_frame_size or
                block_length > callbacks.max_frame_payload)
            {
                return error.ResponseHeadersTooLarge;
            }
        }

        fn data_frame_capacity(self: *const Self, callbacks: Callbacks) usize {
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
                const header_block = self.response_header_storage[index][0..self.pending_header_lengths[index]];
                const end_stream = self.pending_body_lengths[index] == 0;
                self.send_headers(stream_id, header_block, end_stream, callbacks) catch |err| {
                    if (err == error.WouldBlock) return;
                    return err;
                };
                self.pending_header_ready[index] = false;
                if (end_stream) {
                    self.clear_pending_response(index);
                    try self.finish_local(index);
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
                    self.response_body_storage[index][offset .. offset + frame_size],
                    flags,
                    callbacks,
                ) catch |err| {
                    if (err == error.WouldBlock) return;
                    return err;
                };
                self.pending_body_offsets[index] += frame_size;
                if (!final) continue;

                self.clear_pending_response(index);
                try self.finish_local(index);
                return;
            }

            if (!self.pending_stream_end[index]) return;
            self.send_empty_frame(.data, 0x1, stream_id, callbacks) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };
            self.pending_stream_end[index] = false;
            try self.finish_local(index);
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

        fn finish_local(self: *Self, index: u16) !void {
            const released = try self.connection.close_local(index);
            if (released and !self.callback_active[index]) self.clear_stream(index);
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
