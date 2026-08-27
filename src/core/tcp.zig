const std = @import("std");
const xev = @import("xev");
const c = @import("c"); // import boringssl
const Loop = @import("loop.zig").Loop;
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const Router = @import("../router/radix.zig").Router;
const handshake = @import("../crypto/handshake.zig");

/// determines the protocol of the socket.
pub const ProtocolState = enum {
    http,
    websocket,
    // tls or quic will be added in future phases.
};

/// represents an active tcp connection.
/// memory for this struct must be stable.
pub const TcpConnection = struct {
    read_buffer: [8192]u8 = undefined,
    write_buffer: [8192]u8 = undefined,
    tls_write_buffer: [8192]u8 = undefined,
    req: Request = .{},
    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,
    parser: HttpParser = .{},
    ws: WebSocket = undefined,
    socket: xev.TCP,
    loop: *xev.Loop = undefined,
    protocol_state: ProtocolState = .http,
    router: *const Router = undefined,
    pubsub: ?*@import("../ws/pubsub.zig").PubSubEngine = null,
    compressor: ?*@import("../ws/deflate.zig").Compressor = null,
    pool_ptr: ?*anyopaque = null,
    on_close_cb: ?*const fn (pool_ptr: *anyopaque, conn: *TcpConnection) void = null,
    last_active_ms: i64 = 0,
    io: std.Io = undefined,

    // backpressure queue
    pending_writes: std.ArrayListUnmanaged([]u8) = .empty,
    is_writing: bool = false,

    /// tls security state
    ssl: ?*c.SSL = null,
    is_tls_handshake_done: bool = false,

    /// called by server when accepting a new connection on an https port
    pub fn init_tls(self: *TcpConnection, ssl_ctx: *c.SSL_CTX) !void {
        // create ssl object specifically for this connection
        self.ssl = c.SSL_new(ssl_ctx) orelse return error.SslAllocationFailed;

        // create 2 memory bio pipes (read and write) entirely in ram
        const rbio = c.BIO_new(c.BIO_s_mem());
        const wbio = c.BIO_new(c.BIO_s_mem());
        if (rbio == null or wbio == null) return error.BioAllocationFailed;

        // attach bio pipes to ssl and set it to server mode
        c.SSL_set_bio(self.ssl, rbio, wbio);
        c.SSL_set_accept_state(self.ssl);
    }

    /// frees boringssl memory when connection closes
    pub fn deinit_tls(self: *TcpConnection) void {
        if (self.ssl) |ssl_ptr| {
            c.SSL_free(ssl_ptr); // ssl_free automatically cleans up rbio and wbio
            self.ssl = null;
        }
    }

    // injects raw data into boringssl and extracts clean data
    pub fn process_tls_data(self: *TcpConnection, ssl: *c.SSL, encrypted_data: []const u8) void {
        // pump encrypted bytes into input memory bio (rbio)
        const rbio = c.SSL_get_rbio(ssl);
        _ = c.BIO_write(rbio, encrypted_data.ptr, @intCast(encrypted_data.len));

        // activate ssl state machine (handshake or decrypt)
        if (!self.is_tls_handshake_done) {
            const status = handshake.step(ssl);

            // flush what boringssl wants to send to the client (e.g. server hello)
            self.flush_tls_out(ssl);

            switch (status) {
                .success => {
                    self.is_tls_handshake_done = true;
                    std.debug.print("tls 1.3 secure channel established!\n", .{});
                    // handshake is done, there might be application data (e.g. first http request)
                    // stuck in bio, so we fallthrough to the decryption loop below.
                },
                .want_read => return, // stop, wait for libxev to trigger on_read_complete again
                .want_write => return, // already flushed above, wait for network
                .failed => {
                    close_connection(self);
                    return;
                },
            }
        }

        // continuously pull clean bytes (plaintext) until pipe is empty
        var plain_buf: [8192]u8 = undefined;
        while (true) {
            const read_bytes = c.SSL_read(ssl, &plain_buf, plain_buf.len);
            if (read_bytes <= 0) {
                const err = c.SSL_get_error(ssl, read_bytes);
                if (err == c.SSL_ERROR_WANT_READ) break; // wait for tcp to receive more packets
                // if other error, connection should close, handled at a higher level
                break;
            }

            // send clean data into our router system
            self.route_decrypted_data(plain_buf[0..@intCast(read_bytes)]);
        }

        self.flush_tls_out(ssl);
    }

    // routes clean data to parser or websocket
    pub fn route_decrypted_data(self: *TcpConnection, data: []u8) void {
        switch (self.protocol_state) {
            .http => {
                _ = http_parser.consume(&self.parser, &self.req, data);

                if (self.parser.state == .done) {
                    var res = Response{ .target = .{ .tcp = self } };

                    if (self.router.match(self.req.path)) |route| {
                        if (route.route_type == .websocket) {
                            self.ws = WebSocket{ .conn = self, .pubsub = self.pubsub, .compressor = self.compressor };
                            self.ws.upgrade(&self.req, &res, route.ws_behavior.?);
                        } else if (route.http_handler) |handler| {
                            handler(&self.req, &res);
                        }
                    } else {
                        res.end("404 Not Found", "Route not found") catch {};
                    }
                }
            },
            .websocket => {
                // raw binary bytes are passed directly to the zslay decoder.
                self.ws.on_data(data);
            },
        }
    }

    // extracts encrypted bytes from wbio and pushes out to libxev to send
    pub fn flush_tls_out(self: *TcpConnection, ssl: *c.SSL) void {
        const wbio = c.SSL_get_wbio(ssl);

        const pending = c.BIO_ctrl_pending(wbio);
        if (pending <= 0) return;

        const read_bytes = c.BIO_read(wbio, &self.tls_write_buffer, @intCast(self.tls_write_buffer.len));
        if (read_bytes > 0) {
            const encrypted_chunk = self.tls_write_buffer[0..@intCast(read_bytes)];

            // allocate and copy for the queue
            if (std.heap.c_allocator.alloc(u8, encrypted_chunk.len)) |copy| {
                @memcpy(copy, encrypted_chunk);
                self.queue_or_write(copy);
            } else |_| {}
        }
    }

    // internal helper to queue or write dynamic buffers
    fn queue_or_write(self: *TcpConnection, data: []u8) void {
        if (self.is_writing) {
            self.pending_writes.append(std.heap.c_allocator, data) catch {
                std.heap.c_allocator.free(data);
                close_connection(self);
            };
            return;
        }

        self.is_writing = true;
        self.socket.write(
            self.loop,
            &self.write_completion,
            .{ .slice = data },
            TcpConnection,
            self,
            on_write_complete, // use unified completion
        );
    }

    // unified data write interface
    pub fn write_data(self: *TcpConnection, data: []const u8) void {
        if (self.ssl) |ssl| {
            const ret = c.SSL_write(ssl, data.ptr, @intCast(data.len));
            if (ret > 0) {
                self.flush_tls_out(ssl);
            } else {
                std.debug.print("ssl_write error\n", .{});
            }
        } else {
            if (std.heap.c_allocator.alloc(u8, data.len)) |copy| {
                @memcpy(copy, data);
                self.queue_or_write(copy);
            } else |_| {}
        }
    }

    // directly accepts a dynamically allocated buffer to send, taking ownership
    pub fn write_data_dynamic(self: *TcpConnection, data: []u8) void {
        if (self.ssl) |ssl| {
            const ret = c.SSL_write(ssl, data.ptr, @intCast(data.len));
            if (ret > 0) {
                self.flush_tls_out(ssl);
            } else {
                std.debug.print("ssl_write error\n", .{});
            }
            std.heap.c_allocator.free(data);
        } else {
            self.queue_or_write(data);
        }
    }
};

