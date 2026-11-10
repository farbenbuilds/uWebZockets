const std = @import("std");
const support = @import("fuzz_support");

const query = support.query;
const negotiate = support.negotiate;

const max_input_size = 4096;
const scratch_size = 512;
const offers = [_][]const u8{ "application/json", "text/html", "*/*" };

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;
    fuzz_content_coding(input);

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

fn fuzz_content_coding(input: []const u8) void {
    // Only split at a list delimiter; splitting inside a token changes meaning.
    const split = std.mem.indexOfScalar(u8, input, ',') orelse input.len;
    const tail = if (split < input.len) input[split + 1 ..] else "";
    for (0..8) |mask| {
        const available = negotiate.EncodingAvailability{
            .identity = mask & 1 != 0,
            .gzip = mask & 2 != 0,
            .br = mask & 4 != 0,
        };
        const chosen = negotiate.select_encoding(input, available);
        const fields = negotiate.select_encoding_headers(.{
            .names = &.{ "Accept-Encoding", "x-other" },
            .values = &.{ input[0..split], "*;q=0" },
            .extra_names = &.{"aCcEpT-EnCoDiNg"},
            .extra_values = &.{tail},
        }, available);
        if (chosen != fields) @panic("coding field lines differ from their comma-separated value");
        const selected = chosen orelse continue;
        const enabled = switch (selected) {
            .identity => available.identity,
            .gzip => available.gzip,
            .br => available.br,
        };
        if (!enabled) @panic("coding negotiation selected an unavailable representation");
    }

    const refusal = "br;q=0,gzip;q=0,identity;q=0,";
    var blocked: [refusal.len + max_input_size]u8 = undefined;
    @memcpy(blocked[0..refusal.len], refusal);
    @memcpy(blocked[refusal.len..][0..input.len], input);
    if (negotiate.select_encoding(blocked[0 .. refusal.len + input.len], .{ .gzip = true, .br = true }) != null) {
        @panic("coding negotiation erased an explicit refusal");
    }
    for (0..2) |order| {
        if (negotiate.select_encoding_headers(.{
            .names = &.{"Accept-Encoding"},
            .values = &.{if (order == 0) input else refusal},
            .extra_names = &.{"accept-encoding"},
            .extra_values = &.{if (order == 0) refusal else input},
        }, .{ .gzip = true, .br = true }) != null) {
            @panic("coding field lines erased an explicit refusal");
        }
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
