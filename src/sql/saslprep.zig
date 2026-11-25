//! RFC4013 SASLprep over pinned Unicode 3.2, using caller-owned bounded storage.
const std = @import("std");
const data = @import("unicode_3_2.zig");
const SqlError = @import("types.zig").SqlError;

/// Enforces RFC4013 checks on normalized output, using caller-owned bounded storage.
pub fn prepare(input: []const u8, output: []u8, scratch: []u21) SqlError![]const u8 {
    return prepare_profile(.rfc4013, input, output, scratch);
}

/// Matches PostgreSQL 17/18, which checks mapped input before normalized output is returned.
pub fn prepare_postgres(input: []const u8, output: []u8, scratch: []u21) SqlError![]const u8 {
    return prepare_profile(.postgres, input, output, scratch);
}

/// RFC4013 and PostgreSQL differ in the data checked for prohibited characters and bidi.
const Profile = enum { rfc4013, postgres };

fn prepare_profile(profile: Profile, input: []const u8, output: []u8, scratch: []u21) SqlError![]const u8 {
    if (profile == .postgres) try validate_mapped(input);
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidValue;
    var iterator = view.iterator();
    var count: usize = 0;
    while (iterator.nextCodepoint()) |original| {
        const mapped = map_scalar(original) orelse continue;
        const scalar = if (profile == .postgres) postgres_scalar(mapped) else mapped;
        try decompose(scalar, scratch, &count);
    }
    if (count == 0) return error.InvalidValue;
    const normalized = compose(scratch[0..count]);
    if (profile == .rfc4013) try validate(normalized);
    var offset: usize = 0;
    for (normalized) |codepoint| {
        const size = std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidValue;
        if (size > output.len - offset) return error.BufferTooSmall;
        _ = std.unicode.utf8Encode(codepoint, output[offset..][0..size]) catch return error.InvalidValue;
        offset += size;
    }
    return output[0..offset];
}

// PostgreSQL uses the Unicode4 Corrigendum4 mappings, unlike RFC4013's Unicode3.2.
fn postgres_scalar(codepoint: u21) u21 {
    return switch (codepoint) {
        0x2f868 => 0x36fc,
        0x2f874 => 0x5f53,
        0x2f91f => 0x243ab,
        0x2f95f => 0x7aee,
        0x2f9bf => 0x45d7,
        else => codepoint,
    };
}

fn map_scalar(codepoint: u21) ?u21 {
    if (in_ranges(codepoint, &data.spaces)) return 0x20;
    if (in_ranges(codepoint, &data.nothing)) return null;
    return codepoint;
}

fn validate_mapped(input: []const u8) SqlError!void {
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidValue;
    var iterator = view.iterator();
    var has_randal = false;
    var has_lcat = false;
    var first: ?u21 = null;
    var last: u21 = 0;
    while (iterator.nextCodepoint()) |original| {
        const mapped = map_scalar(original) orelse continue;
        if (in_ranges(mapped, &data.prohibited) or in_ranges(mapped, &data.unassigned)) return error.InvalidValue;
        has_randal = has_randal or in_ranges(mapped, &data.randal);
        has_lcat = has_lcat or in_ranges(mapped, &data.lcat);
        if (first == null) first = mapped;
        last = mapped;
    }
    if (first == null) return error.InvalidValue;
    if (!has_randal) return;
    if (has_lcat or !in_ranges(first.?, &data.randal) or !in_ranges(last, &data.randal)) return error.InvalidValue;
}

fn decompose(codepoint: u21, scratch: []u21, count: *usize) SqlError!void {
    if (codepoint >= 0xac00 and codepoint <= 0xd7a3) {
        const index = @as(u32, codepoint) - 0xac00;
        try ordered_append(scratch, count, @intCast(0x1100 + index / 588));
        try ordered_append(scratch, count, @intCast(0x1161 + index % 588 / 28));
        if (index % 28 != 0) try ordered_append(scratch, count, @intCast(0x11a7 + index % 28));
        return;
    }
    const entry = find_decomposition(codepoint) orelse {
        try ordered_append(scratch, count, codepoint);
        return;
    };
    const offset: usize = @intCast(entry & 0xffffff);
    const length: usize = @intCast(entry >> 24 & 0xff);
    for (data.digits[offset..][0..length]) |scalar| try ordered_append(scratch, count, scalar);
}

