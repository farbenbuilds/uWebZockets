const std = @import("std");

const lane_count = 16;
const ByteVector = @Vector(lane_count, u8);

/// Returns the first matching byte using portable vector comparisons.
pub fn index_of_byte(input: []const u8, needle: u8) ?usize {
    const needles: ByteVector = @splat(needle);
    var offset: usize = 0;

    while (input.len - offset >= lane_count) : (offset += lane_count) {
        const bytes: [lane_count]u8 = input[offset..][0..lane_count].*;
        const values: ByteVector = @bitCast(bytes);
        if (!@reduce(.Or, values == needles)) continue;

        for (bytes, 0..) |byte, index| {
            if (byte == needle) return offset + index;
        }
        unreachable;
    }
    return if (std.mem.indexOfScalar(u8, input[offset..], needle)) |index|
        offset + index
    else
        null;
}

/// Returns the first occurrence of `needle`, vectorizing the first-byte scan.
pub fn index_of(input: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > input.len) return null;

    var offset: usize = 0;
    while (offset <= input.len - needle.len) {
        const relative = index_of_byte(input[offset .. input.len - needle.len + 1], needle[0]) orelse return null;
        offset += relative;
        if (std.mem.eql(u8, input[offset .. offset + needle.len], needle)) return offset;
        offset += 1;
    }
    return null;
}
