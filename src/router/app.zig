const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_context = @import("../core/context.zig");
const core_timer = @import("../core/timer.zig");
const radix = @import("radix.zig");

// main application builder.
// statically allocates memory needed for the connection pool.
pub fn App(comptime max_connections: usize) type {
    return struct {
        loop: core_loop.Loop,
        pool: core_context.connection_pool(max_connections),
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        timer: ?core_timer.TimerContext = null,
    };
}

// initializes a new application.
pub fn init_app(comptime max_connections: usize) !App(max_connections) {
    const loop = try core_loop.init();

    return App(max_connections){
        .loop = loop,
        .pool = core_context.init_pool(max_connections),
        .router = radix.Router{},
    };
}

// deinitializes the application and releases os resources.
pub fn deinit_app(app_instance: anytype) void {
    if (app_instance.timer) |*t| core_timer.deinit_timer(t);
    core_loop.deinit(&app_instance.loop);
}

// registers an http get route.
pub fn add_route(app_instance: anytype, path: []const u8, handler: radix.Handler) void {
    radix.add_route(&app_instance.router, path, handler);
}

// global tick callback for the timer wheel.
fn on_tick() void {
    // sweep through the connection pool to clean up idle connections
}

// binds the server to an address and port and arms the accept loop.
pub fn listen(app_instance: anytype, address: []const u8, port: u16) !void {
    app_instance.server = try core_tcp.init_server(address, port);
    core_tcp.accept_start(&app_instance.server.?, &app_instance.loop);

    app_instance.timer = try core_timer.init_timer(4000, on_tick);
    core_timer.start_timer(&app_instance.timer.?, &app_instance.loop);

    std.debug.print("server listening on {s}:{d}\n", .{ address, port });
}

// blocks the current thread and enters the event loop.
pub fn run(app_instance: anytype) !void {
    try core_loop.run(&app_instance.loop);
}
