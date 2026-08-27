const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const zslay = @import("zslay");
const handshake = @import("handshake.zig");
const PubSubEngine = @import("pubsub.zig").PubSubEngine;
const deflate = @import("deflate.zig");

// a zero-allocation websocket connection wrapper.
// takes over the raw tcp stream after a successful http 101 upgrade.
pub const WebSocket = struct {
    conn: *TcpConnection,
    behavior: @import("../router/radix.zig").WsBehavior = .{},
    z_conn: zslay.Conn = undefined,
    tx_nodes: [4]zslay.Conn.FrameNode = undefined,

    // pointer to the central pub/sub engine
    pubsub: ?*PubSubEngine = null,

    // pointer to the shared compression engine
    compressor: ?*deflate.Compressor = null,

    // static buffer to hold compressed payload before framing (8kb is sufficient for real-time events)
    deflate_buffer: [8192]u8 = undefined,

    // flag indicating if the client supports permessage-deflate
    permessage_deflate: bool = false,

    // message assembly for fragmented websocket frames
    msg_buffer: std.ArrayListUnmanaged(u8) = .empty,
    current_opcode: ?zslay.Opcode = null,

    // static buffer for control frame payloads (max 125 bytes per RFC 6455)
    control_buffer: [125]u8 = undefined,

    // handles the protocol upgrade from http/1.1 to websocket.
    pub fn upgrade(self: *WebSocket, req: *const Request, res: *Response, behavior: @import("../router/radix.zig").WsBehavior) void {
        self.behavior = behavior;

        const ws_key = req.get_header("Sec-WebSocket-Key") orelse {
            res.end("400 Bad Request", "Missing Sec-WebSocket-Key") catch {};
            return;
        };

        var accept_token_buf: [28]u8 = undefined;
        const accept_token = handshake.compute_accept_token(ws_key, &accept_token_buf);

        if (accept_token.len == 0) {
            res.end("500 Internal Server Error", "Handshake failed") catch {};
            return;
        }

        if (req.get_header("Sec-WebSocket-Extensions")) |exts| {
            if (std.mem.indexOf(u8, exts, "permessage-deflate") != null) {
                self.permessage_deflate = true;
            }
        }

        const ext_header = if (self.permessage_deflate) "Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\n" else "";

        var header_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "{s}\r\n", .{ accept_token, ext_header }) catch {
            res.end("500 Internal Server Error", "Header too large") catch {};
            return;
        };

        // initialize zslay parser state
        self.z_conn = zslay.Conn.init(&self.tx_nodes);

        self.conn.write_data(headers);

        // context switch: hijack the tcp read callback.
        self.conn.protocol_state = .websocket;

        if (self.behavior.open) |cb| cb(self);
    }

    // helper to send a close frame
    pub fn send_close(self: *WebSocket, code: u16, reason: []const u8) void {
        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        const copy_len = @min(reason.len, 123);
        @memcpy(payload[2 .. 2 + copy_len], reason[0..copy_len]);
        self.send(payload[0 .. 2 + copy_len], .close);
    }

    // application-facing api to send data back to the client.
    pub fn send(self: *WebSocket, data: []const u8, opcode: zslay.Opcode) void {
        var payload_to_send = data;
        var is_compressed = false;

        // compress payload if client supports it, data is not empty, and compressor is available
        if (self.permessage_deflate and data.len > 0) {
            if (self.compressor) |comp| {
                if (deflate.compress(comp.*, data, &self.deflate_buffer)) |compressed| {
                    payload_to_send = compressed;
                    is_compressed = true;
                } else |_| {
                    // if compression fails (e.g. buffer too small), fallback to sending plaintext
                }
            }
        }

        var frame_header: [14]u8 = undefined;

        const header_struct = zslay.FrameHeader{
            .payload_len = if (payload_to_send.len < 126) @intCast(payload_to_send.len) else if (payload_to_send.len <= 65535) 126 else 127,
            .mask = false,
            .opcode = @intCast(@intFromEnum(opcode)),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = is_compressed,
            .fin = true,
        };

        const header_len = zslay.encode_header(&frame_header, header_struct, payload_to_send.len, null) catch return;

        // allocate dynamic buffer for sending to avoid dropping large frames
        const total_len = header_len + payload_to_send.len;

        var packet = std.heap.c_allocator.alloc(u8, total_len) catch {
            std.debug.print("OOM allocating send buffer\n", .{});
            return;
        };

        @memcpy(packet[0..header_len], frame_header[0..header_len]);
        @memcpy(packet[header_len..total_len], payload_to_send);

        // enqueue into tcp connection (write_data must handle dynamic slices and free them)
        self.conn.write_data_dynamic(packet);
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
                self.send_close(1002, "Protocol error");
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

                    const op: zslay.Opcode = @enumFromInt(dh.header.opcode);
                    const is_control = op.is_control();

                    // fast path: entire unfragmented message fits in this TCP chunk. No alloc!
                    const fast_path = !is_control and self.msg_buffer.items.len == 0 and self.z_conn.payload_bytes_processed == 0 and to_process == dh.extended_len and dh.header.fin;

                    if (is_control) {
                        const start = self.z_conn.payload_bytes_processed;
                        if (start + to_process <= self.control_buffer.len) {
                            @memcpy(self.control_buffer[start .. start + to_process], chunk);
                        }
                    } else if (!fast_path) {
                        self.msg_buffer.appendSlice(std.heap.c_allocator, chunk) catch {
                            self.send_close(1011, "Internal server error");
                            tcp.close_connection(self.conn);
                            return;
                        };
                    }

                    self.z_conn.payload_bytes_processed += to_process;

                    if (self.z_conn.payload_bytes_processed == dh.extended_len) {
                        if (is_control) {
                            const ctrl_payload = self.control_buffer[0..@min(dh.extended_len, 125)];
                            if (op == .ping) {
                                self.send(ctrl_payload, .pong);
                            } else if (op == .pong) {
                                // update heartbeat/time-to-live to prevent timeout
                            } else if (op == .close) {
                                if (dh.extended_len >= 2) {
                                    const code = std.mem.readInt(u16, ctrl_payload[0..2], .big);
                                    const reason = ctrl_payload[2..];
                                    self.send_close(code, reason);
                                } else {
                                    self.send(&.{}, .close);
                                }
                                if (self.behavior.close) |cb| cb(self);
                                tcp.close_connection(self.conn);
                                return;
                            }
                        } else {
                            if (op != .continuation) {
                                self.current_opcode = op;
                            }

                            if (dh.header.fin) {
                                const final_op = self.current_opcode orelse .text;
                                const full_msg = if (fast_path) chunk else self.msg_buffer.items;

                                if (final_op == .text and !std.unicode.utf8ValidateSlice(full_msg)) {
                                    self.send_close(1007, "Invalid UTF-8");
                                    tcp.close_connection(self.conn);
                                    return;
                                }

                                if (self.behavior.message) |cb| cb(self, full_msg, final_op);

                                if (!fast_path) {
                                    self.msg_buffer.clearRetainingCapacity();
                                }
                                self.current_opcode = null;
                            }
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
                        self.send(&.{}, .close);
                        if (self.behavior.close) |cb| cb(self);
                        tcp.close_connection(self.conn);
                        return;
                    } else if (op == .text or op == .binary or op == .continuation) {
                        if (op != .continuation) {
                            self.current_opcode = op;
                        }
                        if (dh.header.fin) {
                            const final_op = self.current_opcode orelse .text;
                            if (self.behavior.message) |cb| cb(self, self.msg_buffer.items, final_op);
                            self.msg_buffer.clearRetainingCapacity();
                            self.current_opcode = null;
                        }
                    }
                    self.z_conn.complete_frame();
                },
                else => unreachable,
            }
        }
    }

    pub fn deinit(self: *WebSocket) void {
        self.msg_buffer.deinit(std.heap.c_allocator);
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
