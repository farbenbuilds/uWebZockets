const std = @import("std");
const sql = @import("test_support").sql;
const fixture = @import("sql_test_support.zig");

const Capture = struct {
    calls: usize = 0,
    outcome: ?sql.migrate_pg.Outcome = null,

    fn complete(context: *anyopaque, outcome: sql.migrate_pg.Outcome) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.outcome = outcome;
    }
};

fn wait(live: *fixture.LiveDb, capture: *const Capture) !void {
    const deadline = live.scheduler.current_time_ms() + 5000;
    while (capture.calls == 0) {
        if (live.scheduler.current_time_ms() >= deadline) return error.MigrationCompletionTimeout;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

fn reset_database(live: *fixture.LiveDb) !void {
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("DROP TABLE IF EXISTS public.uwz_schema_migrations; DROP TABLE IF EXISTS public.uwz_migration_test; DROP TABLE IF EXISTS public.uwz_migration_partial", &capture);
    query.mode = .migration;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
}

test "sql PostgreSQL migrations: partial startup, idempotence and checksum mismatch" {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    try reset_database(&live);
    const migrations = [_]sql.migrate.Migration{
        sql.migrate.embedded(1, "first", "CREATE TABLE public.uwz_migration_test(id INTEGER); INSERT INTO public.uwz_migration_test VALUES(1);"),
        sql.migrate.embedded(2, "second", "ALTER TABLE public.uwz_migration_test ADD COLUMN name TEXT;"),
    };
    var capture: Capture = .{};
    var runner = sql.migrate_pg.Runner{ .db = &live.db, .migrations = migrations[0..1], .context = &capture, .callback = Capture.complete };
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.outcome.?.applied);
    capture = .{};
    runner.migrations = &migrations;
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.outcome.?.applied);
    capture = .{};
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(@as(usize, 0), capture.outcome.?.applied);
    capture = .{};
    const changed = sql.migrate.embedded(1, "first", "CREATE TABLE public.uwz_migration_test(changed INTEGER);");
    runner.migrations = &.{ changed, migrations[1] };
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(error.ChecksumMismatch, capture.outcome.?.failure.err);
    try std.testing.expectEqualStrings("first", capture.outcome.?.failure.name.?);
}

test "sql PostgreSQL migrations: script errors and transaction escape roll back schema" {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    try reset_database(&live);
    const bad = sql.migrate.embedded(1, "broken", "CREATE TABLE public.uwz_migration_partial(id INTEGER); INSERT INTO missing_migration_table VALUES(1);");
    var capture: Capture = .{};
    var runner = sql.migrate_pg.Runner{ .db = &live.db, .migrations = &.{bad}, .context = &capture, .callback = Capture.complete };
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(error.ServerError, capture.outcome.?.failure.err);
    capture = .{};
    const escape = sql.migrate.embedded(1, "escape", "CREATE TABLE public.uwz_migration_partial(id INTEGER); COMMIT;");
    runner.migrations = &.{escape};
    try runner.start(live.scheduler.current_time_ms() + 4000);
    try wait(&live, &capture);
    try std.testing.expectEqual(error.ServerError, capture.outcome.?.failure.err);
    var result: fixture.QueryCapture = .{};
    var query = fixture.request("SELECT count(*)::int8 FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('uwz_migration_partial','uwz_schema_migrations')", &result);
    try live.db.query(&query);
    try live.wait(&result);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), result.failure);
    try std.testing.expectEqual(@as(i64, 0), result.integer);
}

test "sql PostgreSQL migrations: advisory lock serializes concurrent starters" {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    try reset_database(&live);
    const migration = sql.migrate.embedded(1, "concurrent", "CREATE TABLE public.uwz_migration_test(id INTEGER);");
    var first: Capture = .{};
    var second: Capture = .{};
    var a = sql.migrate_pg.Runner{ .db = &live.db, .migrations = &.{migration}, .context = &first, .callback = Capture.complete };
    var b = sql.migrate_pg.Runner{ .db = &live.db, .migrations = &.{migration}, .context = &second, .callback = Capture.complete };
    const deadline = live.scheduler.current_time_ms() + 4000;
    try a.start(deadline);
    try b.start(deadline);
    try wait(&live, &first);
    try wait(&live, &second);
    try std.testing.expectEqual(@as(usize, 1), first.outcome.?.applied + second.outcome.?.applied);
}
