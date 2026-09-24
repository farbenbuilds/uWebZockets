const target = @import("query_parse.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "?a=1&b=2",
        "?a=%zz&&=x",
        "?" ++ ("a=1&" ** 40),
        "\xff\xfe?a=1",
        "application/json, text/html;q=0.9, */*;q=0.1",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
