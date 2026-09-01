const std = @import("std");
const TcpConnection = @import("../core/tcp.zig").TcpConnection;

/// Queues one HTTP/1.1 chunk without retaining `data`.
pub fn send_chunk(conn: *TcpConnection, data: []const u8) !void {
    if (data.len == 0) return;

    var hex_buf: [16]u8 = undefined;
    const hex_len = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{data.len}) catch return error.BufferOverflow;
    try conn.write_data_parts(&.{ hex_len, data, "\r\n" });
}

/// Queues each non-empty HTTP/1.1 chunk without retaining caller slices.
pub fn send_chunks(conn: *TcpConnection, chunks: []const []const u8) !void {
    for (chunks) |data| {
        try send_chunk(conn, data);
    }
}

/// Queues the terminal zero-size chunk.
pub fn end(conn: *TcpConnection) !void {
    try conn.write_data("0\r\n\r\n");
}
