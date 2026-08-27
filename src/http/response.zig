const std = @import("std");
const xev = @import("xev");
const tcp_mod = @import("../core/tcp.zig");
const TcpConnection = tcp_mod.TcpConnection;
const quic_mod = @import("../quic/stream.zig");
const QuicStream = quic_mod.QuicStream;

pub const ConnectionTarget = union(enum) {
    tcp: *TcpConnection,
    quic: *QuicStream,
};

// zero-allocation http response wrapper.
// relies on tcp/quic connection for stable memory buffers.
pub const Response = struct {
    target: ConnectionTarget,

    // sends a complete http response in one go using scatter-gather i/o
    pub fn end(self: *Response, status: []const u8, body: []const u8) !void {
        switch (self.target) {
            .tcp => |conn| {
                var header_buf: [1024]u8 = undefined;
                const formatted_headers = std.fmt.bufPrint(
                    &header_buf,
                    "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
                    .{ status, body.len },
                ) catch {
                    std.debug.print("header buffer overflow\n", .{});
                    return error.BufferOverflow;
                };

                const total_len = formatted_headers.len + body.len;
                var packet = std.heap.c_allocator.alloc(u8, total_len) catch return error.BufferOverflow;

                @memcpy(packet[0..formatted_headers.len], formatted_headers);
                @memcpy(packet[formatted_headers.len..total_len], body);

                conn.write_data_dynamic(packet);
            },
            .quic => |stream| {
                stream.send_response(status, body);
            },
        }
    }

    // sends an http response formatted as a chunk
    pub fn write_chunk(self: *Response, chunk: []const u8) !void {
        switch (self.target) {
            .tcp => |conn| {
                const chunked = @import("chunked.zig");
                try chunked.send_chunk(conn, chunk);
            },
            .quic => {
                return error.NotSupportedOnQuic;
            },
        }
    }
};
