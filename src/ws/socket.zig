const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const WsBehavior = @import("../router/radix.zig").WsBehavior;
const zslay = @import("zslay");
const handshake = @import("handshake.zig");
const mask = @import("mask.zig");
const utf8 = @import("utf8.zig");
const PubSubEngine = @import("pubsub.zig").PubSubEngine;

pub const WebSocket = struct {
    conn: *TcpConnection,
    pubsub: ?*PubSubEngine = null,
    behavior: WsBehavior = .{},
    z_conn: zslay.Conn = undefined,
    tx_nodes: [4]zslay.Conn.FrameNode = undefined,
    current_opcode: ?zslay.Opcode = null,
    message_len: usize = 0,
    utf8_state: utf8.State = .{},
    close_sent: bool = false,
    close_received: bool = false,
    close_notified: bool = false,
    initialized: bool = false,
    control_buffer: [125]u8 = undefined,

    pub fn upgrade(self: *WebSocket, req: *const Request, res: *Response, behavior: WsBehavior) void {
        self.behavior = behavior;

        if (!valid_limits(behavior, self.conn.ws_message_buffer.len)) {
            reject_upgrade(res, self.conn, "500 Internal Server Error", "Invalid WebSocket limits", false);
            return;
        }

        const client_key = handshake.validate_request(
            req.method,
            unique_header(req, "Connection"),
            unique_header(req, "Upgrade"),
            unique_header(req, "Sec-WebSocket-Version"),
            unique_header(req, "Sec-WebSocket-Key"),
        ) catch |err| {
            const unsupported_version = err == error.MissingVersion or err == error.UnsupportedVersion;
            const status = if (unsupported_version) "426 Upgrade Required" else "400 Bad Request";
            reject_upgrade(res, self.conn, status, "Invalid WebSocket handshake", unsupported_version);
            return;
        };

        if (behavior.upgrade) |authorize| {
            if (!authorize(req)) {
                reject_upgrade(res, self.conn, "403 Forbidden", "WebSocket upgrade rejected", false);
                return;
            }
        }

        self.z_conn = zslay.Conn.init(&self.tx_nodes, .{
            .role = .server,
            .max_frame_len = behavior.max_frame_size,
            .max_message_len = behavior.max_message_size,
        }) catch {
            reject_upgrade(res, self.conn, "500 Internal Server Error", "Invalid WebSocket limits", false);
            return;
        };

        var accept_buffer: [28]u8 = undefined;
        const accept_token = handshake.compute_accept_token(client_key, &accept_buffer);
        if (accept_token.len == 0) {
            reject_upgrade(res, self.conn, "500 Internal Server Error", "Handshake failed", false);
            return;
        }

        var response_buffer: [256]u8 = undefined;
        const response = std.fmt.bufPrint(
            &response_buffer,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept_token},
        ) catch {
            reject_upgrade(res, self.conn, "500 Internal Server Error", "Handshake failed", false);
            return;
        };

        self.conn.write_data(response) catch {
            tcp.close_connection(self.conn);
            return;
        };

        self.message_len = 0;
        self.current_opcode = null;
        self.utf8_state = .{};
        self.close_sent = false;
        self.close_received = false;
        self.close_notified = false;
        self.initialized = true;
        self.conn.protocol_state = .websocket;

        if (self.behavior.open) |callback| callback(self);
    }

    pub fn send_close(self: *WebSocket, code: u16, reason: []const u8) !void {
        if (self.close_sent) return;
        if (!valid_close_code(code)) return error.InvalidCloseCode;
        if (reason.len > 123) return error.ControlFrameTooLarge;
        if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        @memcpy(payload[2 .. 2 + reason.len], reason);
        try self.send(payload[0 .. 2 + reason.len], .close);
    }

    pub fn send(self: *WebSocket, data: []const u8, opcode: zslay.Opcode) !void {
        if (!self.initialized or self.conn.closing) {
            return error.ConnectionClosed;
        }
        if (self.close_received and opcode != .close) return error.ConnectionClosed;
        if (self.close_sent and opcode != .close) return error.ConnectionClosed;
        if (self.close_sent and opcode == .close) return;

        try validate_outgoing_payload(data, opcode);

        const node = try self.z_conn.prepare_frame(true, opcode, data, false, null);
        try self.conn.write_data_parts(&.{ node.header_buf[0..node.header_size], data });
        if (opcode == .close) {
            self.close_sent = true;
            tcp.close_after_flush(self.conn);
        }
    }

    pub fn buffered_amount(self: *const WebSocket) usize {
        return self.conn.buffered_amount();
    }

    pub fn on_data(self: *WebSocket, data: []u8) void {
        var offset: usize = 0;

        while (!self.conn.closing) {
            const action = self.z_conn.advance_rx() catch |err| {
                const code: u16 = if (err == error.PayloadTooLarge) 1009 else 1002;
                self.fail(code, if (code == 1009) "Message too large" else "Protocol error");
                return;
            };

            switch (action) {
                .need_header => {
                    if (offset == data.len) return;
                    const header_buffer = self.z_conn.get_header_buffer();
                    const copy_len = @min(header_buffer.len, data.len - offset);
                    @memcpy(header_buffer[0..copy_len], data[offset .. offset + copy_len]);
                    self.z_conn.advance_header_read(copy_len) catch {
                        self.fail(1002, "Protocol error");
                        return;
                    };
                    offset += copy_len;
                },
                .need_payload => {
                    if (offset == data.len) return;
                    const decoded = self.z_conn.decoded_header orelse {
                        self.fail(1002, "Protocol error");
                        return;
                    };
                    const remaining = decoded.extended_len - self.z_conn.payload_bytes_processed;
                    const available: u64 = @intCast(data.len - offset);
                    const process_len_u64 = @min(remaining, available);
                    const process_len: usize = @intCast(process_len_u64);
                    const chunk = data[offset .. offset + process_len];

                    if (decoded.masking_key) |masking_key| {
                        mask.apply(chunk, masking_key, self.z_conn.payload_bytes_processed);
                    }

                    const opcode: zslay.Opcode = @enumFromInt(decoded.header.opcode);
                    const message_opcode = if (opcode == .continuation)
                        self.current_opcode orelse {
                            self.fail(1002, "Protocol error");
                            return;
                        }
                    else
                        opcode;
                    if (opcode != .continuation and
                        !opcode.is_control() and
                        self.z_conn.payload_bytes_processed == 0)
                    {
                        self.utf8_state = .{};
                    }
                    if (message_opcode == .text) {
                        self.utf8_state = utf8.validate_chunk(self.utf8_state, chunk) orelse {
                            self.fail(1007, "Invalid UTF-8");
                            return;
                        };
                    }
                    const fast_path = !opcode.is_control() and
                        opcode != .continuation and
                        self.message_len == 0 and
                        self.z_conn.payload_bytes_processed == 0 and
                        process_len_u64 == decoded.extended_len and
                        decoded.header.fin;

                    if (opcode.is_control()) {
                        const start: usize = @intCast(self.z_conn.payload_bytes_processed);
                        @memcpy(self.control_buffer[start .. start + process_len], chunk);
                    } else if (!fast_path) {
                        if (!self.append_message(chunk)) {
                            self.fail(1009, "Message too large");
                            return;
                        }
                    }

                    self.z_conn.advance_payload_read(process_len_u64) catch {
                        self.fail(1002, "Protocol error");
                        return;
                    };
                    offset += process_len;

                    if (self.z_conn.payload_bytes_processed != decoded.extended_len) continue;
                    if (!self.complete_payload_frame(decoded, opcode, chunk, fast_path)) return;
                },
                .emit_frame => {
                    const decoded = self.z_conn.decoded_header orelse {
                        self.fail(1002, "Protocol error");
                        return;
                    };
                    const opcode: zslay.Opcode = @enumFromInt(decoded.header.opcode);
                    if (!self.complete_empty_frame(decoded, opcode)) return;
                },
                else => unreachable,
            }
        }
    }

    fn complete_payload_frame(
        self: *WebSocket,
        decoded: zslay.DecodedHeader,
        opcode: zslay.Opcode,
        final_chunk: []const u8,
        fast_path: bool,
    ) bool {
        if (opcode.is_control()) {
            const payload_len: usize = @intCast(decoded.extended_len);
            const payload = self.control_buffer[0..payload_len];
            if (!self.handle_control(opcode, payload)) return false;
            self.z_conn.complete_frame();
            return !self.conn.closing and !self.conn.close_when_drained;
        }

        if (opcode != .continuation) self.current_opcode = opcode;
        if (!decoded.header.fin) {
            self.z_conn.complete_frame();
            return true;
        }

        const message_opcode = self.current_opcode orelse {
            self.fail(1002, "Protocol error");
            return false;
        };
        const message = if (fast_path) final_chunk else self.conn.ws_message_buffer[0..self.message_len];
        if (message_opcode == .text and !utf8.is_complete(self.utf8_state)) {
            self.fail(1007, "Invalid UTF-8");
            return false;
        }

        if (self.behavior.message) |callback| callback(self, message, message_opcode);
        self.message_len = 0;
        self.current_opcode = null;
        self.utf8_state = .{};
        self.z_conn.complete_frame();
        return !self.conn.closing and !self.conn.close_when_drained;
    }

    fn complete_empty_frame(
        self: *WebSocket,
        decoded: zslay.DecodedHeader,
        opcode: zslay.Opcode,
    ) bool {
        if (opcode.is_control()) {
            if (!self.handle_control(opcode, "")) return false;
            self.z_conn.complete_frame();
            return !self.conn.closing and !self.conn.close_when_drained;
        }

        if (opcode != .continuation) {
            self.current_opcode = opcode;
            self.utf8_state = .{};
        }
        if (decoded.header.fin) {
            const message_opcode = self.current_opcode orelse {
                self.fail(1002, "Protocol error");
                return false;
            };
            const message = self.conn.ws_message_buffer[0..self.message_len];
            if (message_opcode == .text and !utf8.is_complete(self.utf8_state)) {
                self.fail(1007, "Invalid UTF-8");
                return false;
            }
            if (self.behavior.message) |callback| callback(self, message, message_opcode);
            self.message_len = 0;
            self.current_opcode = null;
            self.utf8_state = .{};
        }

        self.z_conn.complete_frame();
        return !self.conn.closing and !self.conn.close_when_drained;
    }

    fn append_message(self: *WebSocket, chunk: []const u8) bool {
        const limit: usize = @intCast(self.behavior.max_message_size);
        if (self.message_len > limit) return false;
        if (chunk.len > limit - self.message_len) return false;

        std.mem.copyForwards(
            u8,
            self.conn.ws_message_buffer[self.message_len .. self.message_len + chunk.len],
            chunk,
        );
        self.message_len += chunk.len;
        return true;
    }

    fn handle_control(self: *WebSocket, opcode: zslay.Opcode, payload: []const u8) bool {
        switch (opcode) {
            .ping => self.send(payload, .pong) catch {
                tcp.close_connection(self.conn);
                return false;
            },
            .pong => {},
            .close => {
                switch (close_payload_status(payload)) {
                    .valid => {},
                    .protocol_error => {
                        self.fail(1002, "Invalid close frame");
                        return false;
                    },
                    .invalid_utf8 => {
                        self.fail(1007, "Invalid UTF-8");
                        return false;
                    },
                }

                self.close_received = true;
                if (!self.close_sent) {
                    self.send(payload, .close) catch {
                        tcp.close_connection(self.conn);
                        return false;
                    };
                }
                self.notify_close();
                tcp.close_after_flush(self.conn);
                return false;
            },
            else => {
                self.fail(1002, "Protocol error");
                return false;
            },
        }
        return true;
    }

    fn fail(self: *WebSocket, code: u16, reason: []const u8) void {
        self.send_close(code, reason) catch {
            tcp.close_connection(self.conn);
            return;
        };
        self.notify_close();
        tcp.close_after_flush(self.conn);
    }

    fn notify_close(self: *WebSocket) void {
        if (self.close_notified) return;
        self.close_notified = true;
        if (self.behavior.close) |callback| callback(self);
    }

    pub fn notify_drain(self: *WebSocket) void {
        if (!self.initialized or self.conn.closing) return;
        if (self.behavior.drain) |callback| callback(self);
    }

    pub fn terminate(self: *WebSocket) void {
        tcp.close_connection(self.conn);
    }

    pub fn deinit(self: *WebSocket) void {
        if (!self.initialized) return;
        self.notify_close();
        if (self.pubsub) |engine| engine.unsubscribe_all(self);
        self.initialized = false;
        self.message_len = 0;
        self.utf8_state = .{};
    }

    pub fn subscribe(self: *WebSocket, topic: []const u8) !void {
        const engine = self.pubsub orelse return error.PubSubUnavailable;
        try engine.subscribe(self, topic);
    }

    pub fn unsubscribe(self: *WebSocket, topic: []const u8) bool {
        const engine = self.pubsub orelse return false;
        return engine.unsubscribe(self, topic);
    }

    pub fn publish(self: *WebSocket, topic: []const u8, message: []const u8, is_text: bool) usize {
        const engine = self.pubsub orelse return 0;
        return engine.publish(topic, message, is_text);
    }
};

