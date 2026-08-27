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
const deflate = @import("../ws/deflate.zig");
const Compressor = deflate.Compressor;

// main application builder.
// statically allocates memory needed for the connection pool.
pub fn App(comptime max_connections: usize) type {
    return struct {
        const Self = @This();

        io: std.Io,
        loop: core_loop.Loop,
        pool: core_pool.freelist_pool(core_tcp.TcpConnection, max_connections),
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        sweeper: ?core_timer.ConnectionSweeper(core_pool.freelist_pool(core_tcp.TcpConnection, max_connections)) = null,
        tls_ctx: ?TlsContext = null,
        quic_engine: ?*@import("../quic/engine.zig").QuicEngine = null,
        udp_socket: ?xev.UDP = null,
        udp_read_completion: xev.Completion = undefined,
        udp_read_state: xev.UDP.State = undefined,
        udp_read_buf: [65536]u8 = undefined,
        reject_completions: [64]xev.Completion = undefined,
        reject_idx: usize = 0,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        // shared compression engine for websocket permessage-deflate
        compressor: Compressor,

        // initializes a new application.
        pub fn init(io: std.Io) !Self {
            const loop = try core_loop.init();

            // initialize compression engine at level 6 (optimal speed/size balance)
            const comp = try deflate.init_compressor(6);

            return Self{
                .io = io,
                .loop = loop,
                .pool = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections).init(),
                .router = radix.Router.init(),
                .pubsub = .{},
                .reject_completions = undefined,
                .reject_idx = 0,
                .compressor = comp,
            };
        }

        // initializes a new application with https support.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var app = try Self.init(io);
            app.tls_ctx = try TlsContext.init(cert_path, key_path);
            return app;
        }

        // initializes a new application with http/3 (quic) support.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var app = try Self.init_https(io, cert_path, key_path);
            app.quic_engine = try @import("../quic/engine.zig").QuicEngine.init(app.tls_ctx.?.ctx);
            return app;
        }

        // deinitializes the application and releases os resources.
        pub fn deinit(self: *Self) void {
            if (self.tls_ctx) |*tls| tls.deinit();
            if (self.sweeper) |*sw| sw.deinit();
            deflate.deinit_compressor(self.compressor);
            core_loop.deinit(&self.loop);
        }

        // registers an http get route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) *Self {
            self.router.get(path, handler);
            return self;
        }

        // registers a websocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) *Self {
            self.router.ws(path, behavior);
            return self;
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            const conn = self.pool.acquire() orelse {
                std.debug.print("connection pool full\n", .{});

                // synchronously drop if possible, or close asynchronously via round-robin completion pool
                self.reject_idx = (self.reject_idx + 1) % self.reject_completions.len;
                const c = &self.reject_completions[self.reject_idx];

                socket.close(&self.loop.xev_loop, c, void, null, (struct {
                    fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
                        return .disarm;
                    }
                }).cb);
                return;
            };

            // dod optimization: reset only lightweight state before assigning to router.
            conn.req = .{};
            conn.parser = .{};
            conn.protocol_state = .http;
            conn.ssl = null;
            conn.is_tls_handshake_done = false;
            conn.last_active_ms = 0;

            conn.socket = socket;
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            conn.compressor = &self.compressor;
            conn.pool_ptr = &self.pool;
            conn.io = self.io;
            conn.on_close_cb = (struct {
                fn cb(pool_ptr: *anyopaque, c: *core_tcp.TcpConnection) void {
                    const pool: *core_pool.freelist_pool(core_tcp.TcpConnection, max_connections) = @ptrCast(@alignCast(pool_ptr));
                    pool.release(c);
                }
            }).cb;

            core_tcp.read_start(conn, &self.loop);
        }

        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            self.server = try core_tcp.init_server(address, port, on_new_connection, self);
            core_tcp.accept_start(&self.server.?, &self.loop);

            const PoolT = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections);
            self.sweeper = try core_timer.ConnectionSweeper(PoolT).init(self.io, &self.pool);
            if (self.sweeper) |*sw| {
                sw.start(&self.loop);
            }

            std.debug.print("server listening on {s}:{d}\n", .{ address, port });
        }

        // binds the server to a udp socket for quic/http3.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            const addr = try std.Io.net.IpAddress.parse(address, port);
            self.udp_socket = try xev.UDP.init(addr);
            try self.udp_socket.?.bind(addr);

            if (self.quic_engine) |quic| {
                quic.udp_fd = self.udp_socket.?.fd;
            }

            self.udp_socket.?.read(
                &self.loop.xev_loop,
                &self.udp_read_completion,
                &self.udp_read_state,
                .{ .slice = &self.udp_read_buf },
                Self,
                self,
                on_udp_read,
            );

            std.debug.print("udp server listening on {s}:{d} (quic/http3)\n", .{ address, port });
        }

        fn on_udp_read(
            ud: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: *xev.UDP.State,
            addr: std.Io.net.IpAddress,
            udp_socket: xev.UDP,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = s;
            _ = udp_socket;
            _ = b;

            const self = ud.?;

            const bytes_read = r catch |err| {
                std.debug.print("udp read error: {}\n", .{err});
                return .rearm;
            };

            if (bytes_read > 0) {
                if (self.quic_engine) |quic| {
                    const datagram = self.udp_read_buf[0..bytes_read];
                    quic.process_datagram(datagram, addr);
                }
            }

            return .rearm;
        }

        // blocks the current thread and enters the event loop.
        pub fn run(self: *Self) !void {
            try core_loop.run(&self.loop);
        }

        // global publish from the server side.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) void {
            self.pubsub.publish(topic, message, is_text);
        }
    };
}
