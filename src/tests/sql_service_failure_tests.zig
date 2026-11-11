const std = @import("std");
const support = @import("test_support");
const service = support.public_api.modules;

const Probe = struct {
    stopped: bool = false,
    deinitialized: bool = false,

    fn start(_: *anyopaque, worker: *const service.WorkerContext) service.ServiceError!void {
        if (worker.worker_index == 0) return error.AuthenticationFailed;
    }

    fn stop(context: *anyopaque, _: *const service.WorkerContext) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.stopped = true;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.deinitialized = true;
    }
};

test "modules: cluster failure retains a bounded owned service name after cleanup" {
    const App = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    var group = try App.cluster(2).init(std.testing.allocator, std.testing.io);
    defer group.deinit();
    var probes: [2]Probe = @splat(.{});
    var name = "database".*;
    for (0..2) |index| {
        try group.worker(index).?.provide(.{
            .name = &name,
            .context = &probes[index],
            .start = Probe.start,
            .stop = Probe.stop,
            .deinit = Probe.deinit,
        });
    }
    try group.listen("127.0.0.1", 0);
    try std.testing.expectError(error.ClusterWorkerFailed, group.run());
    @memset(&name, 'x');
    const failure = group.first_failure().?;
    try std.testing.expectEqual(@as(usize, 0), failure.index);
    const detail = failure.service.?;
    try std.testing.expectEqualStrings("database", detail.name[0..detail.name_len]);
    try std.testing.expectEqual(error.AuthenticationFailed, detail.err);
    try std.testing.expect(probes[0].stopped);
    group.deinit();
    try std.testing.expect(probes[0].deinitialized);
    try std.testing.expectEqualStrings("database", detail.name[0..detail.name_len]);
}
