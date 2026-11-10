const std = @import("std");
const simd = @import("../core/simd.zig");
const body_decoder = @import("body_decoder.zig");
const fetch = @import("fetch.zig");
/// Request view populated by `consume`.
pub const Request = @import("request.zig").Request;

/// Incremental state of the bounded HTTP/1.1 request parser.
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
    error_headers_too_large,
    error_too_large,
};

/// Maximum accepted request-line length in bytes.
pub const max_request_line_size = 8 * 1024;
/// Maximum accepted header block length in bytes.
pub const max_header_size = 16 * 1024;
/// Default maximum accepted fixed or decoded chunked body length in bytes.
pub const default_max_body_size = 16 * 1024;
/// Default body limit kept for callers that do not configure a policy.
pub const max_body_size = default_max_body_size;

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn is_decimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Routeable path and query derived from one request target.
const TargetView = struct {
    path: []const u8,
    query: []const u8,
};

/// Maps one RFC 9112 request-target to its routeable path and query.
///
/// Origin-form and absolute-form carry a path; asterisk-form is legal only
/// for OPTIONS and routes as the literal `*`. Authority-form (CONNECT),
/// unknown schemes, fragments, and userinfo fail closed because the router
/// has no authority view to match against.
fn parse_request_target(method: []const u8, target: []const u8) ?TargetView {
    if (target.len == 0) return null;
    for (target) |c| {
        if (c < 32 or c == 127) return null;
    }
    if (target[0] == '/') return split_target_query(target);
    if (std.mem.eql(u8, target, "*")) {
        if (!std.mem.eql(u8, method, "OPTIONS")) return null;
        return .{ .path = target, .query = "" };
    }
    return parse_absolute_target(target);
}

/// Splits an origin-form path at its first `?` and rejects fragments.
fn split_target_query(path: []const u8) ?TargetView {
    if (std.mem.indexOfScalar(u8, path, '#') != null) return null;
    if (std.mem.indexOfScalar(u8, path, '?')) |query_start| {
        return .{
            .path = path[0..query_start],
            .query = path[query_start + 1 ..],
        };
    }
    return .{ .path = path, .query = "" };
}

/// Parses an absolute-form `http`/`https` target into path and query.
///
/// RFC 9112 section 3.2.2 requires servers to accept absolute-form; the
/// authority must be present because the router only sees the path. An
/// empty URI path routes as `/`.
fn parse_absolute_target(target: []const u8) ?TargetView {
    if (std.mem.indexOfScalar(u8, target, '#') != null) return null;

    const scheme_end = std.mem.indexOf(u8, target, "://") orelse return null;
    const scheme = target[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and
        !std.ascii.eqlIgnoreCase(scheme, "https"))
    {
        return null;
    }

    const authority_start = scheme_end + "://".len;
    const boundary = std.mem.indexOfAnyPos(u8, target, authority_start, "/?") orelse
        target.len;
    const authority = target[authority_start..boundary];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) {
        return null;
    }
    if (boundary == target.len) return .{ .path = "/", .query = "" };
    if (target[boundary] == '?') {
        return .{ .path = "/", .query = target[boundary + 1 ..] };
    }
    return split_target_query(target[boundary..]);
}

/// Allocation-free incremental HTTP/1.1 parser state.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
    /// Absolute input offset where the next delimiter search resumes.
    scan: usize = 0,
    /// Bytes examined by delimiter searches for the current request.
    scan_work: usize = 0,
    content_length: usize = 0,
    chunk_length: usize = 0,
    body_length: usize = 0,
    body_start: usize = 0,
    /// Per-connection body policy; the owner's request buffer must be at least
    /// this large plus request-line, header, and framing slack.
    max_body_size: usize = default_max_body_size,
    /// Per-connection request-line policy.
    max_request_line_bytes: usize = max_request_line_size,
    /// Per-connection header-block policy.
    max_header_bytes: usize = max_header_size,
    /// Overflow storage for headers beyond the inline `Request` arrays.
    ///
    /// Both slices must be the same length and stay valid for the connection
    /// lifetime; an owner that supplies none fails closed at the inline cap.
    extra_header_names: [][]const u8 = &.{},
    extra_header_values: [][]const u8 = &.{},
    extra_header_count: usize = 0,
};