fn valid_limits(behavior: WsBehavior, message_capacity: usize) bool {
    if (behavior.max_frame_size == 0 or behavior.max_message_size == 0) return false;
    if (behavior.max_frame_size > behavior.max_message_size) return false;
    return behavior.max_message_size <= @as(u64, @intCast(message_capacity));
}

fn validate_outgoing_payload(data: []const u8, opcode: zslay.Opcode) !void {
    switch (opcode) {
        .continuation => return error.InvalidOpcode,
        .text => if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8,
        .close => switch (close_payload_status(data)) {
            .valid => {},
            .protocol_error => return error.InvalidCloseFrame,
            .invalid_utf8 => return error.InvalidUtf8,
        },
        .ping, .pong => if (data.len > 125) return error.ControlFrameTooLarge,
        .binary => {},
        else => return error.InvalidOpcode,
    }
}

fn unique_header(req: *const Request, name: []const u8) ?[]const u8 {
    var value: ?[]const u8 = null;
    for (req.header_names[0..req.header_count], req.header_values[0..req.header_count]) |header_name, header_value| {
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        if (value != null) return null;
        value = header_value;
    }
    return value;
}

fn reject_upgrade(
    response: *Response,
    conn: *TcpConnection,
    status: []const u8,
    body: []const u8,
    advertise_version: bool,
) void {
    const headers = if (advertise_version)
        "Sec-WebSocket-Version: 13\r\nConnection: close\r\n"
    else
        "Connection: close\r\n";

    response.end_with_headers(status, headers, body) catch {
        tcp.close_connection(conn);
        return;
    };
    tcp.close_after_flush(conn);
}

const ClosePayloadStatus = enum {
    valid,
    protocol_error,
    invalid_utf8,
};

fn close_payload_status(payload: []const u8) ClosePayloadStatus {
    if (payload.len == 0) return .valid;
    if (payload.len == 1 or payload.len > 125) return .protocol_error;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!valid_close_code(code)) return .protocol_error;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return .invalid_utf8;
    return .valid;
}

fn valid_close_code(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

test "websocket validates outgoing application frames" {
    try validate_outgoing_payload("valid", .text);
    try validate_outgoing_payload("", .close);
    try std.testing.expectError(
        error.InvalidUtf8,
        validate_outgoing_payload(&.{ 0xc0, 0x80 }, .text),
    );
    try std.testing.expectError(
        error.InvalidOpcode,
        validate_outgoing_payload("", .continuation),
    );
    try std.testing.expectError(
        error.InvalidCloseFrame,
        validate_outgoing_payload(&.{0x03}, .close),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        validate_outgoing_payload(&.{ 0x03, 0xe8, 0xc0, 0x80 }, .close),
    );
    try std.testing.expectError(
        error.ControlFrameTooLarge,
        validate_outgoing_payload(&([_]u8{0} ** 126), .ping),
    );
}
