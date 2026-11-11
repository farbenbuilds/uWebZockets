//! One-worker PostgreSQL latency probe with caller-owned in-flight storage.
const std = @import("std");
const uz = @import("uWebZockets");
const xev = @import("xev");

const inflight = 16;
const sample_count = 16_384;
const warmup_count = 1024;
const App = uz.ConfiguredAppWithTimeout(1, 1024, 4096, 0);

const Slot = struct {
    owner: *Probe = undefined,
    query: uz.sql.Query = undefined,
    parameter: [1]uz.sql.Param = .{.{ .value = .{ .int4 = 1 } }},
    name: [16]u8 = undefined,
    name_len: usize = 0,
    submitted_ns: u64 = 0,
    assigned_ns: u64 = 0,
};

const Phase = enum { warmup, measure, done };

const Probe = struct {
    app: *App,
    sql: uz.sql.Sql,
    slots: [inflight]Slot = undefined,
    latencies: [sample_count]u64 = undefined,
    waits: [sample_count]u64 = undefined,
    timer: ?xev.Timer = null,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    phase: Phase = .warmup,
    issued: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    failure: ?uz.sql.RuntimeError = null,
    started_ns: u64 = 0,
    ended_ns: u64 = 0,
    timer_active: bool = false,

    fn hooks(self: *Probe) uz.modules.ServiceHooks {
        return .{ .name = "sql_probe", .context = self, .start = start, .stop = stop, .deinit = deinit };
    }

    fn start(context: *anyopaque, _: *const uz.modules.WorkerContext) uz.modules.ServiceError!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.timer = xev.Timer.init() catch return error.Unexpected;
        self.sql.db.diagnostics = .{ .trace_context = self, .trace = on_trace };
        for (&self.slots, 0..) |*slot, index| {
            slot.* = .{ .owner = self };
            const name = std.fmt.bufPrint(&slot.name, "{d}", .{index}) catch return error.Unexpected;
            slot.name_len = name.len;
        }
        self.arm();
    }

    fn arm(self: *Probe) void {
        self.timer_active = true;
        self.timer.?.run(self.app.loop.get_xev_loop(), &self.completion, 1, Probe, self, on_ready);
    }

    fn on_ready(user_data: ?*Probe, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
        const self = user_data.?;
        self.timer_active = false;
        result catch return .disarm;
        if (!self.sql.db.ready()) {
            self.arm();
            return .disarm;
        }
        self.launch();
        return .disarm;
    }

    fn launch(self: *Probe) void {
        for (&self.slots) |*slot| self.submit(slot);
    }

    fn submit(self: *Probe, slot: *Slot) void {
        const target: usize = if (self.phase == .warmup) warmup_count else sample_count;
        if (self.phase == .done or self.issued == target) return;
        slot.query = .{
            .statement = .{ .name = slot.name[0..slot.name_len], .sql = "SELECT id, randomnumber FROM World WHERE id=$1", .param_oids = &.{23} },
            .params = &slot.parameter,
            .context = slot,
            .callback = on_query,
        };
        self.issued += 1;
        slot.assigned_ns = 0;
        slot.submitted_ns = self.now_ns();
        self.sql.db.query(&slot.query) catch |err| self.finish(slot, .{ .failure = err });
    }

    fn on_trace(context: *anyopaque, event: uz.sql.TraceEvent) void {
        if (event.phase != .begin or event.statement_name.len == 0) return;
        const self: *Probe = @ptrCast(@alignCast(context));
        const index = std.fmt.parseInt(usize, event.statement_name, 10) catch return;
        if (index >= self.slots.len) return;
        self.slots[index].assigned_ns = self.now_ns();
    }

    fn on_query(context: *anyopaque, outcome: uz.sql.QueryOutcome) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        slot.owner.finish(slot, outcome);
    }

    fn finish(self: *Probe, slot: *Slot, outcome: uz.sql.QueryOutcome) void {
        if (self.phase == .done) return;
        const ended = self.now_ns();
        switch (outcome) {
            .failure => |err| {
                self.failed += 1;
                if (self.failure == null) self.failure = err;
            },
            .success => |result| self.validate_result(result) catch |err| {
                self.failed += 1;
                if (self.failure == null) self.failure = err;
            },
        }
        if (self.failure != null) {
            self.phase = .done;
            self.app.request_shutdown();
            return;
        }
        if (self.phase == .measure) {
            self.latencies[self.completed] = ended - slot.submitted_ns;
            self.waits[self.completed] = if (slot.assigned_ns == 0) 0 else slot.assigned_ns - slot.submitted_ns;
        }
        self.completed += 1;
        const target: usize = if (self.phase == .warmup) warmup_count else sample_count;
        if (self.completed != target) {
            self.submit(slot);
            return;
        }
        if (self.phase == .warmup and self.failed == 0) {
            self.phase = .measure;
            self.issued = 0;
            self.completed = 0;
            self.started_ns = self.now_ns();
            self.launch();
            return;
        }
        self.ended_ns = ended;
        self.phase = .done;
        self.app.request_shutdown();
    }

    fn validate_result(_: *Probe, result: uz.sql.QueryResult) uz.sql.RuntimeError!void {
        var rows = result.rows;
        const row = (try rows.next()) orelse return error.InvalidValue;
        if (try row.get(i32, 0) != 1) return error.InvalidValue;
        _ = try row.get(i32, 1);
        if (try rows.next() != null) return error.InvalidValue;
    }

    fn now_ns(self: *const Probe) u64 {
        return @intCast(std.Io.Clock.awake.now(self.app.io).nanoseconds);
    }

    fn stop(context: *anyopaque, _: *const uz.modules.WorkerContext) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (!self.timer_active) return;
        self.timer.?.cancel(self.app.loop.get_xev_loop(), &self.completion, &self.cancel_completion, Probe, self, on_cancel);
    }

    fn on_cancel(user_data: ?*Probe, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| {
            if (err != error.NotFound) std.log.err("SQL probe timer cancellation failed: {}", .{err});
        };
        self.timer_active = false;
        return .disarm;
    }

    fn deinit(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (self.timer) |*timer| timer.deinit();
        self.timer = null;
    }
};