/// Enters `state` with the next token starting at `offset`.
///
/// The scan cursor restarts at the new token so the previous token's search
/// cannot leak into the next one.
fn enter_state(parser: *HttpParser, state: ParserState, offset: usize) void {
    parser.state = state;
    parser.mark = offset;
    parser.scan = offset;
}

/// Structurally admitted head; its views borrow the caller's header arrays and input.
/// Keep both pinned through streaming admission and the resulting response lifetime.
pub const HeadReady = struct {
    framing: body_decoder.Framing,
    header_end: usize,
    headers: fetch.HeadersView,
};

/// Earliest legacy failure checkpoint, before later provisional fields can mask it.
pub const BufferedHeadFailure = struct {
    state: ParserState,
    content_length: usize,
    header_count: usize,
    extra_header_count: usize,
};

/// A ready head precedes body policy and payload, even when all bytes arrived together.
/// A failed structural scan still carries an earlier machine-width rejection, if any.
pub const HeadResult = struct {
    consumed: usize = 0,
    ready: ?HeadReady = null,
    buffered_failure: ?BufferedHeadFailure = null,
};

/// Parses only through initial headers, admitting logical u64 lengths provisionally.
/// Select streaming only after ready; buffered fallback must call commit_head on errors too.
/// Do not scan a completed head twice or resume consume before committing buffered policy.
pub fn consume_head(parser: *HttpParser, req: *Request, buffer: []u8) HeadResult {
    switch (parser.state) {
        .method, .path, .protocol, .headers => {},
        else => return .{ .consumed = parser.mark },
    }
    var result = HeadResult{};
    result.consumed = consume_internal(parser, req, buffer, &result);
    return result;
}

fn buffered_checkpoint(parser: *const HttpParser, req: *const Request, state: ParserState) BufferedHeadFailure {
    return .{
        .state = state,
        .content_length = parser.content_length,
        .header_count = req.header_count,
        .extra_header_count = parser.extra_header_count,
    };
}

/// Commits only the borrowed header views needed by a streaming request.
pub fn commit_streaming_head(parser: *HttpParser, req: *Request) void {
    req.extra_header_names = parser.extra_header_names[0..parser.extra_header_count];
    req.extra_header_values = parser.extra_header_values[0..parser.extra_header_count];
    req.extra_header_count = parser.extra_header_count;
}

/// Applies the unchanged buffered policy, committing overflow views only after acceptance.
pub fn commit_head(parser: *HttpParser, req: *Request, result: HeadResult) bool {
    if (result.buffered_failure) |failure| {
        parser.state = failure.state;
        parser.content_length = failure.content_length;
        req.header_count = failure.header_count;
        parser.extra_header_count = failure.extra_header_count;
        return false;
    }
    const head = result.ready orelse return false;
    commit_buffered_head(parser, req, head.header_end, head.framing == .chunked);
    return true;
}

fn commit_buffered_head(parser: *HttpParser, req: *Request, header_end: usize, chunked: bool) void {
    req.extra_header_names = parser.extra_header_names[0..parser.extra_header_count];
    req.extra_header_values = parser.extra_header_values[0..parser.extra_header_count];
    req.extra_header_count = parser.extra_header_count;
    if (chunked) {
        enter_state(parser, .chunk_size, header_end);
        parser.body_start = parser.mark;
        parser.body_length = 0;
        return;
    }
    enter_state(parser, if (parser.content_length > 0) .body else .done, header_end);
}

/// Parses bytes into `req` and returns the prefix consumed by this request.
/// Request slices borrow buffer; chunked bodies compact in place until dispatch completes.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []u8) usize {
    return consume_internal(parser, req, buffer, null);
}

