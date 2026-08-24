const std = @import("std");
const xev = @import("xev");
const TcpConnection = @import("../core/tcp.zig").TcpConnection;

// zero-allocation http response data.
pub const Response = struct {
    conn: *TcpConnection,
    header_buffer: [1024]u8 = undefined,
};

// sends a complete http response in one go.
pub fn end(res: *Response, status: []const u8, body: []const u8) void {
    const headers = std.fmt.bufPrint(&res.header_buffer, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{ status, body.len }) catch |err| {
        std.debug.print("header buffer overflow: {}\n", .{err});
        return;
    };

    // todo: scatter-gather i/o (writev) via libxev.
    _ = headers;

    std.debug.print("prepared response:\nHTTP/1.1 {s}...\n", .{status});
}

// sends an http response formatted as a chunk.
pub fn write_chunk(res: *Response, chunk: []const u8) void {
    const header_chunk = std.fmt.bufPrint(&res.header_buffer, "{x}\r\n", .{chunk.len}) catch return;

    // todo: pass header_chunk, chunk, and \r\n to libxev.
    _ = header_chunk;
}
