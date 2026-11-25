const target = @import("sql_parse.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",                                           "R\x00\x00\x00\x08\x00\x00\x00\x00",
        "D\x00\x00\x00\x0b\x00\x01\x00\x00\x00\x01x", "T\x00\x00\x00\x06\x00\x00",
        "D\xff\xff\xff\xff",                          "D\x00\x00\x00\x04",
        "1700",                                       "\x0c\x00\x00\x00\x00\xc0\x00\x00\x00",
        "0123456789abcdef" ** 4,                      "0123456789abcdef" ** 3,
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
