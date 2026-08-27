const std = @import("std");
const xev = @import("xev");
const tcp_mod = @import("../core/tcp.zig");
const TcpConnection = tcp_mod.TcpConnection;

// zero-allocation http response wrapper.
// relies on tcp connection for stable memory buffers.
pub const Response = struct {
    conn: *TcpConnection,

    // sends a complete http response in one go using scatter-gather i/o.
    pub fn end(self: *Response, status: []const u8, body: []const u8) void {
        const headers = std.fmt.bufPrint(
            &self.conn.write_buffer,
            "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
            .{ status, body.len },
        ) catch |err| {
            std.debug.print("header buffer overflow: {}\n", .{err});
            return;
        };

        // libxev currently doesn't support writev. copy body if it fits!
        const total_len = headers.len + body.len;
        if (total_len <= self.conn.write_buffer.len) {
            @memcpy(self.conn.write_buffer[headers.len..total_len], body);
            self.conn.write_data(self.conn.write_buffer[0..total_len]);
        } else {
            std.debug.print("response too large for write buffer\n", .{});
        }
    }

    // sends an http response formatted as a chunk.
    pub fn write_chunk(self: *Response, chunk: []const u8) void {
        const chunked_encoder = @import("chunked.zig").chunked_encoder;
        chunked_encoder.send_chunk(self.conn, chunk);
    }
};
