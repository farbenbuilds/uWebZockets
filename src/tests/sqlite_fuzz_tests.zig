const std = @import("std");
const sqlite = @import("test_support").sql_sqlite;

test "fuzz: SQLite bound value decoding preserves bytes, integers and NULL" {
    try std.testing.fuzz({}, roundtrip_values, .{ .corpus = &.{
        "", "\x00", "\xff\x00\xfe", "12345678", "' ); DROP TABLE item; --",
    } });
}

fn roundtrip_values(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var input: [256]u8 = undefined;
    const length: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0, 255, 1),
        .value(u8, 0, 4),
        .value(u8, 255, 4),
    }));
    const integer: i64 = if (length >= 8) std.mem.readInt(i64, input[0..8], .little) else @intCast(length);
    var statements: [1]sqlite.Prepared = undefined;
    var lookaside: [8192]u8 align(8) = undefined;
    var db = try sqlite.Db.init(.{ .limits = .{ .max_rows = 1, .max_field_bytes = 256, .max_response_bytes = 1024 } }, &statements, &lookaside);
    defer db.deinit();
    try db.prepare(0, "SELECT ?1, ?2, ?3");
    db.seal();
    const parameters = [_]sqlite.Param{
        .{ .value = .{ .bytea = input[0..length] } },
        .{ .value = .{ .int8 = integer } },
        .{ .value = .null },
    };
    var rows = try db.query(0, &parameters);
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqualSlices(u8, input[0..length], (try row.value(0)).bytea);
    try std.testing.expectEqual(integer, try row.get(i64, 1));
    try std.testing.expectEqual(.null, try row.value(2));
    try std.testing.expect((try rows.next()) == null);
}
