const std = @import("std");
const mask = @import("fuzz_support").ws_mask;

const prefix_size = 12;
const max_payload_size = 32 * 1024;

pub fn fuzz_one(input: []const u8) void {
    if (input.len < prefix_size or input.len - prefix_size > max_payload_size) return;

    const key: [4]u8 = input[0..4].*;
    const position = std.mem.readInt(u64, input[4..12], .little);
    const payload = input[prefix_size..];

    var original: [max_payload_size]u8 = undefined;
    var whole: [max_payload_size]u8 = undefined;
    var fragmented: [max_payload_size]u8 = undefined;
    @memcpy(original[0..payload.len], payload);
    @memcpy(whole[0..payload.len], payload);
    @memcpy(fragmented[0..payload.len], payload);

    const split = if (payload.len == 0) 0 else @as(usize, key[0]) % (payload.len + 1);
    mask.apply(whole[0..payload.len], key, position);
    mask.apply(fragmented[0..split], key, position);
    mask.apply(
        fragmented[split..payload.len],
        key,
        position +% @as(u64, @intCast(split)),
    );
    if (!std.mem.eql(u8, whole[0..payload.len], fragmented[0..payload.len])) {
        @panic("fragmented WebSocket masking diverged");
    }

    mask.apply(whole[0..payload.len], key, position);
    if (!std.mem.eql(u8, whole[0..payload.len], original[0..payload.len])) {
        @panic("WebSocket masking is not reversible");
    }
}

export fn LLVMFuzzerTestOneInput(
    data: [*]const u8,
    size: usize,
) callconv(.c) c_int {
    if (size <= prefix_size + max_payload_size) fuzz_one(data[0..size]);
    return 0;
}
