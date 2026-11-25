//! Optional worker-confined SQL module; no SQL symbols are exposed through the C ABI.
const std = @import("std");
const service = @import("../modules/service.zig");
const loop_module = @import("../core/loop.zig");
const timer_module = @import("../core/timer.zig");
pub const types = @import("types.zig");
pub const pg_wire = @import("pg_wire.zig");
pub const pg_auth = @import("pg_auth.zig");
pub const row = @import("rows.zig");
pub const pool = @import("pool.zig");
pub const connection = @import("connection.zig");
pub const runtime_types = @import("runtime_types.zig");
pub const Config = runtime_types.Config;
pub const TlsConfig = runtime_types.TlsConfig;
pub const RuntimeError = runtime_types.RuntimeError;
pub const Query = runtime_types.Query;
pub const BoundStatement = runtime_types.BoundStatement;
pub const ResultSet = runtime_types.ResultSet;
pub const QueryMode = runtime_types.QueryMode;
pub const QueryOutcome = runtime_types.QueryOutcome;
pub const QueryResult = runtime_types.QueryResult;
pub const QueryCallback = runtime_types.QueryCallback;
pub const Db = @import("db.zig").Db;
pub const Diagnostics = @import("db.zig").Diagnostics;
pub const TraceCallback = @import("db.zig").TraceCallback;
pub const TraceEvent = @import("db.zig").TraceEvent;
pub const Tx = @import("tx.zig").Tx;
pub const Savepoint = @import("tx.zig").Savepoint;
pub const Rows = row.Rows;
pub const Row = row.Row;
pub const Value = types.Value;
pub const Param = types.Param;
pub const Statement = types.Statement;
pub const Limits = types.Limits;
pub const SqlError = types.SqlError;
pub const FromRow = row.FromRow;
pub const ToParam = row.ToParam;
pub const Lease = pool.Lease;
/// Pure ordered migration history and checksum validation.
pub const migrate = @import("migrate.zig");
/// Asynchronous migrations with a transaction-scoped PostgreSQL advisory lock.
pub const migrate_pg = @import("migrate_pg.zig");
/// Startup readiness waits for checksum-protected PostgreSQL migrations to commit.
pub const MigrationService = @import("migration_service.zig").MigrationService;
/// Optional SQLite backend, compiled and linked only with `-Dsqlite=true`.
pub const sqlite = if (@import("module_options").sqlite) @import("sqlite.zig") else struct {};
/// Startup SQLite migrations protected by an exclusive transaction.
pub const migrate_sqlite = if (@import("module_options").sqlite) @import("migrate_sqlite.zig") else struct {};

/// App-owned service storage; create one independent value for every worker.
pub const Sql = struct {
    db: Db,

    pub fn init(allocator: std.mem.Allocator, config: Config) RuntimeError!Sql {
        return .{ .db = try Db.init(allocator, config) };
    }

    /// Registration transfers shutdown/deinit responsibility to the App.
    pub fn hooks(self: *Sql) service.ServiceHooks {
        return .{ .name = "sql", .context = self, .start = on_start, .stop = on_stop, .ready = on_ready, .failed = on_failed, .deinit = on_deinit };
    }

    fn on_start(context: *anyopaque, worker: *const service.WorkerContext) service.ServiceError!void {
        const self: *Sql = @ptrCast(@alignCast(context));
        const loop: *loop_module.Loop = @ptrCast(@alignCast(worker.loop));
        const scheduler: *timer_module.Scheduler = @ptrCast(@alignCast(worker.scheduler orelse return error.InvalidConfiguration));
        self.db.start(loop, scheduler, worker.io, worker.worker_index) catch |err| return switch (err) {
            error.AuthenticationFailed, error.UnsupportedAuthentication => error.AuthenticationFailed,
            error.TlsFailed, error.TlsRequired, error.CertificateVerificationFailed => error.TlsFailed,
            error.InvalidConfiguration, error.InvalidPoolSize, error.InvalidWaitCapacity => error.InvalidConfiguration,
            error.OutOfMemory => error.CapacityExceeded,
            else => error.ConnectionFailed,
        };
    }

    fn on_stop(context: *anyopaque, _: *const service.WorkerContext) void {
        const self: *Sql = @ptrCast(@alignCast(context));
        self.db.stop();
    }

    fn on_ready(context: *anyopaque) ?[]const u8 {
        const self: *Sql = @ptrCast(@alignCast(context));
        return if (self.db.ready()) null else "SQL connections are not ready";
    }

    fn on_failed(context: *anyopaque) ?service.ServiceError {
        const self: *Sql = @ptrCast(@alignCast(context));
        const failure = self.db.startup_failure orelse return null;
        return switch (failure) {
            error.AuthenticationFailed, error.UnsupportedAuthentication => error.AuthenticationFailed,
            error.TlsFailed, error.TlsRequired, error.CertificateVerificationFailed => error.TlsFailed,
            error.InvalidConfiguration => error.InvalidConfiguration,
            error.QueryTimeout, error.AcquireTimeout, error.DeadlineExceeded => error.DeadlineExceeded,
            else => error.ConnectionFailed,
        };
    }

    fn on_deinit(context: *anyopaque) void {
        const self: *Sql = @ptrCast(@alignCast(context));
        self.db.deinit();
    }
};
