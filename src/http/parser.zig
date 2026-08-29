const std = @import("std");
const Request = @import("request.zig").Request;

// finite states of our zero-allocation http parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    headers,
    body,
    done,
    error_invalid,
};

// http parser state data.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
    content_length: usize = 0,
};

// consumes a chunk of bytes, maps them onto the request.
// returns the number of bytes consumed.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []const u8) usize {
    var i: usize = parser.mark;

    while (i < buffer.len) {
        switch (parser.state) {
            .method => {
                if (std.mem.indexOfScalar(u8, buffer[i..], ' ')) |space_idx| {
                    const abs_space = i + space_idx;
                    req.method = buffer[parser.mark..abs_space];
                    parser.mark = abs_space + 1;
                    parser.state = .path;
                    i = abs_space + 1;
                } else {
                    return buffer.len; // need more data
                }
            },
            .path => {
                if (std.mem.indexOfScalar(u8, buffer[i..], ' ')) |space_idx| {
                    const abs_space = i + space_idx;
                    req.path = buffer[parser.mark..abs_space];
                    parser.mark = abs_space + 1;
                    parser.state = .protocol;
                    i = abs_space + 1;
                } else {
                    return buffer.len;
                }
            },
            .protocol => {
                if (std.mem.indexOfScalar(u8, buffer[i..], '\n')) |nl_idx| {
                    const abs_nl = i + nl_idx;
                    parser.mark = abs_nl + 1;
                    parser.state = .headers;
                    i = abs_nl + 1;
                } else {
                    return buffer.len;
                }
            },
            .headers => {
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
                    if (req.get_header("Content-Length")) |cl| {
                        if (std.fmt.parseInt(usize, cl, 10)) |len| {
                            parser.content_length = len;
                        } else |_| {}
                    } else {
                        parser.content_length = 0;
                    }

                    if (parser.content_length > 0) {
                        parser.state = .body;
                        parser.mark = end + 4;
                        i = parser.mark;
                        continue;
                    }

                    parser.state = .done;
                    return end + 4;
                } else {
                    return buffer.len;
                }
            },
            .body => {
                const remaining = buffer.len - parser.mark;
                if (remaining >= parser.content_length) {
                    req.body = buffer[parser.mark .. parser.mark + parser.content_length];
                    parser.state = .done;
                    return parser.mark + parser.content_length;
                } else {
                    return buffer.len;
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
    parser.content_length = 0;
}
