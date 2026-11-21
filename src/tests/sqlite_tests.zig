const std = @import("std");
const sqlite = @import("test_support").sql_sqlite;

test "sqlite: memory CRUD binds values and preserves NULL and blobs" {
    var statements: [8]sqlite.Prepared = @splat(.{});
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT, payload BLOB)");
    try db.exec(0, &.{});
    try db.prepare(1, "INSERT INTO item VALUES(?1, ?2, ?3)");
    try db.exec(1, &.{ .{ .value = .{ .int8 = 7 } }, .{ .value = .{ .text = "x'); DROP TABLE item; --" } }, .{ .value = .{ .bytea = "\x00\xff" } } });
    try db.exec(1, &.{ .{ .value = .{ .int8 = 8 } }, .{ .value = .null }, .{ .value = .{ .bytea = "" } } });
    try db.prepare(2, "SELECT id, name, payload FROM item ORDER BY id");
    var rows = try db.query(2, &.{});
    const first = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 7), try first.get(i64, 0));
    try std.testing.expectEqualStrings("x'); DROP TABLE item; --", try first.get([]const u8, 1));
    try std.testing.expectEqualSlices(u8, "\x00\xff", (try first.value(2)).bytea);
    const second = (try rows.next()).?;
    try std.testing.expectEqual(.null, try second.value(1));
    try std.testing.expectEqual(@as(usize, 0), (try second.value(2)).bytea.len);
    try std.testing.expect((try rows.next()) == null);
}

test "sqlite: foreign keys and parameter count fail closed" {
    var statements: [5]sqlite.Prepared = @splat(.{});
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "CREATE TABLE parent(id INTEGER PRIMARY KEY)");
    try db.exec(0, &.{});
    try db.prepare(1, "CREATE TABLE child(id INTEGER REFERENCES parent(id))");
    try db.exec(1, &.{});
    try db.prepare(2, "INSERT INTO child VALUES(?1)");
    try std.testing.expectError(error.TooManyParameters, db.exec(2, &.{}));
    try std.testing.expectError(error.SqliteConstraint, db.exec(2, &.{.{ .value = .{ .int8 = 1 } }}));
    try db.prepare(3, "SELECT 1");
    try db.exec(3, &.{});
}

test "sqlite: statement and row bounds reject excess work" {
    var statements: [2]sqlite.Prepared = @splat(.{});
    var lookaside: [8192]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{ .limits = .{ .max_rows = 1, .max_field_bytes = 8 } }, &statements, &lookaside);
    defer db.deinit();
    try std.testing.expectError(error.StatementCacheFull, db.prepare(2, "SELECT 1"));
    try std.testing.expectError(error.InvalidStatement, db.prepare(0, "SELECT 1; SELECT 2"));
    try db.prepare(0, "SELECT 'hello world'");
    var long_rows = try db.query(0, &.{});
    try std.testing.expectError(error.FieldTooLarge, long_rows.next());
    try db.prepare(1, "SELECT 1 UNION ALL SELECT 2");
    var rows = try db.query(1, &.{});
    _ = try rows.next();
    try std.testing.expectError(error.TooManyRows, rows.next());
}

test "sqlite: borrowed rows expire and caller copies survive reset" {
    var statements: [2]sqlite.Prepared = @splat(.{});
    var lookaside: [8192]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "SELECT 'first' UNION ALL SELECT 'second'");
    db.seal();
    try std.testing.expectError(error.AlreadyStarted, db.prepare(1, "SELECT 1"));
    var rows = try db.query(0, &.{});
    const first = (try rows.next()).?;
    var copy: [16]u8 = undefined;
    const kept = try first.keep(0, &copy);
    try std.testing.expectError(error.ConnectionBusy, db.query(0, &.{}));
    _ = try rows.next();
    try std.testing.expectError(error.StaleRow, first.value(0));
    rows.deinit();
    try std.testing.expectEqualStrings("first", kept);
    var restarted = try db.query(0, &.{});
    defer restarted.deinit();
    try std.testing.expectEqualStrings("first", try (try restarted.next()).?.get([]const u8, 0));
}

