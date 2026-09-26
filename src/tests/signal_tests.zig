//! Unit and integration tests for graceful-shutdown signal capture.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const support = @import("test_support");
const signal = support.signal;
const core_loop = support.loop;
const app = support.app;

const testing = std.testing;

/// Signal dispositions cannot capture context; this is the documented
/// OS-singleton exception used only by the handler-restoration test.
var trap_hits: std.atomic.Value(usize) = .init(0);

/// Test disposition that records delivery instead of terminating.
fn trap_handler(_: std.posix.SIG) callconv(.c) void {
    _ = trap_hits.fetchAdd(1, .monotonic);
}

fn count_signal(context: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

/// Stops and releases a watcher, draining the stop wakeup first.
fn stop_and_deinit(watcher: *signal.SignalWatcher, loop: *core_loop.Loop) void {
    watcher.stop();
    // The stop wakeup is already written, so a run failure cannot re-arm the
    // watcher.
    loop.get_xev_loop().run(.until_done) catch {};
    watcher.deinit();
}

test "signal encoding maps only shutdown signals and coalesces wakeups" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    try testing.expect(signal.is_shutdown_signal(std.posix.SIG.INT));
    try testing.expect(signal.is_shutdown_signal(std.posix.SIG.TERM));
    try testing.expect(!signal.is_shutdown_signal(std.posix.SIG.USR1));
    try testing.expect(!signal.coalesce(0));
    try testing.expect(signal.coalesce(1));
    try testing.expect(signal.coalesce(7));
}

test "signal watcher coalesces SIGTERM and restores the previous handler" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var original: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &original);
    defer std.posix.sigaction(std.posix.SIG.TERM, &original, null);

    trap_hits.store(0, .monotonic);
    var trap_action = std.posix.Sigaction{
        .handler = .{ .handler = trap_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &trap_action, null);

    var loop = try core_loop.init();
    defer core_loop.deinit(&loop);

    var fired: usize = 0;
    var watcher = try signal.SignalWatcher.init(&loop, count_signal, &fired);
    watcher.start();
    var watcher_live = true;
    defer if (watcher_live) stop_and_deinit(&watcher, &loop);

    // Two signals before the loop drains must coalesce into one callback and
    // must not reach the previous trap disposition.
    try std.posix.raise(std.posix.SIG.TERM);
    try std.posix.raise(std.posix.SIG.TERM);
    try loop.get_xev_loop().run(.once);
    try testing.expectEqual(@as(usize, 1), fired);
    try testing.expectEqual(@as(usize, 0), trap_hits.load(.monotonic));

    stop_and_deinit(&watcher, &loop);
    watcher_live = false;

    // The watcher restored the trap disposition, so this raise is recorded
    // instead of killing the test process.
    try std.posix.raise(std.posix.SIG.TERM);
    try testing.expectEqual(@as(usize, 1), trap_hits.load(.monotonic));
}

test "signal watcher rejects a second installation until deinit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop = try core_loop.init();
    defer core_loop.deinit(&loop);

    var fired: usize = 0;
    var first = try signal.SignalWatcher.init(&loop, count_signal, &fired);
    first.start();
    var first_live = true;
    defer if (first_live) stop_and_deinit(&first, &loop);

    try testing.expectError(
        error.SignalWatcherAlreadyInstalled,
        signal.SignalWatcher.init(&loop, count_signal, &fired),
    );

    stop_and_deinit(&first, &loop);
    first_live = false;

    // deinit cleared the process-wide state, so a fresh installation works.
    var second = try signal.SignalWatcher.init(&loop, count_signal, &fired);
    second.start();
    var second_live = true;
    defer if (second_live) stop_and_deinit(&second, &loop);
    stop_and_deinit(&second, &loop);
    second_live = false;
}

test "application signal requests the shared shutdown path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const TestApp = app.configured_app_with_timeout(1, 1024, 4096, 0);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();

    try server.catch_shutdown_signals();
    try testing.expectError(
        error.SignalWatcherAlreadyInstalled,
        server.catch_shutdown_signals(),
    );

    const Raiser = struct {
        timer: xev.Timer,
        completion: xev.Completion = .{},

        fn fire(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            std.posix.raise(std.posix.SIG.TERM) catch return .disarm;
            return .disarm;
        }
    };

    var raiser = Raiser{ .timer = try xev.Timer.init() };
    defer raiser.timer.deinit();
    raiser.timer.run(
        server.loop.get_xev_loop(),
        &raiser.completion,
        1,
        void,
        null,
        Raiser.fire,
    );

    try server.run();
    try testing.expect(server.shutting_down);
    try testing.expect(!server.is_running());
    try testing.expectError(error.ApplicationUnavailable, server.catch_shutdown_signals());
}

test "cluster signal watcher installs once and releases with the group" {
    const TestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);
    const test_config = support.config.ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_body_size = 8192,
        .max_route_nodes = 8,
        .max_pattern_routes = 4,
        .max_middleware = 2,
    };
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        test_config,
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    try group.catch_shutdown_signals();
    try testing.expectError(error.SignalWatcherAlreadyInstalled, group.catch_shutdown_signals());
}
