const std = @import("std");
const xev = @import("xev");
const tcp_mod = @import("../core/tcp.zig");
const TcpConnection = tcp_mod.TcpConnection;

// zero-allocation http response wrapper.
// relies on tcp connection for stable memory buffers.
pub const Response = struct {
    conn: *TcpConnection,
};

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

    // construct the scatter-gather array (iovec) using connection's stable memory.
    self.conn.write_iov[0] = .{ .slice = headers };
    self.conn.write_iov[1] = .{ .slice = body };

    // fire and forget directly to the kernel via libxev!
    tcp_mod.writev_start(
        self.conn,
        self.conn.loop,
        self.conn.write_iov[0..2],
    );
}

// sends an http response formatted as a chunk.
pub fn write_chunk(self: *Response, chunk: []const u8) void {
    const header_chunk = std.fmt.bufPrint(
        &self.conn.write_buffer,
        "{x}\r\n",
        .{chunk.len},
    ) catch return;

    // construct the scatter-gather array for the chunk using connection's stable memory.
    self.conn.write_iov[0] = .{ .slice = header_chunk };
    self.conn.write_iov[1] = .{ .slice = chunk };
    self.conn.write_iov[2] = .{ .slice = "\r\n" };

    // fire and forget directly to the kernel via libxev!
    tcp_mod.writev_start(
        self.conn,
        self.conn.loop,
        self.conn.write_iov[0..3],
    );
}