test "sqlite: file WAL supports rollback savepoints and reports busy writer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/state.db", .{directory}, 0);
    defer std.testing.allocator.free(path);
    var first_statements: [8]sqlite.Prepared = @splat(.{});
    var first_lookaside: [64 * 1024]u8 align(8) = undefined;
    var first = try sqlite.Db.init(.{ .path = path, .wal = true }, &first_statements, &first_lookaside);
    defer first.deinit();
    try first.prepare(0, "CREATE TABLE counter(value INTEGER)");
    try first.exec(0, &.{});
    try first.prepare(1, "BEGIN IMMEDIATE");
    try first.prepare(2, "INSERT INTO counter VALUES(?1)");
    try first.prepare(3, "SAVEPOINT bounded");
    try first.prepare(4, "ROLLBACK TO bounded");
    try first.prepare(5, "COMMIT");
    try first.prepare(6, "SELECT count(*) FROM counter");
    try first.prepare(7, "PRAGMA journal_mode");
    var mode = try first.query(7, &.{});
    try std.testing.expectEqualStrings("wal", try (try mode.next()).?.get([]const u8, 0));
    mode.deinit();
    var second_statements: [1]sqlite.Prepared = @splat(.{});
    var second_lookaside: [8192]u8 align(8) = undefined;
    var second = try sqlite.Db.init(.{ .path = path, .wal = true }, &second_statements, &second_lookaside);
    defer second.deinit();
    try second.prepare(0, "BEGIN IMMEDIATE");
    try first.exec(1, &.{});
    try std.testing.expectError(error.SqliteBusy, second.exec(0, &.{}));
    try first.exec(2, &.{.{ .value = .{ .int8 = 1 } }});
    try first.exec(3, &.{});
    try first.exec(2, &.{.{ .value = .{ .int8 = 2 } }});
    try first.exec(4, &.{});
    try first.exec(5, &.{});
    var count = try first.query(6, &.{});
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try count.next()).?.get(i64, 0));
}

test "sqlite: repeated prepared reads retain bounded SQLite memory" {
    var statements: [1]sqlite.Prepared = @splat(.{});
    var lookaside: [64 * 1024]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{}, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "SELECT ?1, ?2");
    db.seal();
    const params = [_]sqlite.Param{ .{ .value = .{ .int8 = 42 } }, .{ .value = .{ .text = "bounded" } } };
    try db.exec(0, &params);
    const before = try db.memory_usage();
    _ = try sqlite.allocation_snapshot(true);
    for (0..1000) |_| {
        var rows = try db.query(0, &params);
        const row = (try rows.next()).?;
        try std.testing.expectEqual(@as(i64, 42), try row.get(i64, 0));
        rows.deinit();
    }
    const after = try db.memory_usage();
    const allocations = try sqlite.allocation_snapshot(false);
    try std.testing.expectEqual(before.statement_bytes, after.statement_bytes);
    try std.testing.expectEqual(before.lookaside_miss_full, after.lookaside_miss_full);
    try std.testing.expectEqual(before.lookaside_miss_size, after.lookaside_miss_size);
    try std.testing.expect(allocations.peak_bytes >= allocations.current_bytes);
    // This proves stable resident usage and no lookaside fallback, not zero
    // allocator calls: SQLite's public status API does not count allocation churn.
}

test "sqlite: VM execution budget interrupts work and resets connection" {
    var statements: [2]sqlite.Prepared = @splat(.{});
    var lookaside: [8192]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{ .max_vm_steps = 1000 }, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "WITH RECURSIVE n(v) AS (VALUES(0) UNION ALL SELECT v+1 FROM n WHERE v<1000000) SELECT sum(v) FROM n");
    try db.prepare(1, "SELECT 1");
    var long_rows = try db.query(0, &.{});
    try std.testing.expectError(error.QueryTimeout, long_rows.next());
    var rows = try db.query(1, &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try rows.next()).?.get(i64, 0));
}

test "sqlite: requested WAL fails when the database cannot enable it" {
    var statements: [1]sqlite.Prepared = @splat(.{});
    var lookaside: [8192]u8 align(8) = undefined;
    try std.testing.expectError(error.InvalidConfiguration, sqlite.Db.init(.{ .wal = true }, &statements, &lookaside));
}
