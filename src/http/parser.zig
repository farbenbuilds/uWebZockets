const std = @import("std");
const Request = @import("request.zig").Request;

// finite states of our zero-allocation http parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    headers,
    done,
    error_invalid,
};

// http parser state data.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
};

// consumes a chunk of bytes, maps them onto the request.
// returns the number of bytes consumed.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []const u8) usize {
    var i: usize = parser.mark;

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
            .protocol => {
                if (char == '\n') {
                    parser.mark = i + 1;
                    parser.state = .headers;
                }
            },
            .headers => {
                // fast path: search for end of headers
                const headers_end = std.mem.indexOfPos(u8, buffer, parser.mark, "\r\n\r\n");
                if (headers_end) |end| {
                    var lines = std.mem.splitSequence(u8, buffer[parser.mark..end], "\r\n");
                    while (lines.next()) |line| {
                        if (std.mem.indexOf(u8, line, ": ")) |colon| {
                            if (req.header_count < req.header_names.len) {
                                req.header_names[req.header_count] = line[0..colon];
                                req.header_values[req.header_count] = line[colon + 2 ..];
                                req.header_count += 1;
                            }
                        }
                    }
                    parser.state = .done;
                    return end + 4;
                } else {
                    return buffer.len; // need more data
                }
            },
            .done, .error_invalid => return i,
        }
    }

    return i;
}

// resets the state for the next request.
pub fn reset(parser: *HttpParser) void {
    parser.state = .method;
    parser.mark = 0;
}
