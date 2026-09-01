const target = @import("quic_packets.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "\x00",
        "\x40\x25",
        "\x80\x00\x40\x00",
        "\xc0\x00\x00\x00\x00\x00\x00\x01payload",
        "\x54\x00capsule",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
