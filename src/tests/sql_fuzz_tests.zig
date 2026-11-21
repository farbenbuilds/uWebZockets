const std = @import("std");
const target = @import("test_support").sql_fuzz;

test "fuzz: PostgreSQL frames and migration checksums preserve bounds" {
    try std.testing.fuzz({}, fuzz_sql, .{ .corpus = &.{
        "",                                           "R\x00\x00\x00\x08\x00\x00\x00\x00",
        "D\x00\x00\x00\x0b\x00\x01\x00\x00\x00\x01x", "T\x00\x00\x00\x06\x00\x00",
        "\x0c\x00\x00\x00\x00\xc0\x00\x00\x00",       "0123456789abcdef" ** 4,
    } });
}

fn fuzz_sql(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var input: [target.max_input_bytes]u8 = undefined;
    const length: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0, 255, 4),
        .value(u8, 0, 12),
        .value(u8, 'D', 4),
        .value(u8, 'T', 4),
        .rangeAtMost(u8, '0', '9', 4),
        .rangeAtMost(u8, 'a', 'f', 4),
    }));
    target.fuzz_one(input[0..length]);
}
