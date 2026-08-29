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
                    for (buffer[parser.mark..abs_space]) |c| {
                        if (c < 32 or c == 127) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    req.method = buffer[parser.mark..abs_space];
                    parser.mark = abs_space + 1;
                    parser.state = .path;
                    i = abs_space + 1;
                } else {
                    if (std.mem.indexOfAny(u8, buffer[i..], "\r\n")) |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    return buffer.len; // need more data
                }
            },
            .path => {
                if (std.mem.indexOfScalar(u8, buffer[i..], ' ')) |space_idx| {
                    const abs_space = i + space_idx;
                    for (buffer[parser.mark..abs_space]) |c| {
                        if (c < 32 or c == 127) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    req.path = buffer[parser.mark..abs_space];
                    parser.mark = abs_space + 1;
                    parser.state = .protocol;
                    i = abs_space + 1;
                } else {
                    if (std.mem.indexOfAny(u8, buffer[i..], "\r\n")) |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    return buffer.len;
                }
            },
            .protocol => {
                if (std.mem.indexOfScalar(u8, buffer[i..], '\n')) |nl_idx| {
                    const abs_nl = i + nl_idx;
                    if (abs_nl > parser.mark and buffer[abs_nl - 1] == '\r') {
                        const proto = buffer[parser.mark .. abs_nl - 1];
                        if (!std.mem.eql(u8, proto, "HTTP/1.1")) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        parser.mark = abs_nl + 1;
                        parser.state = .headers;
                        i = abs_nl + 1;
                    } else {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                } else {
                    return buffer.len;
                }
            },
            .headers => {
                var scan_idx = parser.mark;
                while (std.mem.indexOfScalar(u8, buffer[scan_idx..], '\n')) |nl_offset| {
                    const abs_nl = scan_idx + nl_offset;
                    if (abs_nl == 0 or buffer[abs_nl - 1] != '\r') {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    scan_idx = abs_nl + 1;
                }

                const headers_end = std.mem.indexOfPos(u8, buffer, parser.mark, "\r\n\r\n");
                if (headers_end) |end| {
                    var lines = std.mem.splitSequence(u8, buffer[parser.mark..end], "\r\n");
                    var has_host = false;
                    var has_cl = false;
                    var has_te = false;

                    while (lines.next()) |line| {
                        if (line.len == 0) continue;
                        if (std.mem.indexOf(u8, line, ":")) |colon| {
                            const name = line[0..colon];
                            for (name) |c| {
                                if (c <= 32 or c == 127) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            var val_start = colon + 1;
                            while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) {
                                val_start += 1;
                            }

                            var val_end = line.len;
                            while (val_end > val_start and (line[val_end - 1] == ' ' or line[val_end - 1] == '\t')) {
                                val_end -= 1;
                            }

                            const value = line[val_start..val_end];

                            for (value) |c| {
                                if ((c < 32 and c != '\t') or c == 127) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Host")) {
                                if (has_host) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_host = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                                has_te = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                                if (has_cl) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_cl = true;
                                if (std.fmt.parseInt(usize, value, 10)) |len| {
                                    parser.content_length = len;
                                } else |_| {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            if (req.header_count < req.header_names.len) {
                                req.header_names[req.header_count] = name;
                                req.header_values[req.header_count] = value;
                                req.header_count += 1;
                            }
                        } else {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }

                    if (!has_host) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    if (has_te and has_cl) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    if (has_te) {
                        parser.state = .error_invalid;
                        return buffer.len;
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
