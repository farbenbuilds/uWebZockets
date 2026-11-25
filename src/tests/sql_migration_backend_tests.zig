const std = @import("std");
const support = @import("test_support");
const sqlite = support.sql_sqlite;
const migrate = support.sql_migrate;
const runner = support.sql_migrate_sqlite;

test "sql migrations SQLite: partial startup, idempotence and checksum mismatch" {
    var statements: [2]sqlite.Prepared = undefined;
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    const migrations = [_]migrate.Migration{
        migrate.embedded(1, "world", "CREATE TABLE world(id INTEGER PRIMARY KEY); INSERT INTO world VALUES(1);"),
        migrate.embedded(2, "world_name", "ALTER TABLE world ADD COLUMN name TEXT;"),
    };
    var failure = runner.Failure{};
    try std.testing.expectEqual(@as(usize, 1), try runner.run(&db, migrations[0..1], &failure));
    try std.testing.expectEqual(@as(usize, 1), try runner.run(&db, &migrations, &failure));
    try std.testing.expectEqual(@as(usize, 0), try runner.run(&db, &migrations, &failure));
    try std.testing.expectEqual(@as(?[]const u8, null), failure.name);
    const changed = migrate.embedded(1, "world", "CREATE TABLE world(id INTEGER, changed INTEGER);");
    try std.testing.expectError(error.ChecksumMismatch, runner.run(&db, &.{ changed, migrations[1] }, &failure));
    try std.testing.expectEqualStrings("world", failure.name.?);
    try db.prepare(0, "SELECT count(*) FROM world");
    var rows = try db.query(0, &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try row.get(i64, 0));
}

test "sql migrations SQLite: an error rolls back schema and history" {
    var statements: [2]sqlite.Prepared = undefined;
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    var failure = runner.Failure{};
    const bad = migrate.embedded(1, "broken", "CREATE TABLE partial(id INTEGER); INSERT INTO missing_table VALUES(1);");
    try std.testing.expectError(error.MigrationFailed, runner.run(&db, &.{bad}, &failure));
    try std.testing.expectEqualStrings("broken", failure.name.?);
    try db.prepare(0, "SELECT count(*) FROM sqlite_schema WHERE name IN ('partial', 'uwz_schema_migrations')");
    var rows = try db.query(0, &.{});
    try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
    rows.deinit();
    const good = migrate.embedded(1, "fixed", "CREATE TABLE repaired(id INTEGER);");
    try std.testing.expectEqual(@as(usize, 1), try runner.run(&db, &.{good}, &failure));
}

test "sql migrations SQLite: embedded scripts cannot commit outside the runner" {
    var statements: [1]sqlite.Prepared = undefined;
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    var failure = runner.Failure{};
    const migration = migrate.embedded(1, "escape", "CREATE TABLE escaped(id INTEGER); COMMIT;");
    try std.testing.expectError(error.MigrationFailed, runner.run(&db, &.{migration}, &failure));
    try db.prepare(0, "SELECT count(*) FROM sqlite_schema WHERE name='escaped'");
    var rows = try db.query(0, &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
}

test "sql migrations SQLite: an ignored history row fails the migration" {
    var statements: [1]sqlite.Prepared = undefined;
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    var failure = runner.Failure{};
    const migration = migrate.embedded(1, "ignored", "CREATE TABLE ignored(id INTEGER); CREATE TRIGGER ignore_history BEFORE INSERT ON uwz_schema_migrations BEGIN SELECT RAISE(IGNORE); END;");
    try std.testing.expectError(error.MigrationFailed, runner.run(&db, &.{migration}, &failure));
    try std.testing.expectEqualStrings("ignored", failure.name.?);
    try db.prepare(0, "SELECT count(*) FROM sqlite_schema WHERE name IN ('ignored', 'uwz_schema_migrations')");
    var rows = try db.query(0, &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
}

test "sql migrations SQLite: startup closes when statement preparation is sealed" {
    var statements: [1]sqlite.Prepared = undefined;
    var lookaside: [4096]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    db.seal();
    var failure = runner.Failure{};
    try std.testing.expectError(error.AlreadyStarted, runner.run(&db, &.{}, &failure));
}

test "sql migrations SQLite: VM budget interrupts scripts and rolls back schema" {
    var statements: [1]sqlite.Prepared = undefined;
    var lookaside: [8192]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{ .max_vm_steps = 1000 }, &statements, &lookaside);
    defer db.deinit();
    var failure = runner.Failure{};
    const migration = migrate.embedded(1, "budget", "CREATE TABLE budget(id INTEGER); WITH RECURSIVE n(v) AS (VALUES(0) UNION ALL SELECT v+1 FROM n WHERE v<1000000) SELECT sum(v) FROM n;");
    try std.testing.expectError(error.QueryTimeout, runner.run(&db, &.{migration}, &failure));
    try db.prepare(0, "SELECT count(*) FROM sqlite_schema WHERE name='budget'");
    var rows = try db.query(0, &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), try (try rows.next()).?.get(i64, 0));
}
