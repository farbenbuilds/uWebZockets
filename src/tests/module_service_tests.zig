const std = @import("std");
const support = @import("test_support");
const service = support.public_api.modules;

const Probe = struct {
    events: *[32]u8,
    event_count: *usize,
    id: u8,
    starts: usize = 0,
    stops: usize = 0,
    deinits: usize = 0,
    ready: bool = false,
    fail: bool = false,
    worker_index: usize = 0,

    fn hooks(self: *Probe, name: []const u8) service.ServiceHooks {
        return .{ .name = name, .context = self, .start = start, .stop = stop, .ready = readiness, .deinit = deinit };
    }

    fn start(context: *anyopaque, worker: *const service.WorkerContext) service.ServiceError!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.starts += 1;
        self.worker_index = worker.worker_index;
        self.record(self.id);
        if (self.fail) return error.Unexpected;
    }

    fn stop(context: *anyopaque, _: *const service.WorkerContext) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.stops += 1;
        self.record(self.id + 10);
    }

    fn readiness(context: *anyopaque) ?[]const u8 {
        const self: *Probe = @ptrCast(@alignCast(context));
        return if (self.ready) null else "connection pending";
    }

    fn deinit(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.deinits += 1;
        self.record(self.id + 20);
    }

    fn record(self: *Probe, event: u8) void {
        self.events[self.event_count.*] = event;
        self.event_count.* += 1;
    }
};

fn worker_context(marker: *u8) service.WorkerContext {
    return .{ .worker_index = 3, .io = std.testing.io, .loop = marker, .config = marker };
}

test "modules: lifecycle preserves registration and reverse shutdown ordering" {
    var events: [32]u8 = undefined;
    var count: usize = 0;
    var first = Probe{ .events = &events, .event_count = &count, .id = 1 };
    var second = Probe{ .events = &events, .event_count = &count, .id = 2 };
    var registry = service.Registry{};
    var marker: u8 = 0;
    const worker = worker_context(&marker);
    try registry.provide(first.hooks("first"));
    try registry.provide(second.hooks("second"));
    try registry.start(&worker);
    try std.testing.expectEqual(@as(usize, 3), first.worker_index);
    try std.testing.expectEqualStrings("first", registry.readiness().?.name);
    first.ready = true;
    try std.testing.expectEqualStrings("second", registry.readiness().?.name);
    second.ready = true;
    try std.testing.expect(registry.readiness() == null);
    registry.stop(&worker);
    registry.stop(&worker);
    registry.deinit();
    registry.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 12, 11, 22, 21 }, events[0..count]);
    try std.testing.expectEqual(@as(usize, 1), first.starts);
    try std.testing.expectEqual(@as(usize, 1), first.stops);
    try std.testing.expectEqual(@as(usize, 1), first.deinits);
}

test "modules: start failure rolls back partial start and preserves first failure" {
    var events: [32]u8 = undefined;
    var count: usize = 0;
    var first = Probe{ .events = &events, .event_count = &count, .id = 1 };
    var second = Probe{ .events = &events, .event_count = &count, .id = 2, .fail = true };
    var registry = service.Registry{};
    var marker: u8 = 0;
    const worker = worker_context(&marker);
    try registry.provide(first.hooks("first"));
    try registry.provide(second.hooks("database"));
    try std.testing.expectError(error.Unexpected, registry.start(&worker));
    try std.testing.expectEqualStrings("database", registry.failure.?.name);
    try std.testing.expectEqual(error.Unexpected, registry.failure.?.err);
    registry.stop(&worker);
    registry.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 12, 11, 22, 21 }, events[0..count]);
}