// initiates an asynchronous read operation.
pub fn read_start(conn: *TcpConnection, loop: *Loop) void {
    conn.socket.read(
        loop.get_xev_loop(),
        &conn.read_completion,
        .{ .slice = &conn.read_buffer },
        TcpConnection,
        conn,
        on_read_complete,
    );
}

// callback triggered by libxev when a read completes or fails.
fn on_read_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = s;
    _ = b;
    const conn = user_data.?;

    const bytes_read = result catch |err| {
        if (err != error.EOF and err != error.ConnectionResetByPeer) {
            std.debug.print("read error: {}\n", .{err});
        }
        close_connection(conn);
        return .disarm;
    };

    if (bytes_read == 0) {
        close_connection(conn);
        return .disarm;
    }

    const data = conn.read_buffer[0..bytes_read];

    // update activity timestamp using cross-platform Io clock
    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, 1000000));

    // ensure the loop is stored on the connection for subsequent operations.
    conn.loop = loop;

    // if running in https mode, data must pass through the decryption engine first
    if (conn.ssl) |ssl_ptr| {
        conn.process_tls_data(ssl_ptr, data);
    } else {
        // run pure http
        conn.route_decrypted_data(data);
    }

    return .rearm;
}

// callback triggered when the kernel finishes sending data.
fn on_write_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    s: xev.TCP,
    b: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = s;

    const conn = user_data.?;
    const slice = @constCast(b.slice);
    std.heap.c_allocator.free(slice);

    _ = result catch |err| {
        std.debug.print("write error: {}\n", .{err});
        conn.is_writing = false;
        for (conn.pending_writes.items) |p| std.heap.c_allocator.free(p);
        conn.pending_writes.clearAndFree(std.heap.c_allocator);
        return .disarm;
    };

    if (conn.pending_writes.items.len > 0) {
        const next_data = conn.pending_writes.orderedRemove(0);
        conn.socket.write(
            conn.loop,
            &conn.write_completion,
            .{ .slice = next_data },
            TcpConnection,
            conn,
            on_write_complete,
        );
    } else {
        conn.is_writing = false;
    }

    return .disarm;
}

