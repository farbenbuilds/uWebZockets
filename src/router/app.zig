const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_context = @import("../core/context.zig");
const core_pool = @import("../core/pool.zig");
const core_timer = @import("../core/timer.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const DeflateContext = @import("../ws/deflate.zig").Context;
const TlsContext = @import("../crypto/tls.zig").TlsContext;
const quic = @import("../quic/engine.zig");
const udp = @import("../core/udp.zig");

/// Default maximum complete WebSocket message size per connection.
pub const default_max_ws_message_size = 16 * 1024;
/// Default bounded pending-output capacity per TCP connection.
pub const default_write_queue_size = core_tcp.default_write_queue_capacity;
/// Default inactivity timeout before an idle connection is closed.
pub const default_idle_timeout_ms: u64 = 120_000;
/// Reports whether the compiled lsquic transport is available.
pub const http3_available = quic.available;

/// Returns the default fixed-capacity application type.
pub fn app(comptime max_connections: usize) type {
    return configured_app(max_connections, default_max_ws_message_size, default_write_queue_size);
}

/// Returns an application type with explicit message and write capacities.
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

/// Returns an application type with an explicit idle timeout policy.
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
        const QuicEngine = quic.quic_engine(max_connections, write_queue_size);
        const QuicTransport = udp.quic_transport(QuicEngine);

        io: std.Io,
        loop: core_loop.Loop,
        pool: Pool,
        ws_message_storage: []u8,
        ws_compression_storage: []u8 = &.{},
        ws_compression_capacity: usize = 0,
        ws_deflate: ?DeflateContext = null,
        write_queue_storage: []u8,
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        sweeper: ?core_timer.connection_sweeper(Pool, idle_timeout_ms) = null,
        tls_ctx: ?TlsContext = null,
        quic_tls_ctx: ?TlsContext = null,
        quic_transport: ?QuicTransport = null,
        http3_enabled: bool = false,
        routes_locked: bool = false,
        shutting_down: bool = false,
        running: bool = false,
        deinitialized: bool = false,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        /// Initializes a plaintext application and its fixed-capacity slabs.
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

        /// Initializes an HTTPS application from NUL-terminated certificate paths.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            return instance;
        }

        /// Initializes isolated TCP/TLS and HTTP/3/QUIC server contexts.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            instance.quic_tls_ctx = try TlsContext.init_http3(cert_path, key_path);
            instance.http3_enabled = true;
            return instance;
        }

        /// Releases all application resources after shutdown has drained completions.
        pub fn deinit(self: *Self) void {
            if (self.deinitialized) return;
            if (self.running) {
                std.debug.panic("cannot deinitialize an application from its event loop", .{});
            }
            self.shutdown() catch |err| {
                // Returning would leave kernel completions pointing at storage
                // the caller is about to release.
                std.debug.panic("application shutdown failed: {}", .{err});
            };

            if (self.sweeper) |*sw| {
                sw.deinit();
            }
            self.sweeper = null;
            self.server = null;

            if (self.quic_transport) |*transport| transport.deinit();
            self.quic_transport = null;
            if (self.quic_tls_ctx) |*tls| tls.deinit();
            self.quic_tls_ctx = null;
            if (self.tls_ctx) |*tls| tls.deinit();
            self.tls_ctx = null;
            if (self.ws_deflate) |*context| context.deinit();
            self.ws_deflate = null;
            core_loop.deinit(&self.loop);
            self.pool.deinit();
            std.heap.page_allocator.free(self.ws_message_storage);
            if (self.ws_compression_storage.len != 0) {
                std.heap.page_allocator.free(self.ws_compression_storage);
                self.ws_compression_storage = &.{};
            }
            std.heap.page_allocator.free(self.write_queue_storage);
            self.deinitialized = true;
        }

        /// Stops recurring work and drains completions that borrow application slabs.
        pub fn shutdown(self: *Self) !void {
            if (self.deinitialized) return error.ApplicationDeinitialized;

            self.begin_shutdown();
            if (self.running) return;

            try self.drive_shutdown();
        }

        /// Reports whether this application currently owns an active loop run.
        pub fn is_running(self: *const Self) bool {
            return self.running;
        }

        fn begin_shutdown(self: *Self) void {
            if (self.shutting_down) return;

            self.shutting_down = true;
            if (self.sweeper) |*sw| sw.stop(&self.loop);
            if (self.server) |*server| core_tcp.close_server(server, &self.loop);
            if (self.quic_transport) |*transport| transport.shutdown();

            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index)) continue;
                core_tcp.close_connection(conn);
            }
        }

        fn drive_shutdown(self: *Self) !void {
            std.debug.assert(!self.running);
            self.running = true;
            defer self.running = false;
            try core_loop.run(&self.loop);
            try self.verify_shutdown();
        }

        fn verify_shutdown(self: *const Self) !void {
            if (self.pool.count_active() != 0) return error.ShutdownIncomplete;
            if (self.server) |server| {
                if (!server.close_complete) return error.ShutdownIncomplete;
            }
            if (self.quic_transport) |*transport| if (!transport.is_drained()) {
                return error.ShutdownIncomplete;
            };
        }

        /// Registers a synchronous GET route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.get(path, handler);
            return self;
        }

        /// Registers a synchronous HEAD route.
        pub fn head(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.head(path, handler);
            return self;
        }

        /// Registers a synchronous POST route.
        pub fn post(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.post(path, handler);
            return self;
        }

        /// Registers a synchronous PUT route.
        pub fn put(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.put(path, handler);
            return self;
        }

        /// Registers a synchronous DELETE route.
        pub fn delete(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.delete(path, handler);
            return self;
        }

        /// Registers a synchronous PATCH route.
        pub fn patch(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.patch(path, handler);
            return self;
        }

        /// Registers a synchronous OPTIONS route.
        pub fn options(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.options(path, handler);
            return self;
        }

        /// Registers a safe, idempotent RFC 10008 QUERY route.
        pub fn query(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.query(path, handler);
            return self;
        }

        /// Registers a synchronous fallback-method route.
        pub fn any(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.any(path, handler);
            return self;
        }

        /// Appends one ordered global middleware callback.
        pub fn use(
            self: *Self,
            context: *anyopaque,
            middleware: radix.MiddlewareHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.use(context, middleware);
            return self;
        }

        /// Registers a context-aware callback for one method.
        pub fn route_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_context(method, path, context, handler);
            return self;
        }

        /// Registers a deferred callback for one method.
        pub fn route_async(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async(method, path, handler);
            return self;
        }

        /// Registers a context-aware deferred callback for one method.
        pub fn route_async_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async_context(method, path, context, handler);
            return self;
        }

        /// Registers a context-aware GET route.
        pub fn get_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            return self.route_context(.get, path, context, handler);
        }

        /// Registers a deferred GET route.
        pub fn get_async(
            self: *Self,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            return self.route_async(.get, path, handler);
        }

        /// Registers a context-aware deferred GET route.
        pub fn get_async_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            return self.route_async_context(.get, path, context, handler);
        }

        /// Registers a WebSocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) !*Self {
            try self.ensure_routes_mutable();
            if (!radix.valid_ws_limits(behavior, max_ws_message_size)) {
                return error.InvalidWebSocketLimits;
            }
            if (behavior.compression == .permessage_deflate) try self.ensure_ws_compression();
            try self.router.ws(path, behavior);
            return self;
        }

        fn ensure_routes_mutable(self: *const Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.routes_locked) return error.RoutesLocked;
        }

        fn ensure_ws_compression(self: *Self) !void {
            if (self.ws_deflate != null) return;

            var context = try DeflateContext.init(6);
            errdefer context.deinit();
            const per_connection = try context.scratch_bound(max_ws_message_size);
            const per_connection_storage = std.math.mul(
                usize,
                per_connection,
                2,
            ) catch return error.SizeOverflow;
            const storage_len = std.math.mul(
                usize,
                max_connections,
                per_connection_storage,
            ) catch return error.SizeOverflow;
            const storage = try std.heap.page_allocator.alloc(u8, storage_len);

            self.ws_compression_capacity = per_connection;
            self.ws_compression_storage = storage;
            self.ws_deflate = context;
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            if (self.shutting_down) {
                close_rejected_socket(socket);
                return;
            }
            const conn = self.pool.acquire() orelse {
                // No I/O was registered for this descriptor, so direct close is safe.
                close_rejected_socket(socket);
                return;
            };

            conn.req = .{};
            conn.parser = .{};
            conn.reset_protocol() catch {
                _ = self.pool.release(conn);
                close_rejected_socket(socket);
                return;
            };
            conn.ssl = null;
            conn.network_bio = null;
            conn.is_tls_handshake_done = false;
            conn.tls_shutdown_started = false;
            conn.read_active = false;
            conn.read_cancel_active = false;
            conn.write_cancel_active = false;
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
            conn.dispatch_suspended = false;
            conn.pending_request_consumed = 0;
            conn.pending_close_requested = false;
            conn.async_response_state.cancel();

            const now = std.Io.Clock.now(.awake, self.io);
            conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

            conn.socket = socket;
            conn.loop = &self.loop.xev_loop;
            // acquire only returns pointers into this pool's contiguous slab.
            const connection_index = self.pool.index_of(conn) orelse unreachable;
            const message_start = connection_index * max_ws_message_size;
            conn.ws_message_buffer = self.ws_message_storage[message_start .. message_start + max_ws_message_size];
            if (self.ws_deflate) |*context| {
                const buffers = compression_buffers(
                    self.ws_compression_storage,
                    self.ws_compression_capacity,
                    connection_index,
                ) orelse unreachable;
                conn.ws_compression_buffer = buffers.incoming;
                conn.ws_compression_output_buffer = buffers.outgoing;
                conn.ws_deflate = context;
            } else {
                conn.ws_compression_buffer = &.{};
                conn.ws_compression_output_buffer = &.{};
                conn.ws_deflate = null;
            }
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

        /// Binds and starts the POSIX TCP listener, locking route mutation.
        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.server != null) return error.AlreadyListening;

            const server = try core_tcp.init_server(address, port, on_new_connection, self);
            errdefer close_socket_now(server.listener);

            var sweeper: ?core_timer.connection_sweeper(Pool, idle_timeout_ms) = null;
            if (idle_timeout_ms != 0) {
                sweeper = try core_timer.connection_sweeper(Pool, idle_timeout_ms).init(self.io, &self.pool);
            }

            self.routes_locked = true;
            self.server = server;
            self.sweeper = sweeper;
            core_tcp.accept_start(&self.server.?, &self.loop);
            if (self.sweeper) |*sw| {
                sw.start(&self.loop);
            }

            std.debug.print("server listening on {s}:{d}\n", .{ address, port });
        }

        /// Binds and starts the UDP/QUIC listener, locking route mutation.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (!self.http3_enabled or self.quic_tls_ctx == null) return error.Http3NotInitialized;
            if (self.quic_transport != null) return error.AlreadyListening;

            self.quic_transport = try QuicTransport.init(
                self.quic_tls_ctx.?.ctx,
                &self.router,
                address,
                port,
            );
            errdefer {
                if (self.quic_transport) |*transport| transport.deinit();
                self.quic_transport = null;
            }
            if (self.quic_transport) |*transport| {
                try transport.start(self.loop.get_xev_loop());
            } else unreachable;

            self.routes_locked = true;

            std.debug.print("http/3 server listening on {s}:{d}\n", .{ address, port });
        }

        /// Runs the event loop until shutdown completes or no work remains.
        pub fn run(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.running) return error.ApplicationAlreadyRunning;

            self.running = true;
            defer self.running = false;
            try core_loop.run(&self.loop);
            if (self.shutting_down) try self.verify_shutdown();
        }

        /// Publishes one message to every matching bounded subscription.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) usize {
            return self.pubsub.publish(topic, message, is_text);
        }
    };
}

/// Separate borrowed scratch slices for inbound and outbound compression.
pub const CompressionBuffers = struct {
    /// Scratch storage for compressed client messages and decode tails.
    incoming: []u8,
    /// Scratch storage for compressed server messages.
    outgoing: []u8,
};

/// Selects one connection's disjoint compression buffers from caller storage.
pub fn compression_buffers(
    storage: []u8,
    direction_capacity: usize,
    connection_index: usize,
) ?CompressionBuffers {
    if (direction_capacity == 0) return null;
    const stride = std.math.mul(usize, direction_capacity, 2) catch return null;
    const start = std.math.mul(usize, connection_index, stride) catch return null;
    const incoming_end = std.math.add(usize, start, direction_capacity) catch return null;
    const outgoing_end = std.math.add(usize, incoming_end, direction_capacity) catch return null;
    if (outgoing_end > storage.len) return null;

    return .{
        .incoming = storage[start..incoming_end],
        .outgoing = storage[incoming_end..outgoing_end],
    };
}

fn close_rejected_socket(socket: xev.TCP) void {
    close_socket_now(socket);
}

fn close_socket_now(socket: anytype) void {
    _ = std.posix.system.close(socket.fd);
}
