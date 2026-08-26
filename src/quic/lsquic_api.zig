const std = @import("std");
const c = @import("c"); // translated lsquic library

// receive new stream from a quic connection
export fn on_new_stream(conn_ctx: ?*anyopaque, stream: ?*c.lsquic_stream) callconv(.C) ?*c.lsquic_stream_ctx {
    _ = conn_ctx;
    // register with engine to read from this stream
    c.lsquic_stream_wantread(stream, 1);
    return null;
}

// callback invoked when lsquic extracts udp packet and decrypts tls
export fn on_read(stream: ?*c.lsquic_stream, stream_ctx: ?*c.lsquic_stream_ctx) callconv(.C) void {
    _ = stream_ctx;

    // zero-allocation static buffer for the hot path
    var buf: [8192]u8 = undefined;

    // read clean payload from the lsquic buffer
    const read_bytes = c.lsquic_stream_read(stream, &buf, buf.len);

    if (read_bytes > 0) {
        const clean_data = buf[0..@intCast(read_bytes)];
        std.debug.print("received http/3 payload: {s}\n", .{clean_data});
        // push clean_data to the http parser here
    } else if (read_bytes == 0) {
        _ = c.lsquic_stream_close(stream);
    }
}
