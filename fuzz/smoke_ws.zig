const target = @import("ws_masking.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "key!positionpayload",
        "\x00\x01\x02\x03\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xaa\xbb\xcc\xdd\x07\x00\x00\x00\x00\x00\x00\x00fragmented masking payload",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
