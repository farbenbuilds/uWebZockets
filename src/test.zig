const std = @import("std");
const c = @import("c");
const context = @import("core/context.zig");
const loop = @import("core/loop.zig");
const tcp = @import("core/tcp.zig");
const timer = @import("core/timer.zig");

test "ensure boringssl compiles and links" {
    // check if boringssl constants and types are exposed properly.
    try std.testing.expect(c.TLS1_VERSION == 0x0301);
}

test "ensure lsquic compiles and links" {
    // check if lsquic constants are exposed.
    try std.testing.expect(c.LSQUIC_MAJOR_VERSION >= 3);
}

test "ensure libdeflate compiles and links" {
    // check if libdeflate functions can be called.
    const compressor = c.libdeflate_alloc_compressor(6);
    try std.testing.expect(compressor != null);
    c.libdeflate_free_compressor(compressor);
}

// test connection pool logic.
test "core: connection pool acquires and releases slots" {
    var pool = context.init_pool(10);
    try std.testing.expectEqual(@as(usize, 0), context.count_active_connections(10, &pool));

    const conn = context.acquire_connection(10, &pool);
    try std.testing.expect(conn != null);
    try std.testing.expectEqual(@as(usize, 1), context.count_active_connections(10, &pool));

    context.release_connection(10, &pool, conn.?);
    try std.testing.expectEqual(@as(usize, 0), context.count_active_connections(10, &pool));
}

// test loop initialization and deinitialization.
test "core: loop init and deinit" {
    var l = try loop.init();
    defer loop.deinit(&l);

    // ensure the underlying xev loop is available by taking its pointer.
    const xev_loop = loop.get_xev_loop(&l);
    _ = xev_loop;
}

// test tcp server initialization.
test "core: tcp server init" {
    // bind to ephemeral port 0 to prevent port collisions during tests.
    const server = try tcp.init_server("127.0.0.1", 0);
    _ = server;
}

// dummy callback for timer test.
fn dummy_tick() void {}

// test timer initialization and deinitialization.
test "core: timer init and deinit" {
    var t = try timer.init_timer(100, dummy_tick);
    defer timer.deinit_timer(&t);
}
