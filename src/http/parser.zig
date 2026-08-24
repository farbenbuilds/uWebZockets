const std = @import("std");
const Request = @import("request.zig").Request;

// finite states of our zero-allocation HTTP parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    header_name,
    header_value,
    done,
    error_invalid,
};

// http parser state data.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
};

// consumes a chunk of bytes, maps them onto the request.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []const u8) usize {
    var i: usize = 0;

    while (i < buffer.len) : (i += 1) {
        const char = buffer[i];

        switch (parser.state) {
            .method => {
                if (char == ' ') {
                    req.method = buffer[parser.mark..i];
                    parser.mark = i + 1;
                    parser.state = .path;
                }
            },
            .path => {
                if (char == ' ') {
                    req.path = buffer[parser.mark..i];
                    parser.mark = i + 1;
                    parser.state = .protocol;
                }
            },
            .done, .error_invalid => return i,
            else => {},
        }
    }

    return i;
}

// resets the state for the next request.
pub fn reset(parser: *HttpParser) void {
    parser.state = .method;
    parser.mark = 0;
}