fn consume_internal(parser: *HttpParser, req: *Request, buffer: []u8, head_result: ?*HeadResult) usize {
    while (parser.mark < buffer.len) {
        switch (parser.state) {
            .method => switch (parse_method(parser, req, buffer, parser.scan)) {
                .advanced => {},
                .need_more => return buffer.len,
                .invalid => {
                    parser.state = .error_invalid;
                    return buffer.len;
                },
                .too_large => {
                    parser.state = .error_headers_too_large;
                    return buffer.len;
                },
            },
            .path => switch (parse_path(parser, req, buffer, parser.scan)) {
                .advanced => {},
                .need_more => return buffer.len,
                .invalid => {
                    parser.state = .error_invalid;
                    return buffer.len;
                },
                .too_large => {
                    parser.state = .error_headers_too_large;
                    return buffer.len;
                },
            },
            .protocol => switch (parse_protocol(parser, buffer, parser.scan)) {
                .advanced => {},
                .need_more => return buffer.len,
                .invalid => {
                    parser.state = .error_invalid;
                    return buffer.len;
                },
                .too_large => {
                    parser.state = .error_headers_too_large;
                    return buffer.len;
                },
            },
            .headers => switch (parse_header_block(parser, req, buffer, parser.scan, head_result)) {
                .need_more => return buffer.len,
                .invalid => {
                    parser.state = .error_invalid;
                    return buffer.len;
                },
                .headers_too_large => {
                    parser.state = .error_headers_too_large;
                    return buffer.len;
                },
                .body_too_large => {
                    parser.state = .error_too_large;
                    return buffer.len;
                },
                .ready => |consumed| return consumed,
                .continue_parsing => if (parser.state == .done) return parser.mark,
            },
            .body, .chunk_size, .chunk_ext, .chunk_data, .chunk_crlf, .chunk_trailer => {
                return collect_body(parser, req, buffer);
            },
            .done, .error_invalid, .error_headers_too_large, .error_too_large => return parser.mark,
        }
    }

    return parser.mark;
}

/// One request-line parser outcome; the caller maps it to parser state.
const LineOutcome = enum { advanced, need_more, invalid, too_large };

fn parse_method(parser: *HttpParser, req: *Request, buffer: []u8, search_start: usize) LineOutcome {
    const space = std.mem.indexOfScalar(u8, buffer[search_start..], ' ') orelse {
        const pending = buffer.len - search_start;
        parser.scan_work += pending;
        // Preserve the legacy precedence: a bare CR/LF before the missing
        // space is invalid even when the line is still incomplete.
        if (std.mem.indexOfAny(u8, buffer[search_start..], "\r\n")) |crlf| {
            parser.scan_work += crlf + 1;
            return .invalid;
        }
        if (buffer.len > parser.max_request_line_bytes) return .too_large;
        parser.scan = buffer.len;
        return .need_more;
    };
    parser.scan_work += space + 1;
    const abs_space = search_start + space;
    if (abs_space > parser.max_request_line_bytes) return .too_large;
    if (abs_space == parser.mark) return .invalid;
    for (buffer[parser.mark..abs_space]) |c| {
        if (!is_tchar(c)) return .invalid;
    }
    req.method = buffer[parser.mark..abs_space];
    enter_state(parser, .path, abs_space + 1);
    return .advanced;
}

fn parse_path(parser: *HttpParser, req: *Request, buffer: []u8, search_start: usize) LineOutcome {
    const space = std.mem.indexOfScalar(u8, buffer[search_start..], ' ') orelse {
        const pending = buffer.len - search_start;
        parser.scan_work += pending;
        if (std.mem.indexOfAny(u8, buffer[search_start..], "\r\n")) |crlf| {
            parser.scan_work += crlf + 1;
            return .invalid;
        }
        if (buffer.len > parser.max_request_line_bytes) return .too_large;
        parser.scan = buffer.len;
        return .need_more;
    };
    parser.scan_work += space + 1;
    const abs_space = search_start + space;
    const target = buffer[parser.mark..abs_space];
    if (abs_space > parser.max_request_line_bytes) return .too_large;
    const view = parse_request_target(req.method, target) orelse return .invalid;
    req.target = target;
    req.path = view.path;
    req.query = view.query;
    enter_state(parser, .protocol, abs_space + 1);
    return .advanced;
}