test "modules: registration has fixed capacity and rejects late changes" {
    var events: [32]u8 = undefined;
    var count: usize = 0;
    var probe = Probe{ .events = &events, .event_count = &count, .id = 1 };
    var registry = service.Registry{};
    try registry.provide(probe.hooks("database"));
    try std.testing.expectError(error.DuplicateService, registry.provide(probe.hooks("database")));
    try std.testing.expectError(error.InvalidServiceName, registry.provide(probe.hooks("")));
    try std.testing.expectError(error.InvalidServiceName, registry.provide(probe.hooks("user:password")));
    var marker: u8 = 0;
    const worker = worker_context(&marker);
    try registry.start(&worker);
    try std.testing.expectError(error.ServiceRegistrationClosed, registry.provide(probe.hooks("late")));
    try std.testing.expectError(error.ServiceAlreadyStarted, registry.start(&worker));
    registry.stop(&worker);
    registry.deinit();
}

test "modules: capacity and readiness limits are enforced without allocation" {
    var events: [32]u8 = undefined;
    var count: usize = 0;
    var probe = Probe{ .events = &events, .event_count = &count, .id = 1 };
    var registry = service.Registry{};
    var names: [service.max_services][16]u8 = undefined;
    for (&names, 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "resource_{d}", .{index});
        var hooks = probe.hooks(name);
        hooks.deinit = null;
        try registry.provide(hooks);
    }
    try std.testing.expectError(error.ServiceCapacityReached, registry.provide(probe.hooks("overflow")));
    var marker: u8 = 0;
    const worker = worker_context(&marker);
    registry.hooks[0].ready = long_readiness;
    try registry.start(&worker);
    const status = registry.readiness().?;
    try std.testing.expect(status.reason.len <= service.max_reason_bytes);
    try std.testing.expectEqualStrings("service readiness reason exceeds limit", status.reason);
    registry.stop(&worker);
    registry.deinit();
}

fn long_readiness(_: *anyopaque) ?[]const u8 {
    return "x" ** (service.max_reason_bytes + 1);
}

const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
const xev = @import("xev");

const LoopProbe = struct {
    app: *TestApp,
    wakeup: ?xev.Async = null,
    completion: xev.Completion = .{},
    starts: usize = 0,
    stops: usize = 0,
    deinits: usize = 0,
    active: bool = false,
    stopping: bool = false,
    start_bound: bool = false,
    stop_drained_http: bool = false,
    fail: bool = false,
    request_stop: bool = true,
    observed_worker_index: usize = 0,
    start_thread: ?std.Thread.Id = null,
    stop_thread: ?std.Thread.Id = null,
    cancel_lifecycle_poll: bool = false,
    poll_cancel_requested: bool = false,
    cancel_completion: xev.Completion = .{},
    complete_readiness: bool = false,
    startup_completed: bool = false,
    readiness_observed: bool = false,
    asynchronous_failure: bool = false,
    startup_failed: bool = false,

    fn hooks(self: *LoopProbe, name: []const u8) service.ServiceHooks {
        return .{ .name = name, .context = self, .start = start, .stop = stop, .ready = readiness, .failed = failure, .deinit = deinit };
    }

    fn start(context: *anyopaque, worker: *const service.WorkerContext) service.ServiceError!void {
        const self: *LoopProbe = @ptrCast(@alignCast(context));
        self.starts += 1;
        self.observed_worker_index = worker.worker_index;
        self.start_thread = std.Thread.getCurrentId();
        self.start_bound = self.app.listener_count != 0 and worker.loop == @as(*anyopaque, &self.app.loop) and worker.scheduler != null;
        if (self.fail) return error.AuthenticationFailed;
        self.wakeup = xev.Async.init() catch return error.Unexpected;
        self.active = true;
        self.wakeup.?.wait(self.app.loop.get_xev_loop(), &self.completion, LoopProbe, self, on_wakeup);
        if (self.cancel_lifecycle_poll or self.complete_readiness or self.asynchronous_failure) self.wakeup.?.notify() catch return error.Unexpected;
        if (self.request_stop) self.app.request_shutdown();
    }

    fn stop(context: *anyopaque, _: *const service.WorkerContext) void {
        const self: *LoopProbe = @ptrCast(@alignCast(context));
        self.stops += 1;
        self.stop_thread = std.Thread.getCurrentId();
        self.stopping = true;
        self.stop_drained_http = self.app.pool.count_active() == 0;
        if (self.app.scheduler) |*scheduler| self.stop_drained_http = self.stop_drained_http and !scheduler.active;
        for (self.app.listeners[0..self.app.listener_count]) |*listener| {
            self.stop_drained_http = self.stop_drained_http and listener.close_complete;
        }
        if (self.wakeup) |*wakeup| wakeup.notify() catch @panic("test module wakeup failed");
    }

    fn on_wakeup(
        user_data: ?*LoopProbe,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        result catch @panic("test module wakeup completion failed");
        if (!self.stopping) {
            if (self.complete_readiness) self.startup_completed = true;
            if (self.asynchronous_failure) self.startup_failed = true;
            if (self.cancel_lifecycle_poll and !self.poll_cancel_requested) {
                self.poll_cancel_requested = true;
                self.app.service_timer.?.cancel(self.app.loop.get_xev_loop(), &self.app.service_completion, &self.cancel_completion, LoopProbe, self, on_poll_canceled);
            }
            return .rearm;
        }
        self.active = false;
        return .disarm;
    }

    fn on_poll_canceled(_: ?*LoopProbe, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        result catch @panic("test lifecycle poll cancellation failed");
        return .disarm;
    }

    fn readiness(context: *anyopaque) ?[]const u8 {
        const self: *LoopProbe = @ptrCast(@alignCast(context));
        if (self.asynchronous_failure) return "resource authentication pending";
        if (self.complete_readiness) {
            if (!self.startup_completed) return "resource startup pending";
            self.readiness_observed = true;
            self.app.request_shutdown();
        }
        return if (self.cancel_lifecycle_poll) "waiting for lifecycle poll cancellation" else null;
    }

    fn failure(context: *anyopaque) ?service.ServiceError {
        const self: *LoopProbe = @ptrCast(@alignCast(context));
        return if (self.startup_failed) error.AuthenticationFailed else null;
    }

    fn deinit(context: *anyopaque) void {
        const self: *LoopProbe = @ptrCast(@alignCast(context));
        std.debug.assert(!self.active);
        self.deinits += 1;
        if (self.wakeup) |*wakeup| wakeup.deinit();
        self.wakeup = null;
    }
};

