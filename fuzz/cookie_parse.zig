const std = @import("std");
const support = @import("fuzz_support");

const cookie = support.cookie;

const max_input_size = 4096;

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;

    const jar = cookie.CookieJar.parse(input);
    if (jar.count > cookie.max_cookies) @panic("cookie jar overflowed its capacity");

    var pair_count: usize = 0;
    var pairs = jar.pairs();
    while (pairs.next()) |pair| {
        pair_count += 1;
        if (!slice_within_input(input, pair.name)) @panic("cookie name escaped input buffer");
        if (!slice_within_input(input, pair.value)) @panic("cookie value escaped input buffer");
    }
    if (pair_count != jar.count) @panic("cookie jar iterator count mismatch");
    if (jar.at(jar.count) != null) @panic("cookie jar at() escaped its count");

    // The scalar iterator is the reference for the bounded prefix: while the
    // jar is below capacity it must agree pair for pair.
    var scalar = cookie.iterator(input);
    var index: usize = 0;
    while (index < jar.count) : (index += 1) {
        const expected = scalar.next() orelse @panic("cookie jar accepted a pair the scalar parser rejects");
        const stored = jar.at(index).?;
        if (!std.mem.eql(u8, expected.name, stored.name)) @panic("cookie jar name mismatch");
        if (!std.mem.eql(u8, expected.value, stored.value)) @panic("cookie jar value mismatch");
    }
    if (jar.count < cookie.max_cookies and scalar.next() != null) {
        @panic("cookie jar dropped a pair before reaching capacity");
    }
}

export fn LLVMFuzzerTestOneInput(
    data: [*]const u8,
    size: usize,
) callconv(.c) c_int {
    if (size <= max_input_size) fuzz_one(data[0..size]);
    return 0;
}

/// Every borrowed slice, including an empty value, must point inside the
/// parsed input.
fn slice_within_input(input: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(input.ptr);
    const end = start + input.len;
    const slice_start = @intFromPtr(slice.ptr);
    return slice_start >= start and slice_start + slice.len <= end;
}