fn parse_protocol(parser: *HttpParser, buffer: []u8, search_start: usize) LineOutcome {
    const newline = std.mem.indexOfScalar(u8, buffer[search_start..], '\n') orelse {
        parser.scan_work += buffer.len - search_start;
        if (buffer.len > parser.max_request_line_bytes) return .too_large;
        parser.scan = buffer.len;
        return .need_more;
    };
    parser.scan_work += newline + 1;
    const abs_newline = search_start + newline;
    if (abs_newline + 1 > parser.max_request_line_bytes) return .too_large;
    if (abs_newline == parser.mark or buffer[abs_newline - 1] != '\r') return .invalid;
    const proto = buffer[parser.mark .. abs_newline - 1];
    if (!std.mem.eql(u8, proto, "HTTP/1.1")) return .invalid;
    enter_state(parser, .headers, abs_newline + 1);
    return .advanced;
}

/// Outcome of one complete initial-header block; the caller owns state changes.
const HeaderOutcome = union(enum) {
    need_more,
    invalid,
    headers_too_large,
    body_too_large,
    ready: usize,
    continue_parsing,
};

/// Parses and validates initial fields, committing either streaming metadata or
/// the buffered parser state. Returns `need_more` with `parser.scan` retained.
fn parse_header_block(
    parser: *HttpParser,
    req: *Request,
    buffer: []u8,
    search_start: usize,
    head_result: ?*HeadResult,
) HeaderOutcome {
    const offset = simd.index_of_header_end(buffer[search_start..]) orelse {
        parser.scan_work += buffer.len - search_start;
        if (buffer.len - parser.mark > parser.max_header_bytes) return .headers_too_large;
        // The four-byte terminator may straddle the delivery boundary.
        parser.scan = @max(parser.mark, buffer.len -| 3);
        return .need_more;
    };
    parser.scan_work += offset + 4;
    const end = search_start + offset;
    if (end - parser.mark > parser.max_header_bytes) return .headers_too_large;

    var lines = std.mem.splitSequence(u8, buffer[parser.mark..end], "\r\n");
    var has_host = false;
    var has_cl = false;
    var has_te = false;
    var cl_too_large = false;
    var logical_length: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .invalid;
        const name = line[0..colon];
        if (name.len == 0) return .invalid;
        for (name) |c| {
            if (!is_tchar(c)) return .invalid;
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
        if (!simd.valid_http_field_value(value)) return .invalid;

        if (std.ascii.eqlIgnoreCase(name, "Host")) {
            if (has_host or value.len == 0) return .invalid;
            has_host = true;
        }

        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (has_te or !std.ascii.eqlIgnoreCase(value, "chunked")) return .invalid;
            has_te = true;
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (has_cl or !is_decimal(value)) return .invalid;
            has_cl = true;
            if (head_result) |result| {
                logical_length = std.fmt.parseInt(u64, value, 10) catch return .invalid;
                if (logical_length > std.math.maxInt(usize)) {
                    result.buffered_failure = buffered_checkpoint(parser, req, .error_invalid);
                } else if (logical_length > parser.max_body_size) {
                    cl_too_large = true;
                } else {
                    parser.content_length = @intCast(logical_length);
                }
            } else {
                const length = std.fmt.parseInt(usize, value, 10) catch return .invalid;
                if (length > parser.max_body_size) {
                    cl_too_large = true;
                } else {
                    parser.content_length = length;
                }
            }
        }

        if (req.header_count >= req.header_names.len) {
            const extra_capacity = @min(parser.extra_header_names.len, parser.extra_header_values.len);
            if (parser.extra_header_count >= extra_capacity) return .headers_too_large;
            parser.extra_header_names[parser.extra_header_count] = name;
            parser.extra_header_values[parser.extra_header_count] = value;
            parser.extra_header_count += 1;
        } else {
            req.header_names[req.header_count] = name;
            req.header_values[req.header_count] = value;
            req.header_count += 1;
        }
    }

    if (!has_host) return .invalid;
    // The framing conflict is invalid regardless of the declared length.
    if (has_te and has_cl) return .invalid;

    if (head_result) |result| {
        if (cl_too_large and result.buffered_failure == null) {
            result.buffered_failure = buffered_checkpoint(parser, req, .error_too_large);
        }
        // RFC 9112 section 6.3: framing is structural; body storage policy follows routing.
        result.ready = .{
            .framing = if (has_te) .chunked else if (has_cl) .{ .content_length = logical_length } else .none,
            .header_end = end + 4,
            .headers = fetch.HeadersView.init_with_extra(
                req.header_names[0..@min(req.header_count, req.header_names.len)],
                req.header_values[0..@min(req.header_count, req.header_values.len)],
                parser.extra_header_names[0..parser.extra_header_count],
                parser.extra_header_values[0..parser.extra_header_count],
            ),
        };
        return .{ .ready = end + 4 };
    }
    if (cl_too_large) return .body_too_large;
    commit_buffered_head(parser, req, end + 4, has_te);
    return .continue_parsing;
}