test "modules: App starts bound owners and drains their tasks before deinit" {
    var app = try TestApp.init(std.testing.io);
    var probe = LoopProbe{ .app = &app };
    defer app.deinit();
    try app.provide(probe.hooks("loop_resource"));
    try std.testing.expect(app.service_readiness() != null);
    try app.listen("127.0.0.1", 0);
    try app.run();
    try std.testing.expect(probe.start_bound);
    try std.testing.expect(probe.stop_drained_http);
    try std.testing.expect(!probe.active);
    try std.testing.expectEqual(@as(usize, 1), probe.starts);
    try std.testing.expectEqual(@as(usize, 1), probe.stops);
    try std.testing.expectEqual(@as(usize, 0), probe.deinits);
    app.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.deinits);
    app.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.deinits);
}

test "modules: App startup rollback drains pending tasks and preserves the owner" {
    var app = try TestApp.init(std.testing.io);
    var first = LoopProbe{ .app = &app, .request_stop = false };
    var failed = LoopProbe{ .app = &app, .fail = true };
    defer app.deinit();
    try app.provide(first.hooks("first"));
    try app.provide(failed.hooks("database"));
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(error.AuthenticationFailed, app.run());
    try std.testing.expectEqualStrings("database", app.service_failure().?.name);
    try std.testing.expectEqual(error.AuthenticationFailed, app.service_failure().?.err);
    try std.testing.expect(!first.active);
    try std.testing.expectEqual(@as(usize, 1), first.stops);
    try std.testing.expectEqual(@as(usize, 1), failed.stops);
    app.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.deinits);
    try std.testing.expectEqual(@as(usize, 1), failed.deinits);
}

