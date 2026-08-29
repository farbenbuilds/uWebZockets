const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_context = @import("../core/context.zig");
const core_pool = @import("../core/pool.zig");
const core_timer = @import("../core/timer.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const TlsContext = @import("../crypto/tls.zig").TlsContext;

pub const default_max_ws_message_size = 16 * 1024;
pub const default_write_queue_size = core_tcp.default_write_queue_capacity;
pub const default_idle_timeout_ms: u64 = 120_000;
pub const http3_available = false;

pub fn app(comptime max_connections: usize) type {
    return configured_app(max_connections, default_max_ws_message_size, default_write_queue_size);
}

pub fn configured_app(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
) type {
    return configured_app_with_timeout(
        max_connections,
        max_ws_message_size,
        write_queue_size,
        default_idle_timeout_ms,
    );
}

pub fn configured_app_with_timeout(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
    comptime idle_timeout_ms: u64,
) type {
    if (max_connections == 0) @compileError("connection capacity must be greater than zero");
    if (max_ws_message_size == 0) @compileError("WebSocket message capacity must be greater than zero");
    if (write_queue_size == 0) @compileError("write queue capacity must be greater than zero");
    if (max_connections > std.math.maxInt(usize) / max_ws_message_size) {
        @compileError("WebSocket message storage size overflows usize");
    }
    if (max_connections > std.math.maxInt(usize) / write_queue_size) {
        @compileError("write queue storage size overflows usize");
    }

    return struct {
        const Self = @This();
        const Pool = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections);

        io: std.Io,
        loop: core_loop.Loop,
        pool: Pool,
        ws_message_storage: []u8,
        write_queue_storage: []u8,
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        sweeper: ?core_timer.ConnectionSweeper(Pool, idle_timeout_ms) = null,
        tls_ctx: ?TlsContext = null,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        // initializes a new application.
        pub fn init(io: std.Io) !Self {
            var loop = try core_loop.init();
            errdefer core_loop.deinit(&loop);

            var pool = try Pool.init();
            errdefer pool.deinit();

            const storage_len = max_connections * max_ws_message_size;
            const ws_message_storage = try std.heap.page_allocator.alloc(u8, storage_len);
            errdefer std.heap.page_allocator.free(ws_message_storage);

            const write_storage_len = max_connections * write_queue_size;
            const write_queue_storage = try std.heap.page_allocator.alloc(u8, write_storage_len);
            errdefer std.heap.page_allocator.free(write_queue_storage);

            return Self{
                .io = io,
                .loop = loop,
                .pool = pool,
                .ws_message_storage = ws_message_storage,
                .write_queue_storage = write_queue_storage,
                .router = radix.Router.init(),
                .pubsub = .{},
            };
        }

        // initializes a new application with https support.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            return instance;
        }

        // initializes a new application with http/3 (quic) support.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            _ = io;
            _ = cert_path;
            _ = key_path;
            return error.Http3NotImplemented;
        }

        // deinitializes the application and releases os resources.
        pub fn deinit(self: *Self) void {
            if (self.sweeper) |*sw| sw.deinit();
            self.sweeper = null;

            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index)) continue;
                conn.closing = true;
                if (conn.protocol_state == .websocket) conn.ws.deinit();
                conn.deinit_tls();
                close_socket_now(conn.socket);
            }

            if (self.server) |server| close_socket_now(server.listener);
            self.server = null;

            if (self.tls_ctx) |*tls| tls.deinit();
            self.tls_ctx = null;
            core_loop.deinit(&self.loop);
            self.pool.deinit();
            std.heap.page_allocator.free(self.ws_message_storage);
            std.heap.page_allocator.free(self.write_queue_storage);
        }

        // registers an http get route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.get(path, handler);
            return self;
        }

        pub fn head(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.head(path, handler);
            return self;
        }

        pub fn post(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.post(path, handler);
            return self;
        }

        pub fn put(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.put(path, handler);
            return self;
        }

        pub fn delete(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.delete(path, handler);
            return self;
        }

        pub fn patch(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.patch(path, handler);
            return self;
        }

        pub fn options(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.options(path, handler);
            return self;
        }

        pub fn any(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.router.any(path, handler);
            return self;
        }

        // registers a websocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) !*Self {
            try self.router.ws(path, behavior);
            return self;
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            const conn = self.pool.acquire() orelse {
                // No I/O was registered for this descriptor, so direct close is safe.
                close_rejected_socket(socket);
                return;
            };

            conn.req = .{};
            conn.parser = .{};
            conn.protocol_state = .http;
            conn.ssl = null;
            conn.network_bio = null;
            conn.is_tls_handshake_done = false;
            conn.tls_shutdown_started = false;
            conn.read_active = false;
            conn.request_len = 0;
            conn.write_head = 0;
            conn.write_len = 0;
            conn.write_in_flight_len = 0;
            conn.is_writing = false;
            conn.close_complete = false;
            conn.was_backpressured = false;
            conn.close_when_drained = false;
            conn.closing = false;
            conn.expect_continue_sent = false;
            conn.suppress_response_body = false;

            const now = std.Io.Clock.now(.awake, self.io);
            conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

            conn.socket = socket;
            conn.loop = &self.loop.xev_loop;
            // acquire only returns pointers into this pool's contiguous slab.
            const connection_index = self.pool.index_of(conn) orelse unreachable;
            const message_start = connection_index * max_ws_message_size;
            conn.ws_message_buffer = self.ws_message_storage[message_start .. message_start + max_ws_message_size];
            const write_start = connection_index * write_queue_size;
            conn.write_queue = self.write_queue_storage[write_start .. write_start + write_queue_size];
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            conn.pool_ptr = &self.pool;
            conn.io = self.io;
            conn.on_close_cb = (struct {
                fn cb(pool_ptr: *anyopaque, c: *core_tcp.TcpConnection) void {
                    const pool: *Pool = @ptrCast(@alignCast(pool_ptr));
                    _ = pool.release(c);
                }
            }).cb;

            if (self.tls_ctx) |tls| {
                conn.init_tls(tls.ctx) catch {
                    core_tcp.close_connection(conn);
                    return;
                };
            }
            core_tcp.read_start(conn, &self.loop);
        }

        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            if (self.server != null) return error.AlreadyListening;

            const server = try core_tcp.init_server(address, port, on_new_connection, self);
            errdefer close_socket_now(server.listener);

            var sweeper: ?core_timer.ConnectionSweeper(Pool, idle_timeout_ms) = null;
            if (idle_timeout_ms != 0) {
                sweeper = try core_timer.ConnectionSweeper(Pool, idle_timeout_ms).init(self.io, &self.pool);
            }

            self.server = server;
            self.sweeper = sweeper;
            core_tcp.accept_start(&self.server.?, &self.loop);
            if (self.sweeper) |*sw| {
                sw.start(&self.loop);
            }

            std.debug.print("server listening on {s}:{d}\n", .{ address, port });
        }

        // binds the server to a udp socket for quic/http3.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            _ = self;
            _ = address;
            _ = port;
            return error.Http3NotImplemented;
        }

        // blocks the current thread and enters the event loop.
        pub fn run(self: *Self) !void {
            try core_loop.run(&self.loop);
        }

        // global publish from the server side.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) usize {
            return self.pubsub.publish(topic, message, is_text);
        }
    };
}

fn close_rejected_socket(socket: xev.TCP) void {
    close_socket_now(socket);
}

fn close_socket_now(socket: anytype) void {
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(@ptrCast(socket.fd));
        return;
    }
    _ = std.posix.system.close(socket.fd);
}
