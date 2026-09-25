const builtin = @import("builtin");
const std = @import("std");

const lane_count = switch (builtin.cpu.arch) {
    .x86, .x86_64 => 32,
    else => 16,
};
/// Byte vector of one full lane width: 32 lanes on x86/x86_64, 16 elsewhere.
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

/// Returns the first index where `input` holds `first` or `second`.
///
/// One pass finds either delimiter, so callers that split on a structural
/// byte and terminate on another (Cookie `=` and `;`) do not scan twice.
pub fn index_of_either_byte(input: []const u8, first: u8, second: u8) ?usize {
    const first_needles: ByteVector = @splat(first);
    const second_needles: ByteVector = @splat(second);
    var offset: usize = 0;

    while (input.len - offset >= lane_count) : (offset += lane_count) {
        const bytes: [lane_count]u8 = input[offset..][0..lane_count].*;
        const values: ByteVector = @bitCast(bytes);
        const matches = (values == first_needles) | (values == second_needles);
        if (!@reduce(.Or, matches)) continue;

        for (bytes, 0..) |byte, index| {
            if (byte == first or byte == second) return offset + index;
        }
        unreachable;
    }
    for (input[offset..], offset..) |byte, index| {
        if (byte == first or byte == second) return index;
    }
    return null;
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

/// Returns the first HTTP line ending using vectorized carriage-return scans.
pub fn index_of_crlf(input: []const u8) ?usize {
    var offset: usize = 0;
    while (offset < input.len) {
        const relative = index_of_byte(input[offset..], '\r') orelse return null;
        const position = offset + relative;
        if (position + 1 < input.len and input[position + 1] == '\n') return position;
        offset = position + 1;
    }
    return null;
}

/// Returns the first HTTP header terminator using SIMD candidate discovery.
pub fn index_of_header_end(input: []const u8) ?usize {
    var offset: usize = 0;
    while (offset < input.len) {
        const relative = index_of_crlf(input[offset..]) orelse return null;
        const position = offset + relative;
        if (position + 3 < input.len and
            input[position + 2] == '\r' and
            input[position + 3] == '\n')
        {
            return position;
        }
        offset = position + 2;
    }
    return null;
}

/// Validates HTTP field-value bytes 16 lanes at a time.
pub fn valid_http_field_value(input: []const u8) bool {
    const spaces: ByteVector = @splat(32);
    const deletes: ByteVector = @splat(127);
    const tabs: ByteVector = @splat('\t');
    var offset: usize = 0;
    while (input.len - offset >= lane_count) : (offset += lane_count) {
        const bytes: [lane_count]u8 = input[offset..][0..lane_count].*;
        const values: ByteVector = @bitCast(bytes);
        const valid = ((values >= spaces) & (values != deletes)) | (values == tabs);
        if (!@reduce(.And, valid)) return false;
    }
    for (input[offset..]) |byte| {
        if ((byte < 32 and byte != '\t') or byte == 127) return false;
    }
    return true;
}
