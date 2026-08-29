const std = @import("std");
const Request = @import("request.zig").Request;

// finite states of our zero-allocation http parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    headers,
    body,
    chunk_size,
    chunk_ext,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    done,
    error_invalid,
};

fn isTChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

// http parser state data.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
    content_length: usize = 0,
    chunk_length: usize = 0,
    body_length: usize = 0,
    body_start: usize = 0,
};

// consumes a chunk of bytes, maps them onto the request.
// returns the number of bytes consumed.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []u8) usize {
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
                                if (!isTChar(c)) {
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
                        parser.state = .chunk_size;
                        parser.mark = end + 4;
                        parser.body_start = end + 4;
                        parser.body_length = 0;
                        i = parser.mark;
                        continue;
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
            .chunk_size => {
                if (std.mem.indexOfAny(u8, buffer[parser.mark..], "\r;")) |offset| {
                    const end_idx = parser.mark + offset;
                    const hex_str = buffer[parser.mark..end_idx];
                    if (std.fmt.parseInt(usize, hex_str, 16)) |len| {
                        parser.chunk_length = len;
                        if (buffer[end_idx] == ';') {
                            parser.state = .chunk_ext;
                            parser.mark = end_idx + 1;
                        } else {
                            if (end_idx + 1 < buffer.len) {
                                if (buffer[end_idx + 1] != '\n') {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                if (len == 0) {
                                    parser.state = .chunk_trailer;
                                } else {
                                    parser.state = .chunk_data;
                                }
                                parser.mark = end_idx + 2;
                            } else {
                                return buffer.len; // need more data
                            }
                        }
                        i = parser.mark;
                        continue;
                    } else |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                }
                return buffer.len;
            },
            .chunk_ext => {
                if (std.mem.indexOfScalar(u8, buffer[parser.mark..], '\r')) |offset| {
                    const end_idx = parser.mark + offset;
                    if (end_idx + 1 < buffer.len) {
                        if (buffer[end_idx + 1] != '\n') {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        if (parser.chunk_length == 0) {
                            parser.state = .chunk_trailer;
                        } else {
                            parser.state = .chunk_data;
                        }
                        parser.mark = end_idx + 2;
                        i = parser.mark;
                        continue;
                    } else {
                        return buffer.len;
                    }
                }
                return buffer.len;
            },
            .chunk_data => {
                const available = buffer.len - parser.mark;
                if (available >= parser.chunk_length) {
                    const src = buffer[parser.mark .. parser.mark + parser.chunk_length];
                    const dst = buffer[parser.body_start + parser.body_length .. parser.body_start + parser.body_length + parser.chunk_length];
                    std.mem.copyForwards(u8, dst, src);
                    parser.body_length += parser.chunk_length;
                    parser.mark += parser.chunk_length;
                    parser.state = .chunk_crlf;
                    i = parser.mark;
                    continue;
                }
                return buffer.len;
            },
            .chunk_crlf => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] != '\r' or buffer[parser.mark + 1] != '\n') {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    parser.mark += 2;
                    parser.state = .chunk_size;
                    i = parser.mark;
                    continue;
                }
                return buffer.len;
            },
            .chunk_trailer => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] == '\r' and buffer[parser.mark + 1] == '\n') {
                        req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                        parser.state = .done;
                        return parser.mark + 2;
                    }
                    if (std.mem.indexOfPos(u8, buffer, parser.mark, "\r\n\r\n")) |end_idx| {
                        req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                        parser.state = .done;
                        return end_idx + 4;
                    }
                }
                return buffer.len;
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
    parser.chunk_length = 0;
    parser.body_length = 0;
    parser.body_start = 0;
}
