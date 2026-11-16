const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const xev = @import("xev");
const support = @import("test_support");

const Router = support.radix.Router;
const Hook = *const fn (*anyopaque) void;
const attempts = 4096;

const WakeEngine = struct {
    processes: usize = 0,
    packets: usize = 0,
    cooldowns: usize = 0,
    delay: u64 = 60_000,
    shorten_deadline: bool = false,
    context: ?*anyopaque = null,
    process_hook: ?Hook = null,
    packet_hook: ?Hook = null,

    pub fn init() !WakeEngine {
        return .{};
    }

    pub fn start(_: *WakeEngine, _: *c.SSL_CTX, _: *const Router, _: xev.SocketFd, _: std.Io.net.IpAddress) !void {}
    pub fn deinit(_: *WakeEngine) void {}

    pub fn process(engine: *WakeEngine) void {
        engine.processes += 1;
        if (engine.shorten_deadline) engine.delay = if (engine.processes == 1) 0 else 60_000;
        if (engine.process_hook) |hook| hook(engine.context.?);
    }

    pub fn process_datagram(engine: *WakeEngine, _: []const u8, _: std.Io.net.IpAddress) void {
        engine.packets += 1;
        if (engine.packet_hook) |hook| hook(engine.context.?);
    }

    pub fn next_timeout_ms(engine: *const WakeEngine) u64 {
        return engine.delay;
    }

    pub fn cooldown(engine: *WakeEngine) void {
        engine.cooldowns += 1;
    }
};

const Transport = support.udp.quic_transport(WakeEngine);

const Fixture = struct {
    transport: Transport,
    loop: support.loop.Loop,
    hook_failed: bool = false,
    expired_with_cancel_pending: bool = false,

    fn init(router: *const Router) !Fixture {
        var loop = if (try select_backend())
            support.loop.Loop{ .xev_loop = try xev.Loop.init(.{ .entries = 256 }) }
        else
            try support.loop.init();
        errdefer support.loop.deinit(&loop);
        return .{
            .transport = try Transport.init(@ptrFromInt(1), router, "127.0.0.1", 0),
            .loop = loop,
        };
    }

    fn start(fixture: *Fixture) !void {
        fixture.transport.engine.context = fixture;
        try fixture.transport.start(fixture.loop.get_xev_loop());
    }

    fn tick(fixture: *Fixture, count: usize) !void {
        for (0..count) |_| try fixture.loop.xev_loop.run(.no_wait);
    }

    fn await_processes(fixture: *Fixture, count: usize) !void {
        for (0..attempts) |_| {
            if (fixture.transport.engine.processes >= count) break;
            try fixture.tick(1);
        }
        try std.testing.expectEqual(count, fixture.transport.engine.processes);
    }

    fn drain(fixture: *Fixture) !void {
        fixture.transport.shutdown();
        for (0..attempts) |_| {
            if (fixture.transport.is_drained()) break;
            try fixture.tick(1);
        }
        try std.testing.expect(fixture.transport.is_drained());
        try std.testing.expect(!fixture.transport.timer_active);
        try std.testing.expect(!fixture.transport.timer_cancel_active);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.drain() catch @panic("UDP wake fixture did not drain");
        fixture.transport.deinit();
        support.loop.deinit(&fixture.loop);
    }
};

fn select_backend() !bool {
    const requested = std.testing.environ.getAlloc(std.testing.allocator, "UWZ_UDP_WAKE_BACKEND") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => return err,
    };
    defer std.testing.allocator.free(requested);
    if (comptime !xev.dynamic) return error.DynamicBackendRequired;
    if (std.mem.eql(u8, requested, "epoll")) {
        if (!xev.prefer(.epoll)) return error.RequestedBackendUnavailable;
        return true;
    }
    if (std.mem.eql(u8, requested, "io_uring")) {
        if (!xev.prefer(.io_uring)) return error.RequestedBackendUnavailable;
        return true;
    }
    return error.InvalidRequestedBackend;
}

fn request_inside_engine(context: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.transport.request_process() catch {
        fixture.hook_failed = true;
    };
}

fn shutdown_inside_engine(context: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.transport.shutdown();
}

fn observe_expiration(context: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.expired_with_cancel_pending = fixture.transport.timer_cancel_active;
    fixture.transport.engine.delay = 60_000;
}

test "udp wake: queued timer request is deferred and coalesced" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    try std.testing.expectError(error.NotStarted, fixture.transport.request_process());
    try fixture.start();
    for (0..32) |_| try fixture.transport.request_process();
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.processes);
    try fixture.await_processes(1);
    try fixture.tick(32);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.processes);
}

test "udp wake: active timer advances without waiting for its old deadline" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    try fixture.start();
    try fixture.tick(1);
    try fixture.transport.request_process();
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.processes);
    try fixture.await_processes(1);
}

test "udp wake: request during engine processing creates no autonomous pass" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    fixture.transport.engine.process_hook = request_inside_engine;
    try fixture.start();
    try fixture.transport.request_process();
    try fixture.await_processes(1);
    try fixture.tick(64);
    try std.testing.expect(!fixture.hook_failed);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.processes);
}

test "udp wake: request during packet dispatch creates no autonomous pass" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    fixture.transport.engine.packet_hook = request_inside_engine;
    try fixture.start();
    const sender = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (sender < 0) return error.SocketFailed;
    defer _ = std.posix.system.close(sender);
    var address = support.quic_api.Sockaddr.init(fixture.transport.local_address);
    const payload = "wake";
    try std.testing.expectEqual(@as(isize, payload.len), c.sendto(sender, payload.ptr, payload.len, 0, @ptrCast(&address.storage), address.length));
    for (0..attempts) |_| {
        if (fixture.transport.engine.packets != 0) break;
        try fixture.tick(1);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.packets);
    try fixture.tick(64);
    try std.testing.expect(!fixture.hook_failed);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.processes);
}

test "udp wake: processing rearms the newly shortened engine deadline" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    fixture.transport.engine.shorten_deadline = true;
    try fixture.start();
    try fixture.transport.request_process();
    try fixture.await_processes(2);
    try fixture.tick(32);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.engine.processes);
}

test "udp wake: shutdown drains an outstanding wake cancellation exactly once" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    try fixture.start();
    try fixture.transport.request_process();
    fixture.transport.shutdown();
    fixture.transport.shutdown();
    try std.testing.expectError(error.ShuttingDown, fixture.transport.request_process());
    try fixture.drain();
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.processes);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.cooldowns);
}

test "udp wake: shutdown inside processing prevents timer rearm" {
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    fixture.transport.engine.process_hook = shutdown_inside_engine;
    try fixture.start();
    try fixture.transport.request_process();
    try fixture.await_processes(1);
    try fixture.drain();
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.cooldowns);
}

test "udp wake: expired io_uring timer retires before its outstanding cancel is reused" {
    if (comptime !xev.dynamic) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router);
    defer fixture.deinit();
    if (xev.backend() != .io_uring) return error.SkipZigTest;
    fixture.transport.engine.delay = 0;
    fixture.transport.engine.process_hook = observe_expiration;
    try fixture.start();
    try xev.submit(fixture.loop.get_xev_loop());
    // Let the real kernel deadline complete without dispatching its callback.
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    try fixture.transport.request_process();
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.processes);
    try fixture.await_processes(1);
    try std.testing.expect(fixture.expired_with_cancel_pending);
    try fixture.tick(32);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.processes);
}