fn decoder_state(state: ParserState) body_decoder.State {
    return switch (state) {
        .body => .body,
        .chunk_size => .chunk_size,
        .chunk_ext => .chunk_ext,
        .chunk_data => .chunk_data,
        .chunk_crlf => .chunk_crlf,
        .chunk_trailer => .chunk_trailer,
        else => unreachable, // Only body states enter the collector.
    };
}

fn project_decoder(parser: *const HttpParser) body_decoder.BodyDecoder {
    return .{
        .state = decoder_state(parser.state),
        .limits = .{ .max_body_bytes = parser.max_body_size, .max_header_bytes = parser.max_header_bytes, .buffered = true },
        .mark = parser.mark,
        .scan = parser.scan,
        .scan_work = parser.scan_work,
        .chunk_length = parser.chunk_length,
        .body_length = if (parser.state == .body) 0 else parser.body_length,
        .remaining = if (parser.state == .body) parser.content_length else parser.chunk_length,
    };
}

fn store_decoder(parser: *HttpParser, decoder: *const body_decoder.BodyDecoder, fixed: bool) void {
    parser.state = switch (decoder.state) {
        .body => .body,
        .chunk_size => .chunk_size,
        .chunk_ext => .chunk_ext,
        .chunk_data => .chunk_data,
        .chunk_crlf => .chunk_crlf,
        .chunk_trailer => .chunk_trailer,
        .done => .done,
        .error_invalid => .error_invalid,
        .error_too_large => .error_too_large,
    };
    parser.mark = decoder.mark;
    parser.scan = decoder.scan;
    parser.scan_work = decoder.scan_work;
    parser.chunk_length = @intCast(decoder.chunk_length);
    // Fixed-body completion never changed the legacy decoded-chunk counter.
    if (!fixed) parser.body_length = @intCast(decoder.body_length);
}

fn collect_body(parser: *HttpParser, req: *Request, buffer: []u8) usize {
    var decoder = project_decoder(parser);
    const fixed = parser.state == .body;
    const body_start = parser.mark;
    while (decoder.mark < buffer.len) {
        switch (body_decoder.next(&decoder, buffer)) {
            .data => |bytes| {
                if (!fixed) {
                    const start = parser.body_start + @as(usize, @intCast(decoder.body_length));
                    std.mem.copyForwards(u8, buffer[start..][0..bytes.len], bytes);
                }
                // The decoder offered exactly this borrowed prefix.
                body_decoder.accept_payload(&decoder, bytes.len) catch unreachable;
                if (fixed) {
                    req.body = buffer[body_start..decoder.mark];
                    store_decoder(parser, &decoder, fixed);
                    return parser.mark;
                }
            },
            .end => {
                req.body = if (fixed) buffer[body_start..decoder.mark] else buffer[parser.body_start..][0..@intCast(decoder.body_length)];
                store_decoder(parser, &decoder, fixed);
                return parser.mark;
            },
            .need_more, .invalid, .too_large => {
                store_decoder(parser, &decoder, fixed);
                return buffer.len;
            },
        }
    }
    store_decoder(parser, &decoder, fixed);
    return parser.mark;
}

/// Resets parser offsets and lengths before parsing the next request.
pub fn reset(parser: *HttpParser) void {
    parser.extra_header_count = 0;
    parser.state = .method;
    parser.mark = 0;
    parser.scan = 0;
    parser.scan_work = 0;
    parser.content_length = 0;
    parser.chunk_length = 0;
    parser.body_length = 0;
    parser.body_start = 0;
}