fn ordered_append(scratch: []u21, count: *usize, codepoint: u21) SqlError!void {
    if (count.* == scratch.len) return error.BufferTooSmall;
    var index = count.*;
    const class = combining_class(codepoint);
    while (index > 0 and class != 0) {
        const previous_class = combining_class(scratch[index - 1]);
        if (previous_class == 0 or previous_class <= class) break;
        scratch[index] = scratch[index - 1];
        index -= 1;
    }
    scratch[index] = codepoint;
    count.* += 1;
}

fn compose(codepoints: []u21) []const u21 {
    var starter: ?usize = null;
    var last_class: u8 = 0;
    var count: usize = 0;
    for (codepoints) |scalar| {
        const class = combining_class(scalar);
        const combined = if (starter != null and (last_class == 0 or last_class < class))
            composite(codepoints[starter.?], scalar)
        else
            null;
        if (combined) |value| {
            codepoints[starter.?] = value;
            continue;
        }
        if (class == 0) starter = count;
        last_class = class;
        codepoints[count] = scalar;
        count += 1;
    }
    return codepoints[0..count];
}

fn composite(first: u21, second: u21) ?u21 {
    if (first >= 0x1100 and first <= 0x1112 and second >= 0x1161 and second <= 0x1175) {
        return @intCast(0xac00 + (@as(u32, first) - 0x1100) * 588 + (@as(u32, second) - 0x1161) * 28);
    }
    if (first >= 0xac00 and first <= 0xd7a3 and (first - 0xac00) % 28 == 0 and second >= 0x11a8 and second <= 0x11c2) {
        return @intCast(@as(u32, first) + second - 0x11a7);
    }
    const key = @as(u64, first) << 21 | second;
    var low: usize = 0;
    var high: usize = data.compositions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = data.compositions[mid];
        const found = entry >> 21;
        if (found == key) return @intCast(entry & 0x1fffff);
        if (found < key) low = mid + 1 else high = mid;
    }
    return null;
}

fn find_decomposition(codepoint: u21) ?u64 {
    var low: usize = 0;
    var high: usize = data.decompositions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = data.decompositions[mid];
        const found = entry >> 32;
        if (found == codepoint) return entry;
        if (found < codepoint) low = mid + 1 else high = mid;
    }
    return null;
}

fn combining_class(codepoint: u21) u8 {
    var low: usize = 0;
    var high: usize = data.combining.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = data.combining[mid];
        const found = entry >> 8;
        if (found == codepoint) return @intCast(entry & 0xff);
        if (found < codepoint) low = mid + 1 else high = mid;
    }
    return 0;
}

fn in_ranges(codepoint: u21, ranges: []const u64) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (codepoint < range >> 32) {
            high = mid;
            continue;
        }
        if (codepoint <= range & 0xffffffff) return true;
        low = mid + 1;
    }
    return false;
}

fn validate(codepoints: []const u21) SqlError!void {
    var has_randal = false;
    var has_lcat = false;
    for (codepoints) |codepoint| {
        if (in_ranges(codepoint, &data.prohibited) or in_ranges(codepoint, &data.unassigned)) return error.InvalidValue;
        has_randal = has_randal or in_ranges(codepoint, &data.randal);
        has_lcat = has_lcat or in_ranges(codepoint, &data.lcat);
    }
    if (!has_randal) return;
    if (has_lcat or !in_ranges(codepoints[0], &data.randal) or !in_ranges(codepoints[codepoints.len - 1], &data.randal)) return error.InvalidValue;
}
