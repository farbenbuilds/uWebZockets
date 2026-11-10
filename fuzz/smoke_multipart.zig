const target = @import("multipart_streaming.zig");

pub fn main() void {
    const seeds = [_][]const u8{
        "",
        "\x00--abc--",
        "\x00preamble\r\n--abc\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ndata\r\n--abc--\r\nepilogue",
        "\x00--abc\r\nContent-Disposition: form-data; name=\"\"\r\n\r\n\r\n--abc--",
        "\x00--abc\r\nContent-Disposition: form-data; name=x\r\n\r\n\r\n--abcX\r\r\n--abc--",
        "\x00--abc\r\nContent-Disposition: form-data; name=x; name=y\r\n\r\nx\r\n--abc--",
        "\x00--abc\r\nContent-Disposition: form-data; name=x\r\n\r\ntruncated",
        "\x01--" ++ ("b" ** 70) ++ "\r\nContent-Disposition: form-data; name=x\r\n\r\ndata\r\n--" ++ ("b" ** 70) ++ "--",
        "\x02--abc\r\nContent-Disposition: form-data; name=x\r\n\r\npayload\r\n--abc--",
        "\x10--abc\r\nContent-Disposition: form-data; name=x\r\n\r\nx\r\n--abc--",
        "\x00" ++ ("--abc\r\nContent-Disposition: form-data; name=x\r\n\r\nx\r\n" ** 34) ++ "--abc--",
        "\x00--abc\r\nContent-Disposition: form-data; name=x\r\n\r\n" ++ ("large" ** 1000) ++ "\r\n--abc--",
    };
    for (seeds) |seed| {
        target.fuzz_one(seed);
        for (0..seed.len) |end| target.fuzz_one(seed[0..end]);
    }
}
