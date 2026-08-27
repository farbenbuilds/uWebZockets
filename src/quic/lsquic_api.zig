const std = @import("std");
const c = @import("c"); // translated lsquic library
const QuicStream = @import("stream.zig").QuicStream;

// simple zero-allocation memory pool for quic streams.
const MAX_STREAMS = 1024;
var stream_pool: [MAX_STREAMS]QuicStream = undefined;
var active_streams: [MAX_STREAMS]bool = [_]bool{false} ** MAX_STREAMS;

// acquires a free stream from the pool.
fn acquire_stream(stream_ptr: *c.lsquic_stream, router: *const @import("../router/radix.zig").Router) ?*QuicStream {
    for (&active_streams, 0..) |*is_active, i| {
        if (!is_active.*) {
            is_active.* = true;
            stream_pool[i] = QuicStream.init(stream_ptr, router);
            // explicitly clear parser state (dod) to prevent dirty reads from recycled streams
            stream_pool[i].parser = .{};
            stream_pool[i].req = .{};
            return &stream_pool[i];
        }
    }
    return null; // pool exhausted
}

// releases a stream back to the pool.
fn release_stream(stream_obj: *QuicStream) void {
    const ptr_val = @intFromPtr(stream_obj);
    const pool_start = @intFromPtr(&stream_pool[0]);
    const index = (ptr_val - pool_start) / @sizeOf(QuicStream);
    if (index < MAX_STREAMS) {
        active_streams[index] = false;
    }
}

// callback invoked when a new quic connection is established
pub export fn on_new_conn(ea_ctx: ?*anyopaque, conn: ?*c.lsquic_conn) callconv(.c) ?*c.lsquic_conn_ctx {
    _ = conn;
    return @ptrCast(ea_ctx);
}

// callback invoked when a quic connection is closed
pub export fn on_conn_closed(conn: ?*c.lsquic_conn) callconv(.c) void {
    _ = conn;
}

// receive new stream from a quic connection
pub export fn on_new_stream(conn_ctx: ?*anyopaque, stream: ?*c.lsquic_stream) callconv(.c) ?*c.lsquic_stream_ctx {
    const engine: *@import("engine.zig").QuicEngine = @ptrCast(@alignCast(conn_ctx orelse return null));

    if (stream) |s| {
        // acquire a zero-allocation stream from the pool
        if (acquire_stream(s, engine.router)) |stream_obj| {
            _ = c.lsquic_stream_wantread(s, 1);
            return @ptrCast(stream_obj);
        }
        // if pool is full, we must close the stream
        _ = c.lsquic_stream_close(s);
    }

    return null;
}

// callback invoked when lsquic stream is ready to write
pub export fn on_write(stream: ?*c.lsquic_stream, stream_ctx: ?*c.lsquic_stream_ctx) callconv(.c) void {
    _ = stream;
    _ = stream_ctx;
    // this will be implemented later for pushing data
}

// callback invoked when lsquic extracts udp packet and decrypts tls
pub export fn on_read(stream: ?*c.lsquic_stream, stream_ctx: ?*c.lsquic_stream_ctx) callconv(.c) void {
    const stream_obj: *QuicStream = @ptrCast(@alignCast(stream_ctx orelse return));

    // zero-allocation static buffer for the hot path
    var buf: [8192]u8 = undefined;

    // read clean payload from the lsquic buffer
    const read_bytes = c.lsquic_stream_read(stream, &buf, buf.len);

    if (read_bytes > 0) {
        const clean_data = buf[0..@intCast(read_bytes)];
        stream_obj.on_data(clean_data);
    } else if (read_bytes == 0) {
        _ = c.lsquic_stream_close(stream);
    }
}

pub export fn on_close(stream: ?*c.lsquic_stream, stream_ctx: ?*c.lsquic_stream_ctx) callconv(.c) void {
    _ = stream;
    if (stream_ctx) |ctx| {
        const stream_obj: *QuicStream = @ptrCast(@alignCast(ctx));
        release_stream(stream_obj);
    }
}
