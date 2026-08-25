const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_context = @import("../core/context.zig");
const core_timer = @import("../core/timer.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;

// main application builder.
// statically allocates memory needed for the connection pool.
pub fn App(comptime max_connections: usize) type {
    return struct {
        const Self = @This();

        loop: core_loop.Loop,
        pool: core_context.connection_pool(max_connections),
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        timer: ?core_timer.TimerContext = null,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        // initializes a new application.
        pub fn init() !Self {
            const loop = try core_loop.init();

            return Self{
                .loop = loop,
                .pool = core_context.init_pool(max_connections),
                .router = radix.Router.init(),
                .pubsub = .{},
            };
        }

        // deinitializes the application and releases os resources.
        pub fn deinit(self: *Self) void {
            if (self.timer) |*t| core_timer.deinit_timer(t);
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

        // global tick callback for the timer wheel.
        fn on_tick() void {
            // sweep through the connection pool to clean up idle connections
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            const conn = core_context.acquire_connection(max_connections, &self.pool) orelse {
                std.debug.print("connection pool full\n", .{});
                _ = std.posix.system.close(socket.fd);
                return;
            };

            conn.socket = socket;
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            core_tcp.read_start(conn, &self.loop);
        }

        // binds the server to an address and port and arms the accept loop.
        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            self.server = try core_tcp.init_server(address, port, on_new_connection, self);
            core_tcp.accept_start(&self.server.?, &self.loop);

            self.timer = try core_timer.init_timer(4000, on_tick);
            core_timer.start_timer(&self.timer.?, &self.loop);

            std.debug.print("server listening on {s}:{d}\n", .{ address, port });
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
