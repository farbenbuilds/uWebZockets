const std = @import("std");
const TcpConnection = @import("../core/tcp.zig").TcpConnection;

// sends a single chunk, zero allocation
pub fn send_chunk(conn: *TcpConnection, data: []const u8) !void {
    if (data.len == 0) return;

    var hex_buf: [16]u8 = undefined;
    // format length as hex with crlf
    const hex_len = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{data.len}) catch unreachable;

    const total_len = hex_len.len + data.len + 2;
    if (total_len <= conn.write_buffer.len) {
        @memcpy(conn.write_buffer[0..hex_len.len], hex_len);
        @memcpy(conn.write_buffer[hex_len.len .. hex_len.len + data.len], data);
        @memcpy(conn.write_buffer[hex_len.len + data.len .. total_len], "\r\n");
        conn.write_data(conn.write_buffer[0..total_len]);
    } else {
        std.debug.print("chunk too large for write buffer\n", .{});
        return error.BufferOverflow;
    }
}

// sends multiple chunks in one go to minimize system calls (data-oriented batching)
pub fn send_chunks(conn: *TcpConnection, chunks: []const []const u8) !void {
    var offset: usize = 0;

    for (chunks) |data| {
        if (data.len == 0) continue;

        var hex_buf: [16]u8 = undefined;
        const hex_len = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{data.len}) catch unreachable;

        const chunk_total = hex_len.len + data.len + 2;

        // flush buffer if full
        if (offset > 0 and offset + chunk_total > conn.write_buffer.len) {
            conn.write_data(conn.write_buffer[0..offset]);
            offset = 0;
        }

        if (chunk_total <= conn.write_buffer.len) {
            @memcpy(conn.write_buffer[offset .. offset + hex_len.len], hex_len);
            offset += hex_len.len;
            @memcpy(conn.write_buffer[offset .. offset + data.len], data);
            offset += data.len;
            @memcpy(conn.write_buffer[offset .. offset + 2], "\r\n");
            offset += 2;
        } else {
            std.debug.print("chunk too large for write buffer\n", .{});
            return error.BufferOverflow;
        }
    }

    if (offset > 0) {
        conn.write_data(conn.write_buffer[0..offset]);
    }
}

// ends chunked transfer by sending a zero-size chunk
pub fn end(conn: *TcpConnection) void {
    conn.write_data("0\r\n\r\n");
}
