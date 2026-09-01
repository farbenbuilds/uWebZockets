const target = @import("http_framing.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "invalid",
        "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ntest",
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