test "modules: canceled lifecycle poll still drains core completions before module stop" {
    var app = try TestApp.init(std.testing.io);
    var probe = LoopProbe{ .app = &app, .request_stop = false, .cancel_lifecycle_poll = true };
    defer app.deinit();
    try app.provide(probe.hooks("poll_failure"));
    try app.listen("127.0.0.1", 0);
    try app.run();
    try std.testing.expect(probe.poll_cancel_requested);
    try std.testing.expect(probe.stop_drained_http);
    try std.testing.expect(!probe.active);
    try std.testing.expectEqual(@as(usize, 1), probe.stops);
}

test "modules: asynchronous readiness defers ready output and owns listener address" {
    var app = try TestApp.init(std.testing.io);
    var probe = LoopProbe{ .app = &app, .request_stop = false, .complete_readiness = true };
    defer app.deinit();
    try app.provide(probe.hooks("asynchronous_resource"));
    var address = "127.0.0.1".*;
    try app.listen(&address, 0);
    try std.testing.expectEqual(@as(usize, 1), app.pending_ready_count);
    @memset(&address, 'x');
    try std.testing.expectEqualStrings("127.0.0.1", app.pending_ready[0].address[0..app.pending_ready[0].address_len]);
    try app.run();
    try std.testing.expect(probe.startup_completed);
    try std.testing.expect(probe.readiness_observed);
    try std.testing.expectEqual(@as(usize, 0), app.pending_ready_count);
    try std.testing.expect(probe.stop_drained_http);
}

test "modules: a never-run application releases registered startup storage once" {
    var events: [32]u8 = undefined;
    var count: usize = 0;
    var probe = Probe{ .events = &events, .event_count = &count, .id = 1 };
    var app = try TestApp.init(std.testing.io);
    defer app.deinit();
    try app.provide(probe.hooks("unstarted"));
    app.deinit();
    try std.testing.expectEqual(@as(usize, 0), probe.starts);
    try std.testing.expectEqual(@as(usize, 0), probe.stops);
    try std.testing.expectEqual(@as(usize, 1), probe.deinits);
    try std.testing.expectEqualSlices(u8, &.{21}, events[0..count]);
}

test "modules: asynchronous startup failure preserves owner and drains every started resource" {
    var app = try TestApp.init(std.testing.io);
    var first = LoopProbe{ .app = &app, .request_stop = false };
    var failed = LoopProbe{ .app = &app, .request_stop = false, .asynchronous_failure = true };
    defer app.deinit();
    try app.provide(first.hooks("first"));
    try app.provide(failed.hooks("database"));
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(error.AuthenticationFailed, app.run());
    try std.testing.expectEqualStrings("database", app.service_failure().?.name);
    try std.testing.expectEqual(error.AuthenticationFailed, app.service_failure().?.err);
    try std.testing.expect(first.stop_drained_http and failed.stop_drained_http);
    try std.testing.expect(!first.active and !failed.active);
    try std.testing.expectEqual(@as(usize, 1), first.stops);
    try std.testing.expectEqual(@as(usize, 1), failed.stops);
}

test "modules: cluster starts and stops independent contexts on their owning workers" {
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 1,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    var probes = [_]LoopProbe{ .{ .app = group.worker(0).? }, .{ .app = group.worker(1).? } };
    defer group.deinit();
    for (&probes) |*probe| try probe.app.provide(probe.hooks("resource"));
    try group.listen("127.0.0.1", 0);
    try group.run();
    const configuring_thread = std.Thread.getCurrentId();
    for (&probes, 0..) |*probe, index| {
        try std.testing.expectEqual(index, probe.observed_worker_index);
        try std.testing.expect(probe.start_thread.? != configuring_thread);
        try std.testing.expectEqual(probe.start_thread.?, probe.stop_thread.?);
        try std.testing.expectEqual(@as(usize, 1), probe.starts);
        try std.testing.expectEqual(@as(usize, 1), probe.stops);
        try std.testing.expect(!probe.active);
    }
    group.deinit();
    for (probes) |probe| try std.testing.expectEqual(@as(usize, 1), probe.deinits);
}
