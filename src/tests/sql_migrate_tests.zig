const std = @import("std");
const migrate = @import("test_support").sql_migrate;

test "sql migrations: empty and partially applied plans preserve order" {
    const migrations = [_]migrate.Migration{
        migrate.embedded(1, "create_world", "CREATE TABLE world(id INTEGER);"),
        migrate.embedded(2, "index_world", "CREATE INDEX world_id ON world(id);"),
    };
    var empty = try migrate.Plan.init(&migrations, &.{});
    try std.testing.expectEqualStrings("create_world", empty.next().?.name);
    try std.testing.expectEqualStrings("index_world", empty.next().?.name);
    try std.testing.expectEqual(@as(?*const migrate.Migration, null), empty.next());

    const applied = [_]migrate.Applied{.{
        .id = migrations[0].id,
        .name = migrations[0].name,
        .checksum = migrations[0].checksum,
    }};
    var partial = try migrate.Plan.init(&migrations, &applied);
    try std.testing.expectEqualStrings("index_world", partial.next().?.name);
}

test "sql migrations: applied checksums cannot silently change" {
    const migration = migrate.embedded(1, "create_world", "CREATE TABLE world(id INTEGER);");
    var applied = migrate.Applied{ .id = 1, .name = "create_world", .checksum = migration.checksum };
    applied.checksum[0] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, migrate.Plan.init(&.{migration}, &.{applied}));
    try std.testing.expectEqualStrings("create_world", migrate.mismatch_name(&.{migration}, &.{applied}).?);
}

test "sql migrations: reject unknown, renamed and non-prefix histories" {
    const migrations = [_]migrate.Migration{
        migrate.embedded(1, "first", "SELECT 1;"),
        migrate.embedded(2, "second", "SELECT 2;"),
    };
    const later = migrate.Applied{ .id = 2, .name = "second", .checksum = migrations[1].checksum };
    try std.testing.expectError(error.HistoryMismatch, migrate.Plan.init(&migrations, &.{later}));
    const renamed = migrate.Applied{ .id = 1, .name = "renamed", .checksum = migrations[0].checksum };
    try std.testing.expectError(error.HistoryMismatch, migrate.Plan.init(&migrations, &.{renamed}));
    try std.testing.expectError(error.HistoryMismatch, migrate.Plan.init(&.{}, &.{later}));
    try std.testing.expectError(error.InvalidOrder, migrate.Plan.init(&.{ migrations[1], migrations[0] }, &.{}));
}

test "sql migrations: checksums use strict fixed-size hex without allocation" {
    const migration = migrate.embedded(1, "first", "SELECT 1;");
    var encoded: [64]u8 = undefined;
    migrate.encode_checksum(migration.checksum, &encoded);
    try std.testing.expectEqual(migration.checksum, try migrate.parse_checksum(&encoded));
    try std.testing.expectError(error.InvalidChecksum, migrate.parse_checksum(encoded[0..63]));
    encoded[0] = 'g';
    try std.testing.expectError(error.InvalidChecksum, migrate.parse_checksum(&encoded));
}

test "sql migrations: runtime definitions enforce names and content integrity" {
    var migration = migrate.embedded(1, "first", "SELECT 1;");
    migration.name = "bad\x00name";
    try std.testing.expectError(error.InvalidName, migrate.Plan.init(&.{migration}, &.{}));
    migration.name = "first";
    migration.sql = "SELECT 2;";
    try std.testing.expectError(error.ChecksumMismatch, migrate.Plan.init(&.{migration}, &.{}));
}

test "sql migrations: PostgreSQL script quoting rejects delimiter escape" {
    var buffer: [512]u8 = undefined;
    const sql = "CREATE TABLE item(id INTEGER); INSERT INTO item VALUES(1);";
    const script = try migrate.pg_transaction_script(sql, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, script, sql) != null);
    try std.testing.expect(std.mem.startsWith(u8, script, "DO $uwz_body$ BEGIN EXECUTE $uwz_sql$"));
    try std.testing.expectError(error.InvalidSql, migrate.pg_transaction_script("SELECT '$uwz_sql$'", &buffer));
    try std.testing.expectError(error.InvalidSql, migrate.pg_transaction_script("SELECT '$uwz_body$'", &buffer));
    try std.testing.expectError(error.BufferTooSmall, migrate.pg_transaction_script(sql, buffer[0..10]));
}
