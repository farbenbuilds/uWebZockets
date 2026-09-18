const std = @import("std");
const tcp = @import("tcp.zig");
const TcpConnection = tcp.TcpConnection;
const zero_copy = @import("zero_copy.zig");

pub fn enqueue_plain_parts(conn: *TcpConnection, parts: []const []const u8) !void {
    if (conn.closing) return error.ConnectionClosed;

    var total_len: usize = 0;
    for (parts) |part| {
        if (part.len > conn.write_queue.len - total_len) return error.WouldBlock;
        total_len += part.len;
    }
    if (total_len > conn.write_queue.len - conn.write_len) return error.WouldBlock;
    if (total_len == 0) return;

    const tail = (conn.write_head + conn.write_len) % conn.write_queue.len;
    _ = tcp.copy_parts_to_ring(conn.write_queue, tail, parts);

    conn.write_len += total_len;
    if (conn.write_len >= conn.write_queue.len / 2) conn.was_backpressured = true;
    conn.start_write();
}

/// Copies scatter/gather plaintext parts atomically into the write path.
pub fn write_data_parts(conn: *TcpConnection, parts: []const []const u8) !void {
    if (conn.closing or conn.close_when_drained) return error.ConnectionClosed;
    if (conn.ssl != null) return conn.write_tls_parts(parts);
    return enqueue_plain_parts(conn, parts);
}

fn finish_file_body(conn: *TcpConnection) void {
    const file = conn.file_body orelse return;
    conn.file_body = null;
    conn.file_remaining = 0;
    file.close(conn.io);

    if (conn.file_close_after) {
        conn.file_close_after = false;
        conn.dispatch_suspended = false;
        tcp.close_after_flush(conn);
        return;
    }
    if (conn.dispatch_suspended) conn.resume_async_dispatch();
}

/// Pushes queued plaintext, then streams the file until the socket stalls.
///
/// The kernel path needs a nonblocking socket: a blocking `sendfile` sleeps
/// until its full count is transferred. io_uring sockets are blocking, so
/// the transfer opens a temporary nonblocking window and closes it before
/// any completion is queued. A tick transfers at most `file_tick_budget`
/// bytes so one large asset cannot starve the worker.
pub fn pump_file_body(conn: *TcpConnection) void {
    if (comptime !zero_copy.kernel_send_supported) return;
    const file = conn.file_body orelse return;
    if (conn.closing or conn.is_writing or conn.write_len != 0) return;

    const window = zero_copy.open_nonblocking_window(conn.socket.fd);
    if (window == .failed) {
        dribble_file_body(conn, file);
        return;
    }

    var budget = tcp.file_tick_budget;
    while (conn.file_remaining != 0 and budget != 0) {
        const chunk: usize = @intCast(@min(
            @min(conn.file_remaining, zero_copy.max_chunk),
            budget,
        ));
        const sent = zero_copy.send_file_chunk(
            conn.socket.fd,
            file.handle,
            &conn.file_offset,
            chunk,
        ) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                zero_copy.close_nonblocking_window(window, conn.socket.fd);
                tcp.close_connection(conn);
                return;
            },
        };
        // A short read below Content-Length would desynchronize framing.
        if (sent == 0) {
            zero_copy.close_nonblocking_window(window, conn.socket.fd);
            tcp.close_connection(conn);
            return;
        }
        conn.file_remaining -= sent;
        budget -= sent;
    }
    zero_copy.close_nonblocking_window(window, conn.socket.fd);

    if (conn.closing) return;
    if (conn.file_remaining == 0) {
        finish_file_body(conn);
        return;
    }
    dribble_file_body(conn, file);
}

/// Bounded copy fallback used while the kernel path cannot proceed.
///
/// Reuses the TLS staging buffer because a plaintext connection never
/// touches it, keeping the per-connection footprint unchanged.
fn dribble_file_body(conn: *TcpConnection, file: std.Io.File) void {
    const available = conn.write_queue.len - conn.write_len;
    if (available == 0) return;

    const wanted: usize = @intCast(@min(
        @min(conn.file_remaining, available),
        conn.tls_write_buffer.len,
    ));
    if (wanted == 0) return;

    const read = file.readPositionalAll(
        conn.io,
        conn.tls_write_buffer[0..wanted],
        conn.file_offset,
    ) catch {
        tcp.close_connection(conn);
        return;
    };
    if (read == 0) {
        tcp.close_connection(conn);
        return;
    }
    enqueue_plain_parts(conn, &.{conn.tls_write_buffer[0..read]}) catch {
        tcp.close_connection(conn);
        return;
    };
    conn.file_offset += read;
    conn.file_remaining -= read;
    if (conn.file_remaining == 0) finish_file_body(conn);
}
