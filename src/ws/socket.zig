const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const zslay = @import("zslay");
const handshake = @import("handshake.zig");
const PubSubEngine = @import("pubsub.zig").PubSubEngine;

// a zero-allocation websocket connection wrapper.
// takes over the raw tcp stream after a successful http 101 upgrade.
pub const WebSocket = struct {
    conn: *TcpConnection,
    behavior: @import("../router/radix.zig").WsBehavior = .{},
    z_conn: zslay.Conn = undefined,
    tx_nodes: [4]zslay.Conn.FrameNode = undefined,

    // pointer to the central pub/sub engine
    pubsub: ?*PubSubEngine = null,

    // handles the protocol upgrade from http/1.1 to websocket.
    pub fn upgrade(self: *WebSocket, req: *const Request, res: *Response, behavior: @import("../router/radix.zig").WsBehavior) void {
        self.behavior = behavior;

        const ws_key = req.get_header("Sec-WebSocket-Key") orelse {
            res.end("400 Bad Request", "Missing Sec-WebSocket-Key");
            return;
        };

        var accept_token_buf: [28]u8 = undefined;
        const accept_token = handshake.compute_accept_token(ws_key, &accept_token_buf);

        if (accept_token.len == 0) {
            res.end("500 Internal Server Error", "Handshake failed");
            return;
        }

        var header_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept_token}) catch {
            res.end("500 Internal Server Error", "Header too large");
            return;
        };

        // initialize zslay parser state
        self.z_conn = zslay.Conn.init(&self.tx_nodes);

        self.conn.write_data(headers);

        // context switch: hijack the tcp read callback.
        self.conn.protocol_state = .websocket;

        if (self.behavior.open) |cb| cb(self);
    }

    // application-facing api to send data back to the client.
    pub fn send(self: *WebSocket, data: []const u8, opcode: zslay.Opcode) void {
        var frame_header: [14]u8 = undefined;

        const header_struct = zslay.FrameHeader{
            .payload_len = if (data.len < 126) @intCast(data.len) else if (data.len <= 65535) 126 else 127,
            .mask = false,
            .opcode = @intCast(@intFromEnum(opcode)),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        };

        const header_len = zslay.encode_header(&frame_header, header_struct, data.len, null) catch return;

        // libxev currently doesn't support writev. copy to buffer if it fits!
        const total_len = header_len + data.len;
        if (total_len <= self.conn.write_buffer.len) {
            @memcpy(self.conn.write_buffer[0..header_len], frame_header[0..header_len]);
            @memcpy(self.conn.write_buffer[header_len..total_len], data);
            self.conn.write_data(self.conn.write_buffer[0..total_len]);
        } else {
            std.debug.print("websocket frame too large for write buffer\n", .{});
        }
    }

    // processes raw byte stream when the connection is upgraded to websocket.
    // uses zslay to extract frames and perform in-place XOR unmasking.
    pub fn on_data(self: *WebSocket, data: []u8) void {
        var offset: usize = 0;

        // a tcp packet might contain multiple websocket frames,
        // or just a fragment of one.
        while (offset < data.len) {
            const action = self.z_conn.advance_rx() catch |err| {
                std.debug.print("protocol error: {}\n", .{err});
                // hacker sent malformed frame -> close immediately to protect server
                tcp.close_connection(self.conn);
                return;
            };

            switch (action) {
                .need_header => {
                    const buf = self.z_conn.get_header_buffer();
                    const available = data.len - offset;
                    const to_copy = @min(buf.len, available);

                    @memcpy(buf[0..to_copy], data[offset .. offset + to_copy]);
                    self.z_conn.advance_header_read(to_copy);
                    offset += to_copy;
                },
                .need_payload => {
                    const dh = self.z_conn.decoded_header.?;
                    const remaining_payload = dh.extended_len - self.z_conn.payload_bytes_processed;
                    const available = data.len - offset;
                    const to_process = @min(remaining_payload, available);

                    // chunk of payload unmasked in-place. zero-allocation.
                    const chunk = data[offset .. offset + to_process];

                    if (dh.masking_key) |mkey| {
                        zslay.mask(chunk, mkey, self.z_conn.payload_bytes_processed);
                    }

                    self.z_conn.payload_bytes_processed += to_process;

                    if (self.z_conn.payload_bytes_processed == dh.extended_len) {
                        const op: zslay.Opcode = @enumFromInt(dh.header.opcode);

                        if (op == .text or op == .binary) {
                            if (self.behavior.message) |cb| {
                                cb(self, chunk, op);
                            }
                        } else if (op == .ping) {
                            // rfc 6455: must respond with pong immediately, including ping payload
                            self.send(chunk, .pong);
                        } else if (op == .pong) {
                            // update heartbeat/time-to-live to prevent timeout
                        } else if (op == .close) {
                            if (self.behavior.close) |cb| cb(self);
                            tcp.close_connection(self.conn);
                            return;
                        }

                        self.z_conn.complete_frame();
                    }

                    offset += to_process;
                },
                .emit_frame => {
                    const dh = self.z_conn.decoded_header.?;
                    const op: zslay.Opcode = @enumFromInt(dh.header.opcode);

                    if (op == .ping) {
                        self.send(&.{}, .pong);
                    } else if (op == .close) {
                        if (self.behavior.close) |cb| cb(self);
                        tcp.close_connection(self.conn);
                        return;
                    }
                    self.z_conn.complete_frame();
                },
                else => unreachable,
            }
        }
    }

    // registers this client into a pub/sub topic
    pub fn subscribe(self: *WebSocket, topic: []const u8) !void {
        if (self.pubsub) |ps| {
            try ps.subscribe(self, topic);
        }
    }

    // broadcasts a message to a topic from this client
    pub fn publish(self: *WebSocket, topic: []const u8, message: []const u8, is_text: bool) void {
        if (self.pubsub) |ps| {
            ps.publish(topic, message, is_text);
        }
    }
};
