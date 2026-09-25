const target = @import("cookie_parse.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "a=1; b=2",
        "good=1; bad; =novalue; empty=; spaced = 4",
        "session=" ++ ("x" ** 80) ++ "; theme=dark",
        "k=v; " ** 40,
        "\xff\xfe=1; k=\x00",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
