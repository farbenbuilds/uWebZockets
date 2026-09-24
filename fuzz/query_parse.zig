const std = @import("std");
const support = @import("fuzz_support");

const query = support.query;
const negotiate = support.negotiate;

const max_input_size = 4096;
const scratch_size = 512;
const offers = [_][]const u8{ "application/json", "text/html", "*/*" };

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;

    const params = query.QueryParams.parse_link(input) catch return;
    var scratch: [scratch_size]u8 = undefined;
    var pairs = params.pairs();
    while (pairs.next()) |pair| {
        if (!slice_within_input(input, pair.key)) @panic("query key escaped input buffer");
        if (!slice_within_input(input, pair.value)) @panic("query value escaped input buffer");
        // Decode failures are the expected outcome for hostile input; only the
        // parser slicing guarantees above are under test.
        _ = query.percent_decode(pair.key, &scratch) catch {};
        _ = query.form_decode(pair.value, &scratch) catch {};
    }

    const accept = negotiate.parse(input);
    if (accept.count > negotiate.max_entries) @panic("Accept parser overflowed its capacity");
    if (negotiate.best(accept, &offers)) |offer| {
        if (!offer_is_requested(offer)) @panic("Accept negotiation returned an unknown offer");
    }
}

export fn LLVMFuzzerTestOneInput(
    data: [*]const u8,
    size: usize,
) callconv(.c) c_int {
    if (size <= max_input_size) fuzz_one(data[0..size]);
    return 0;
}

/// Every borrowed slice, including an empty flagged value, must point inside
/// the parsed input; the parser keeps flag values at the segment end.
fn slice_within_input(input: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(input.ptr);
    const end = start + input.len;
    const slice_start = @intFromPtr(slice.ptr);
    return slice_start >= start and slice_start + slice.len <= end;
}

fn offer_is_requested(offer: []const u8) bool {
    for (offers) |candidate| {
        if (std.mem.eql(u8, offer, candidate)) return true;
    }
    return false;
}
