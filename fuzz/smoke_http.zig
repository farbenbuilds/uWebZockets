const target = @import("http_framing.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "invalid",
        "1;x=y\r\nx\r\n0\r\nX: v\r\n\r\nPIPE",
        "0\r\nHost: forbidden\r\n\r\n",
        "100000000\r\nx",
        "10000000000000000\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4294967296\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ntest",
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n",
    };
    for (seeds) |seed| target.fuzz_one(seed);
}
