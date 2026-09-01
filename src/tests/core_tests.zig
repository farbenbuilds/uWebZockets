const std = @import("std");
const support = @import("test_support");
const context = support.context;
const loop = support.loop;
const pool_mod = support.pool;
const tcp = support.tcp;
const timer = support.timer;

// test generic bitset pool logic.
test "core: bitset pool acquires and releases slots" {
    var pool = context.bitset_pool(usize, 10).init();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test generic freelist pool logic.
test "core: freelist pool acquires and releases slots" {
    var pool = try pool_mod.freelist_pool(usize, 10).init();
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test loop initialization and deinitialization.
test "core: loop init and deinit" {
    var l = try loop.init();
    defer loop.deinit(&l);

    // ensure the underlying xev loop is available by taking its pointer.
    const xev_loop = l.get_xev_loop();
    _ = xev_loop;
}

fn dummy_accept(socket: @import("xev").TCP, user_data: ?*anyopaque) void {
    _ = socket;
    _ = user_data;
}

// test tcp server initialization.
test "core: tcp server init" {
    // bind to ephemeral port 0 to prevent port collisions during tests.
    const server = try tcp.init_server("127.0.0.1", 0, dummy_accept, null);
    defer _ = std.posix.system.close(server.listener.fd);
}

// dummy callback for timer test.
fn dummy_tick() void {}

// test timer initialization and deinitialization.
test "core: timer init and deinit" {
    var t = try timer.init_timer(100, dummy_tick);
    defer timer.deinit_timer(&t);
}

test "tcp: multipart ring writes preserve order across wrap" {
    var buffer = [_]u8{0} ** 8;
    const tail = tcp.copy_parts_to_ring(&buffer, 6, &.{ "ab", "cde" });

    try std.testing.expectEqual(@as(usize, 3), tail);
    try std.testing.expectEqualStrings("cde", buffer[0..3]);
    try std.testing.expectEqualStrings("ab", buffer[6..8]);
}

test "tcp: HTTP/2 frame capacity reserves plaintext and TLS overhead" {
    try std.testing.expectEqual(@as(usize, 0), tcp.http2_frame_payload_capacity(9, false));
    try std.testing.expectEqual(@as(usize, 1), tcp.http2_frame_payload_capacity(10, false));

    const tls_fixed_cost = 9 + 2 * 64;
    try std.testing.expectEqual(
        @as(usize, 0),
        tcp.http2_frame_payload_capacity(tls_fixed_cost, true),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        tcp.http2_frame_payload_capacity(tls_fixed_cost + 1, true),
    );
    try std.testing.expectEqual(
        @as(usize, 16 * 1024),
        tcp.http2_frame_payload_capacity(tls_fixed_cost + 32 * 1024, true),
    );
}

test "tcp: drained write ring normalizes its head" {
    try std.testing.expectEqual(@as(usize, 0), tcp.advance_write_head(65_504, 32, 0, 65_536));
    try std.testing.expectEqual(@as(usize, 0), tcp.advance_write_head(65_504, 32, 57, 65_536));
    try std.testing.expectEqual(@as(usize, 25), tcp.advance_write_head(10, 15, 20, 65_536));
}

test "tcp: closed connection waits for active completions" {
    const Release = struct {
        var count: usize = 0;

        fn callback(_: *anyopaque, _: *tcp.TcpConnection) void {
            count += 1;
        }
    };

    var pool_token: u8 = 0;
    var conn = tcp.TcpConnection{
        .socket = undefined,
        .closing = true,
        .close_complete = true,
        .read_active = true,
        .is_writing = true,
        .pool_ptr = &pool_token,
        .on_close_cb = Release.callback,
    };

    Release.count = 0;
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.read_active = false;
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.is_writing = false;
    tcp.release_closed_connection(&conn);
    tcp.release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 1), Release.count);
}

test "tcp: server close drains an outstanding accept" {
    const Accept = struct {
        fn callback(socket: @import("xev").TCP, _: ?*anyopaque) void {
            _ = std.posix.system.close(socket.fd);
        }
    };

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);
    var server = try tcp.init_server("127.0.0.1", 0, Accept.callback, null);

    tcp.accept_start(&server, &event_loop);
    tcp.close_server(&server, &event_loop);
    try loop.run(&event_loop);
    try std.testing.expect(server.close_complete);
}

test "timer: stop drains the active completion" {
    const Tick = struct {
        fn callback() void {}
    };

    var event_loop = try loop.init();
    defer loop.deinit(&event_loop);
    var active_timer = try timer.init_timer(60_000, Tick.callback);
    defer timer.deinit_timer(&active_timer);

    timer.start_timer(&active_timer, &event_loop);
    timer.stop_timer(&active_timer, &event_loop);
    try loop.run(&event_loop);
    try std.testing.expect(!active_timer.active);
}
