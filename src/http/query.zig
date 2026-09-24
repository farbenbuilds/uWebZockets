//! Zero-allocation query-string parsing over request and URL buffers.
//!
//! Keys and values are raw byte slices into the caller's buffer: nothing is
//! copied, decoded, or allocated. Percent escapes stay intact so lookups use
//! the on-the-wire spelling; `percent_decode` and `form_decode` materialize
//! decoded text in a caller-owned scratch buffer when needed.

const std = @import("std");
const simd = @import("../core/simd.zig");

/// Maximum number of key/value pairs retained by one `QueryParams` view.
pub const max_params = 32;

/// Failures raised while slicing a query string.
pub const ParseError = error{
    TooManyQueryParameters,
    QueryComponentTooLong,
};

/// Failures raised while turning escapes into decoded bytes.
pub const DecodeError = error{
    InvalidPercentEncoding,
    NoSpaceLeft,
};

/// One borrowed raw key/value pair.
pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

/// Fixed-capacity struct-of-arrays view over borrowed query components.
///
/// Slices point into the original URL or body buffer and remain valid exactly
/// as long as that buffer does. A component without `=` parses as an empty
/// value; empty segments and empty keys are skipped. More than `max_params`
/// pairs fail closed with `error.TooManyQueryParameters` rather than silently
/// dropping data.
pub const QueryParams = struct {
    key_ptrs: [max_params][*]const u8 = undefined,
    key_lens: [max_params]u32 = undefined,
    value_ptrs: [max_params][*]const u8 = undefined,
    value_lens: [max_params]u32 = undefined,
    count: usize = 0,

    /// Parses `key=value` components after the first `?` in `target`.
    ///
    /// The `?` is located with a vectorized scan; the preceding path bytes are
    /// never copied.
    pub fn parse_link(target: []const u8) ParseError!QueryParams {
        const mark = simd.index_of_byte(target, '?') orelse return .{};
        return parse(target[mark + 1 ..]);
    }

    /// Parses raw `key=value` components separated by `&` without allocating.
    pub fn parse(query: []const u8) ParseError!QueryParams {
        var result = QueryParams{};
        var rest = query;

        while (rest.len != 0) {
            const separator = simd.index_of_byte(rest, '&') orelse rest.len;
            const segment = rest[0..separator];
            rest = if (separator == rest.len) "" else rest[separator + 1 ..];
            if (segment.len == 0) continue;

            const equals = simd.index_of_byte(segment, '=');
            const key = if (equals) |index| segment[0..index] else segment;
            if (key.len == 0) continue;
            const value = if (equals) |index| segment[index + 1 ..] else "";
            if (result.count == max_params) return error.TooManyQueryParameters;
            try result.push(key, value);
        }
        return result;
    }

    /// Returns the pair at `index`, or null when out of range.
    pub fn at(self: *const QueryParams, index: usize) ?Pair {
        if (index >= self.count) return null;
        return .{
            .key = self.key_ptrs[index][0..@as(usize, self.key_lens[index])],
            .value = self.value_ptrs[index][0..@as(usize, self.value_lens[index])],
        };
    }

    /// Returns the first raw value whose raw key matches `name` byte-exactly.
    pub fn get(self: *const QueryParams, name: []const u8) ?[]const u8 {
        for (0..self.count) |index| {
            const pair = self.at(index).?;
            if (std.mem.eql(u8, pair.key, name)) return pair.value;
        }
        return null;
    }

    /// Returns the last raw value whose raw key matches `name` byte-exactly.
    pub fn get_last(self: *const QueryParams, name: []const u8) ?[]const u8 {
        var index = self.count;
        while (index != 0) {
            index -= 1;
            const pair = self.at(index).?;
            if (std.mem.eql(u8, pair.key, name)) return pair.value;
        }
        return null;
    }

    /// Reports whether any raw key matches `name` byte-exactly.
    pub fn has(self: *const QueryParams, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Counts raw keys matching `name` byte-exactly.
    pub fn count_named(self: *const QueryParams, name: []const u8) usize {
        var matches: usize = 0;
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.at(index).?.key, name)) matches += 1;
        }
        return matches;
    }

    /// Returns an iterator that borrows this view.
    pub fn pairs(self: *const QueryParams) PairIterator {
        return .{ .params = self };
    }

    fn push(self: *QueryParams, key: []const u8, value: []const u8) ParseError!void {
        const key_len = std.math.cast(u32, key.len) orelse return error.QueryComponentTooLong;
        const value_len = std.math.cast(u32, value.len) orelse return error.QueryComponentTooLong;
        self.key_ptrs[self.count] = key.ptr;
        self.key_lens[self.count] = key_len;
        self.value_ptrs[self.count] = value.ptr;
        self.value_lens[self.count] = value_len;
        self.count += 1;
    }
};

/// Forward iterator over borrowed pairs.
pub const PairIterator = struct {
    params: *const QueryParams,
    index: usize = 0,

    pub fn next(self: *PairIterator) ?Pair {
        const pair = self.params.at(self.index) orelse return null;
        self.index += 1;
        return pair;
    }
};

/// Decodes `%HH` escapes into `scratch`, rejecting malformed escapes.
///
/// The input slice is never modified; `scratch` must be at least
/// `value.len` bytes when every component is percent-encoded.
pub fn percent_decode(value: []const u8, scratch: []u8) DecodeError![]u8 {
    return decode(value, scratch, false);
}

/// Decodes `+` as space and `%HH` escapes into `scratch` (form-urlencoded).
pub fn form_decode(value: []const u8, scratch: []u8) DecodeError![]u8 {
    return decode(value, scratch, true);
}

/// Shared percent-decoding core; `plus_as_space` selects form semantics.
fn decode(value: []const u8, scratch: []u8, plus_as_space: bool) DecodeError![]u8 {
    var written: usize = 0;
    var index: usize = 0;

    while (index < value.len) {
        const byte = value[index];
        if (plus_as_space and byte == '+') {
            if (written == scratch.len) return error.NoSpaceLeft;
            scratch[written] = ' ';
            written += 1;
            index += 1;
            continue;
        }
        if (byte != '%') {
            if (written == scratch.len) return error.NoSpaceLeft;
            scratch[written] = byte;
            written += 1;
            index += 1;
            continue;
        }
        if (value.len - index < 3) return error.InvalidPercentEncoding;
        const high = hex_nibble(value[index + 1]) orelse return error.InvalidPercentEncoding;
        const low = hex_nibble(value[index + 2]) orelse return error.InvalidPercentEncoding;
        if (written == scratch.len) return error.NoSpaceLeft;
        scratch[written] = (high << 4) | low;
        written += 1;
        index += 3;
    }
    return scratch[0..written];
}

fn hex_nibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
