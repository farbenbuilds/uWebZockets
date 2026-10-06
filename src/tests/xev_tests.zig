//! Runtime backend selection and the allocation-free HTTP/1.1 framing writer.

const std = @import("std");
const support = @import("test_support");
const status = support.status;
const xev = @import("xev");

test "xev: detect selects an available backend" {
    try xev.detect();
    try std.testing.expect(@tagName(xev.backend()).len != 0);
}

test "status: format_http1_framing does not reserve the worst-case digit count" {
    // A 78-byte reason phrase plus a one-digit length fits the 128-byte
    // response framing buffer, so the bound must count actual digits.
    const long_status = "200 " ++ "x" ** 74;
    var buffer: [128]u8 = undefined;
    const head = try status.format_http1_framing(&buffer, long_status, 5);
    try std.testing.expectEqual(@as(usize, 108), head.len);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r\nContent-Length: 5\r\n",
        head,
    );
}

test "status: format_http1_framing writes the largest length" {
    var buffer: [128]u8 = undefined;
    const head = try status.format_http1_framing(&buffer, "200 OK", std.math.maxInt(u64));
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551615\r\n",
        head,
    );
}