fn config(init: std.process.Init) !uz.sql.Config {
    const env = init.environ_map;
    const plaintext = std.mem.eql(u8, env.get("UWZ_SQL_ALLOW_PLAINTEXT") orelse "", "1");
    const ca = env.get("PGSSLROOTCERT");
    if (!plaintext and ca == null) return error.SqlCaRequired;
    return .{
        .host = env.get("PGHOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
        .user = env.get("PGUSER") orelse "postgres",
        .database = env.get("PGDATABASE") orelse "postgres",
        .password = env.get("PGPASSWORD") orelse "",
        .allow_plaintext = plaintext,
        .tls = if (ca) |path| .{
            .ca_path = try init.arena.allocator().dupeZ(u8, path),
            .server_name = env.get("PGSSLSERVERNAME") orelse "127.0.0.1",
        } else null,
        .statement_cache_entries = 32,
        .limits = .{ .max_message_bytes = 64 * 1024, .max_response_bytes = 64 * 1024 },
    };
}

pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    defer init.gpa.destroy(probe);
    var app = try App.init(init.io);
    defer app.deinit();
    probe.* = .{ .app = &app, .sql = try uz.sql.Sql.init(init.gpa, try config(init)) };
    app.provide(probe.sql.hooks()) catch |err| {
        probe.sql.db.deinit();
        return err;
    };
    try app.provide(probe.hooks());
    try app.listen("127.0.0.1", 0);
    try app.run();
    if (probe.failure) |failure| return failure;
    if (probe.completed != sample_count) return error.IncompleteSamples;
    const output = init.environ_map.get("UWZ_SQL_PROBE_OUTPUT") orelse return error.OutputPathRequired;
    const file = try std.Io.Dir.cwd().createFile(init.io, output, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, "sample,query_ns,pool_wait_ns\n");
    var line: [128]u8 = undefined;
    for (probe.latencies, probe.waits, 0..) |latency, wait, index| {
        const written = try std.fmt.bufPrint(&line, "{d},{d},{d}\n", .{ index, latency, wait });
        try file.writeStreamingAll(init.io, written);
    }
    std.mem.sort(u64, &probe.latencies, {}, std.sort.asc(u64));
    std.mem.sort(u64, &probe.waits, {}, std.sort.asc(u64));
    const summary = try std.fmt.bufPrint(
        &line,
        "samples={d} errors={d} duration_ns={d}\n",
        .{ sample_count, probe.failed, probe.ended_ns - probe.started_ns },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, summary);
    const query = try std.fmt.bufPrint(&line, "query_p50_ns={d} query_p99_ns={d}\n", .{ probe.latencies[sample_count / 2 - 1], probe.latencies[(sample_count * 99 + 99) / 100 - 1] });
    try std.Io.File.stdout().writeStreamingAll(init.io, query);
    const query_tail = try std.fmt.bufPrint(&line, "query_p999_ns={d} query_max_ns={d}\n", .{ probe.latencies[(sample_count * 999 + 999) / 1000 - 1], probe.latencies[sample_count - 1] });
    try std.Io.File.stdout().writeStreamingAll(init.io, query_tail);
    const wait = try std.fmt.bufPrint(&line, "pool_wait_p50_ns={d} pool_wait_p99_ns={d}\n", .{ probe.waits[sample_count / 2 - 1], probe.waits[(sample_count * 99 + 99) / 100 - 1] });
    try std.Io.File.stdout().writeStreamingAll(init.io, wait);
    const wait_tail = try std.fmt.bufPrint(&line, "pool_wait_p999_ns={d} pool_wait_max_ns={d}\n", .{ probe.waits[(sample_count * 999 + 999) / 1000 - 1], probe.waits[sample_count - 1] });
    try std.Io.File.stdout().writeStreamingAll(init.io, wait_tail);
}