// cleanly closes the connection asynchronously across platforms via libxev.
pub fn close_connection(conn: *TcpConnection) void {
    conn.deinit_tls();

    for (conn.pending_writes.items) |p| std.heap.c_allocator.free(p);
    conn.pending_writes.clearAndFree(std.heap.c_allocator);
    conn.is_writing = false;

    if (conn.protocol_state == .websocket) {
        conn.ws.deinit();
    }

    conn.socket.close(
        conn.loop,
        &conn.close_completion,
        TcpConnection,
        conn,
        (struct {
            fn cb(
                ud: ?*TcpConnection,
                l: *xev.Loop,
                c_ptr: *xev.Completion,
                s: xev.TCP,
                r: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = l;
                _ = c_ptr;
                _ = s;
                _ = r catch {};
                if (ud) |connection| {
                    if (connection.on_close_cb) |cb_func| {
                        cb_func(connection.pool_ptr.?, connection);
                    }
                }
                return .disarm;
            }
        }).cb,
    );
}

pub const AcceptCallback = *const fn (socket: xev.TCP, user_data: ?*anyopaque) void;

// tcp listener that binds to a port and accepts incoming connections.
pub const TcpServer = struct {
    accept_completion: xev.Completion = undefined,
    listener: xev.TCP,
    on_connection: AcceptCallback,
    user_data: ?*anyopaque,
};

// binds to an ipv4 address and port, and begins listening.
pub fn init_server(address: []const u8, port: u16, cb: AcceptCallback, user_data: ?*anyopaque) !TcpServer {
    const addr = try std.Io.net.IpAddress.parse(address, port);

    var listener = try xev.TCP.init(addr);
    try listener.bind(addr);
    try listener.listen(128);

    return TcpServer{
        .listener = listener,
        .on_connection = cb,
        .user_data = user_data,
    };
}

// starts accepting incoming connections asynchronously.
pub fn accept_start(server: *TcpServer, loop: *Loop) void {
    server.listener.accept(
        loop.get_xev_loop(),
        &server.accept_completion,
        TcpServer,
        server,
        on_accept_complete,
    );
}

// callback triggered when a new client connects.
fn on_accept_complete(
    user_data: ?*TcpServer,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const server = user_data.?;

    const accepted_socket = result catch |err| {
        std.debug.print("accept error: {}\n", .{err});
        return .rearm;
    };

    server.on_connection(accepted_socket, server.user_data);

    return .rearm;
}
