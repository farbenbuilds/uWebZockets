//! Worker-local startup migrations gated on SQL readiness and one overall deadline.
const std = @import("std");
const database = @import("db.zig");
const migration = @import("migrate.zig");
const pg = @import("migrate_pg.zig");
const lifecycle = @import("../modules/service.zig");
const timer = @import("../core/timer.zig");
const wheel = @import("../core/timer_wheel.zig");

/// Startup policy and the bounded service identity retained by the caller-owned owner.
pub const Options = struct {
    name: []const u8 = "sql_migrations",
    timeout_ms: u64 = 30_000,
    poll_interval_ms: u64 = 1,
};
/// The migration name remains inspectable after borrowed source storage is released.
pub const Failure = struct {
    err: pg.Error,
    name: [migration.max_name_bytes]u8 = undefined,
    name_len: usize = 0,
};
/// Only `ready` permits the application's ready notification.
pub const State = enum { configured, waiting, running, ready, failed, stopping, stopped, deinitialized };

/// Register after `Sql.hooks`; the owner, Db and migration sources stay stable
/// until App deinit. Every timer and query uses existing worker-owned storage.
pub const MigrationService = struct {
    /// Named startup policy accepted by `init`.
    pub const Config = Options;

    runner: pg.Runner,
    timeout_ms: u64,
    poll_interval_ms: u64,
    name: [lifecycle.max_name_bytes]u8 = undefined,
    name_len: usize,
    poll: wheel.TimerNode = .{},
    scheduler: ?*timer.Scheduler = null,
    deadline_ms: u64 = 0,
    state: State = .configured,
    failure: ?Failure = null,
    applied: usize = 0,

    /// Validates embedded sources before any startup effect or allocation.
    pub fn init(db: *database.Db, migrations: []const migration.Migration, options: Options) pg.Error!MigrationService {
        if (!valid_options(options)) return error.InvalidConfiguration;
        _ = try migration.Plan.init(migrations, &.{});
        var result = MigrationService{
            .runner = .{ .db = db, .migrations = migrations, .context = undefined, .callback = on_complete },
            .timeout_ms = options.timeout_ms,
            .poll_interval_ms = options.poll_interval_ms,
            .name_len = options.name.len,
        };
        @memcpy(result.name[0..options.name.len], options.name);
        return result;
    }

    pub fn hooks(self: *MigrationService) lifecycle.ServiceHooks {
        return .{
            .name = self.name[0..self.name_len],
            .context = self,
            .start = on_start,
            .stop = on_stop,
            .ready = on_ready,
            .failed = on_failed,
            .deinit = on_deinit,
        };
    }

    fn on_start(context: *anyopaque, worker: *const lifecycle.WorkerContext) lifecycle.ServiceError!void {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        if (self.state != .configured) return error.ServiceAlreadyStarted;
        if (!self.runner.db.started or self.runner.db.pool.worker_index != worker.worker_index) return error.InvalidConfiguration;
        const db_loop = self.runner.db.loop orelse return error.InvalidConfiguration;
        if (@as(*anyopaque, db_loop) != worker.loop) return error.InvalidConfiguration;
        const scheduler: *timer.Scheduler = @ptrCast(@alignCast(worker.scheduler orelse return error.InvalidConfiguration));
        if (self.runner.db.scheduler != scheduler) return error.InvalidConfiguration;
        self.scheduler = scheduler;
        self.deadline_ms = scheduler.current_time_ms() +| self.timeout_ms;
        self.runner.context = self;
        self.state = .waiting;
        self.schedule_poll();
    }

    fn on_poll(context: *anyopaque) void {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        if (self.state != .waiting) return;
        if (self.scheduler.?.current_time_ms() >= self.deadline_ms) {
            self.retain_failure(error.QueryTimeout, null);
            self.state = .failed;
            return;
        }
        if (self.runner.db.startup_failure) |failure| {
            self.retain_failure(failure, null);
            self.state = .failed;
            return;
        }
        if (!self.runner.db.ready()) {
            self.schedule_poll();
            return;
        }
        self.state = .running;
        self.runner.start(self.deadline_ms) catch |err| {
            if (err == error.PoolExhausted) {
                self.state = .waiting;
                self.schedule_poll();
                return;
            }
            self.retain_failure(err, null);
            self.state = .failed;
        };
    }

    fn schedule_poll(self: *MigrationService) void {
        const scheduler = self.scheduler.?;
        const next = @min(self.deadline_ms, scheduler.current_time_ms() +| self.poll_interval_ms);
        scheduler.schedule(&self.poll, next, on_poll, self);
    }

    fn on_complete(context: *anyopaque, outcome: pg.Outcome) void {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        const stopping = self.state == .stopping;
        switch (outcome) {
            .applied => |count| {
                self.applied = count;
                self.state = if (stopping) .stopped else .ready;
            },
            .failure => |failure| {
                self.retain_failure(failure.err, failure.name);
                self.state = if (stopping) .stopped else .failed;
            },
        }
    }

    fn retain_failure(self: *MigrationService, err: pg.Error, name: ?[]const u8) void {
        if (self.failure != null) return;
        var failure = Failure{ .err = err };
        if (name) |value| {
            failure.name_len = @min(value.len, failure.name.len);
            @memcpy(failure.name[0..failure.name_len], value[0..failure.name_len]);
        }
        self.failure = failure;
    }

    fn on_stop(context: *anyopaque, _: *const lifecycle.WorkerContext) void {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        if (self.state == .stopped or self.state == .deinitialized) return;
        if (self.scheduler) |scheduler| _ = scheduler.cancel(&self.poll);
        if (self.runner.phase == .idle) {
            self.state = .stopped;
            return;
        }
        self.state = .stopping;
        self.runner.db.cancel(&self.runner.query) catch |err| {
            // The SQL owner stops immediately afterward and drains every query callback.
            self.retain_failure(err, if (self.runner.current) |current| current.name else null);
        };
    }

    fn on_ready(context: *anyopaque) ?[]const u8 {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        return if (self.state == .ready) null else "SQL migrations have not committed";
    }

    fn on_failed(context: *anyopaque) ?lifecycle.ServiceError {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        const failure = self.failure orelse return null;
        return switch (failure.err) {
            error.QueryTimeout, error.AcquireTimeout, error.DeadlineExceeded => error.DeadlineExceeded,
            error.AuthenticationFailed, error.UnsupportedAuthentication => error.AuthenticationFailed,
            error.TlsFailed, error.TlsRequired, error.CertificateVerificationFailed => error.TlsFailed,
            error.InvalidConfiguration, error.WrongWorker, error.WrongPool => error.InvalidConfiguration,
            else => error.MigrationFailed,
        };
    }

    fn on_deinit(context: *anyopaque) void {
        const self: *MigrationService = @ptrCast(@alignCast(context));
        std.debug.assert(self.runner.phase == .idle);
        std.debug.assert(self.poll.owner == null);
        self.state = .deinitialized;
    }
};

fn valid_options(options: Options) bool {
    if (options.timeout_ms == 0 or options.poll_interval_ms == 0 or options.poll_interval_ms > 1000) return false;
    if (options.name.len == 0 or options.name.len > lifecycle.max_name_bytes) return false;
    for (options.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    }
    return true;
}
