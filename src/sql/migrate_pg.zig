//! Asynchronous PostgreSQL migrations on one pinned worker connection.
const std = @import("std");
const db_module = @import("db.zig");
const runtime = @import("runtime_types.zig");
const pool = @import("pool.zig");
const types = @import("types.zig");
const migrate = @import("migrate.zig");

pub const Error = runtime.RuntimeError || migrate.MigrationError;
/// Retains only the migration name and stable error, never SQL or credentials.
pub const Failure = struct { err: Error, name: ?[]const u8 = null };
pub const Outcome = union(enum) { applied: usize, failure: Failure };
/// Runs on the owning worker, after the pinned connection has been released.
pub const CompleteCallback = *const fn (*anyopaque, Outcome) void;
/// Migration progress remains caller-owned until its terminal callback.
pub const Phase = enum { idle, begin, lock, schema, history, apply, record, verify, commit, rollback };

/// Stable startup storage. One transaction-scoped advisory lock serializes
/// concurrent starters; history is read only after the lock is acquired.
pub const Runner = struct {
    db: *db_module.Db,
    migrations: []const migrate.Migration,
    context: *anyopaque,
    callback: CompleteCallback,
    query: runtime.Query = undefined,
    history: [migrate.max_migrations]migrate.Applied = undefined,
    names: [migrate.max_migrations][migrate.max_name_bytes]u8 = undefined,
    params: [3]types.Param = undefined,
    checksum_text: [64]u8 = undefined,
    script: [migrate.max_sql_bytes + 128]u8 = undefined,
    lease: ?pool.Lease = null,
    phase: Phase = .idle,
    plan: migrate.Plan = undefined,
    current: ?*const migrate.Migration = null,
    failure: ?Failure = null,
    applied: usize = 0,
    deadline_ms: u64 = 0,

    /// Begins after Db readiness with an absolute scheduler deadline. The
    /// runner, migration sources, and callback context must stay at stable addresses.
    pub fn start(self: *Runner, deadline_ms: u64) Error!void {
        if (self.phase != .idle) return error.AlreadyStarted;
        _ = try migrate.Plan.init(self.migrations, &.{});
        self.lease = try self.db.acquire();
        self.failure = null;
        self.current = null;
        self.applied = 0;
        self.deadline_ms = deadline_ms;
        self.submit(.begin);
    }

    fn submit(self: *Runner, phase: Phase) void {
        self.phase = phase;
        self.query = .{
            .statement = .{ .name = statement_name(phase), .sql = statement_sql(phase) },
            .deadline_ms = self.deadline_ms,
            .context = self,
            .callback = on_query,
        };
        switch (phase) {
            .lock => {
                self.params[0] = .{ .value = .{ .int8 = 0x75575a6d696772 } };
                self.query.params = self.params[0..1];
            },
            .apply => {
                const script = migrate.pg_transaction_script(self.current.?.sql, &self.script) catch |err| {
                    self.fail(err);
                    return;
                };
                self.query.statement = .{ .name = "", .sql = script };
                self.query.mode = .migration;
            },
            .record => {
                const migration = self.current.?;
                migrate.encode_checksum(migration.checksum, &self.checksum_text);
                self.params = .{
                    .{ .value = .{ .int8 = @intCast(migration.id) } },
                    .{ .value = .{ .text = migration.name } },
                    .{ .value = .{ .text = &self.checksum_text } },
                };
                self.query.params = &self.params;
            },
            .verify => {
                self.params[0] = .{ .value = .{ .int8 = @intCast(self.current.?.id) } };
                self.query.params = self.params[0..1];
            },
            else => {},
        }
        self.db.query_on(self.lease.?, &self.query) catch |err| self.fail(err);
    }

    fn fail(self: *Runner, err: Error) void {
        if (self.failure == null) self.failure = .{
            .err = err,
            .name = if (self.current) |migration| migration.name else null,
        };
        if (self.phase == .rollback) {
            self.finish(false);
            return;
        }
        self.submit(.rollback);
    }

    fn finish(self: *Runner, healthy: bool) void {
        if (!healthy and self.failure == null) {
            self.failure = .{ .err = error.MigrationFailed, .name = if (self.current) |migration| migration.name else null };
        }
        const lease = self.lease.?;
        if (healthy) {
            self.db.release(lease) catch |err| {
                if (self.failure == null) self.failure = .{ .err = err };
            };
        } else {
            self.db.discard(lease) catch |err| {
                if (self.failure == null) self.failure = .{ .err = err };
            };
        }
        const outcome: Outcome = if (self.failure) |failure| .{ .failure = failure } else .{ .applied = self.applied };
        const callback = self.callback;
        const context = self.context;
        self.phase = .idle;
        self.lease = null;
        callback(context, outcome);
    }

    fn on_query(context: *anyopaque, outcome: runtime.QueryOutcome) void {
        const self: *Runner = @ptrCast(@alignCast(context));
        const result = switch (outcome) {
            .success => |result| result,
            .failure => |err| {
                self.fail(err);
                return;
            },
        };
        switch (self.phase) {
            .begin, .lock, .schema, .history, .apply, .record, .verify => {
                if (result.transaction_status != 'T') {
                    self.fail(error.MigrationFailed);
                    return;
                }
            },
            .commit, .rollback, .idle => {},
        }
        switch (self.phase) {
            .begin => self.submit(.lock),
            .lock => self.submit(.schema),
            .schema => self.submit(.history),
            .history => {
                self.read_history(result) catch |err| {
                    self.fail(err);
                    return;
                };
                self.next();
            },
            .apply => self.submit(.record),
            .record => {
                if (!std.mem.eql(u8, result.command_tag, "INSERT 0 1")) {
                    self.fail(error.MigrationFailed);
                    return;
                }
                self.verify_row(result) catch |err| {
                    self.fail(err);
                    return;
                };
                self.submit(.verify);
            },
            .verify => {
                self.verify_row(result) catch |err| {
                    self.fail(err);
                    return;
                };
                self.applied += 1;
                self.next();
            },
            .commit, .rollback => self.finish(result.transaction_status == 'I'),
            .idle => unreachable,
        }
    }

    fn next(self: *Runner) void {
        self.current = self.plan.next();
        self.submit(if (self.current == null) .commit else .apply);
    }

    /// Re-read the committed row in a separate round trip. `RETURNING` sees the
    /// tuple before AFTER triggers, which can still mutate or delete it.
    fn verify_row(self: *Runner, result: runtime.QueryResult) Error!void {
        const migration = self.current.?;
        var rows = result.rows;
        const row = (try rows.next()) orelse return error.MigrationFailed;
        const id = try row.get(i64, 0);
        const name = try row.get([]const u8, 1);
        const checksum = try row.get([]const u8, 2);
        if (id != @as(i64, @intCast(migration.id)) or
            !std.mem.eql(u8, name, migration.name) or
            !std.mem.eql(u8, checksum, &self.checksum_text))
        {
            return error.MigrationFailed;
        }
        if ((try rows.next()) != null) return error.MigrationFailed;
    }

    fn read_history(self: *Runner, result: runtime.QueryResult) Error!void {
        var rows = result.rows;
        var count: usize = 0;
        while (try rows.next()) |row| {
            if (count == self.history.len) return error.TooManyMigrations;
            const id = try row.get(i64, 0);
            const name = try row.get([]const u8, 1);
            const checksum = try row.get([]const u8, 2);
            if (id <= 0) return error.HistoryMismatch;
            if (name.len == 0 or name.len > migrate.max_name_bytes) return error.InvalidName;
            @memcpy(self.names[count][0..name.len], name);
            self.history[count] = .{
                .id = @intCast(id),
                .name = self.names[count][0..name.len],
                .checksum = try migrate.parse_checksum(checksum),
            };
            count += 1;
        }
        self.plan = migrate.Plan.init(self.migrations, self.history[0..count]) catch |err| {
            self.failure = .{ .err = err, .name = migrate.mismatch_name(self.migrations, self.history[0..count]) };
            return err;
        };
    }
};

fn statement_name(phase: Phase) []const u8 {
    return switch (phase) {
        .begin => "uwz_migration_begin",
        .lock => "uwz_migration_lock",
        .schema => "uwz_migration_schema",
        .history => "uwz_migration_history",
        .record => "uwz_migration_record",
        .verify => "uwz_migration_verify",
        .commit => "uwz_migration_commit",
        .rollback => "uwz_migration_rollback",
        .idle, .apply => "",
    };
}

fn statement_sql(phase: Phase) []const u8 {
    return switch (phase) {
        .begin => "BEGIN",
        .lock => "SELECT pg_advisory_xact_lock($1)",
        .schema => "CREATE TABLE IF NOT EXISTS public.uwz_schema_migrations(id BIGINT PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL)",
        .history => "SELECT id, name, checksum FROM public.uwz_schema_migrations ORDER BY id",
        .record => "INSERT INTO public.uwz_schema_migrations(id, name, checksum) VALUES($1, $2, $3) RETURNING id, name, checksum",
        .verify => "SELECT id, name, checksum FROM public.uwz_schema_migrations WHERE id = $1",
        .commit => "COMMIT",
        .rollback => "ROLLBACK",
        .idle, .apply => "",
    };
}
