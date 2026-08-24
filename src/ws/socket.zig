const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const zslay = @import("zslay");
const handshake = @import("handshake.zig");

// a zero-allocation websocket connection wrapper.
// takes over the raw tcp stream after a successful http 101 upgrade.
pub const WebSocket = struct {
    conn: *TcpConnection,
    // zslay rx_state and buffers would go here for parsing
};

// handles the protocol upgrade from http/1.1 to websocket.
pub fn upgrade(ws: *WebSocket, req: *const Request, res: *Response) void {
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

    tcp.write_start(ws.conn, ws.conn.loop, headers);

    // context switch: hijack the tcp read callback.
    // this would be enabled when tcpconnection supports protocol states.
    // ws.conn.protocol_state = .websocket;
}

// application-facing api to send data back to the client.
pub fn send(ws: *WebSocket, data: []const u8, opcode: zslay.Opcode) void {
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
    if (total_len <= ws.conn.write_buffer.len) {
        @memcpy(ws.conn.write_buffer[0..header_len], frame_header[0..header_len]);
        @memcpy(ws.conn.write_buffer[header_len..total_len], data);
        tcp.write_start(ws.conn, ws.conn.loop, ws.conn.write_buffer[0..total_len]);
    } else {
        std.debug.print("websocket frame too large for write buffer\n", .{});
    }
}
