//! Tests for status, error-response, negotiation, and cache helpers.

const std = @import("std");
const support = @import("test_support");

const Request = support.http_request.Request;
const Response = support.http_response.Response;
const status = support.status;
const errors = support.errors;
const negotiate = support.negotiate;
const cache = support.cache;

/// Minimal HTTP/3 target that records one response for assertions.
const ResponseCapture = struct {
    status: [64]u8 = undefined,
    status_len: usize = 0,
    headers: [512]u8 = undefined,
    headers_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    chunks: [512]u8 = undefined,
    chunks_len: usize = 0,
    begun: bool = false,
    finished: bool = false,

    fn target(self: *ResponseCapture) support.http_response.Http3Target {
        return .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        };
    }

    fn end(context: *anyopaque, response_status: []const u8, headers: []const u8, body: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (response_status.len > self.status.len or headers.len > self.headers.len or body.len > self.body.len) {
            return error.BufferOverflow;
        }
        @memcpy(self.status[0..response_status.len], response_status);
        self.status_len = response_status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        @memcpy(self.body[0..body.len], body);
        self.body_len = body.len;
        self.finished = true;
    }

    fn begin(context: *anyopaque, response_status: []const u8, headers: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (response_status.len > self.status.len or headers.len > self.headers.len) return error.BufferOverflow;
        @memcpy(self.status[0..response_status.len], response_status);
        self.status_len = response_status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        self.begun = true;
    }

    fn write(context: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (chunk.len > self.chunks.len - self.chunks_len) return error.BufferOverflow;
        @memcpy(self.chunks[self.chunks_len..][0..chunk.len], chunk);
        self.chunks_len += chunk.len;
    }

    fn finish(context: *anyopaque) anyerror!void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        self.finished = true;
    }

    fn status_line(self: *const ResponseCapture) []const u8 {
        return self.status[0..self.status_len];
    }

    fn header_bytes(self: *const ResponseCapture) []const u8 {
        return self.headers[0..self.headers_len];
    }

    fn body_bytes(self: *const ResponseCapture) []const u8 {
        return self.body[0..self.body_len];
    }
};

/// Fills `request` with exactly one header entry.
fn set_single_header(request: *Request, name: []const u8, value: []const u8) void {
    request.* = .{};
    request.header_names[0] = name;
    request.header_values[0] = value;
    request.header_count = 1;
}

test "helpers: status line covers every declared code with canonical numbers" {
    const codes = std.enums.values(status.StatusCode);
    try std.testing.expect(codes.len >= 29);
    for (codes) |code| {
        const line = status.line(code);
        var prefix_buffer: [8]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{d} ", .{@intFromEnum(code)});
        try std.testing.expect(std.mem.startsWith(u8, line, prefix));
        try std.testing.expect(line.len > prefix.len);
        for (line) |byte| {
            try std.testing.expect(byte >= 32 and byte != 127);
        }
    }
}

test "helpers: status lines match canonical reason phrases at category boundaries" {
    try std.testing.expectEqualStrings("200 OK", status.line(.ok));
    try std.testing.expectEqualStrings("204 No Content", status.line(.no_content));
    try std.testing.expectEqualStrings("304 Not Modified", status.line(.not_modified));
    try std.testing.expectEqualStrings("400 Bad Request", status.line(.bad_request));
    try std.testing.expectEqualStrings("413 Content Too Large", status.line(.content_too_large));
    try std.testing.expectEqualStrings("422 Unprocessable Entity", status.line(.unprocessable_entity));
    try std.testing.expectEqualStrings("429 Too Many Requests", status.line(.too_many_requests));
    try std.testing.expectEqualStrings("500 Internal Server Error", status.line(.internal_server_error));
    try std.testing.expectEqualStrings("504 Gateway Timeout", status.line(.gateway_timeout));

    try std.testing.expectEqual(@as(u16, 404), @intFromEnum(status.StatusCode.not_found));
    try std.testing.expectEqual(@as(u16, 503), @intFromEnum(status.StatusCode.service_unavailable));
}

test "helpers: error render writes the canonical JSON shape" {
    var buffer: [errors.max_document_bytes]u8 = undefined;
    const document = errors.render("not_found", "Not Found", &buffer);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"not_found\",\"message\":\"Not Found\"}}",
        document,
    );
}

test "helpers: error render escapes JSON metacharacters" {
    var buffer: [errors.max_document_bytes]u8 = undefined;
    const message = "say \"hi\"\\path\nline\ttab";
    const document = errors.render("bad_request", message, &buffer);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"bad_request\",\"message\":\"say \\\"hi\\\"\\\\path\\nline\\ttab\"}}",
        document,
    );
}

test "helpers: error render preserves non-ASCII bytes in valid JSON" {
    var buffer: [errors.max_document_bytes]u8 = undefined;
    const document = errors.render("teapot", "caf\u{00e9} \u{00fc}nicode", &buffer);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"teapot\",\"message\":\"caf\u{00e9} \u{00fc}nicode\"}}",
        document,
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    const body = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("caf\u{00e9} \u{00fc}nicode", body.get("message").?.string);
}

test "helpers: error render falls back to a valid document" {
    var buffer: [8]u8 = undefined;
    const document = errors.render("not_found", "Not Found", &buffer);
    try std.testing.expect(document.len > buffer.len);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    const body = parsed.value.object.get("error").?.object;
    try std.testing.expect(body.get("code") != null);
}

test "helpers: send emits a JSON error through the response target" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try errors.send(&response, .{
        .status = .bad_request,
        .code = "bad_request",
        .message = "Missing field 'name'",
    });

    try std.testing.expectEqualStrings("400 Bad Request", capture.status_line());
    try std.testing.expectEqualStrings(
        "Content-Type: application/json; charset=utf-8\r\n",
        capture.header_bytes(),
    );
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"bad_request\",\"message\":\"Missing field 'name'\"}}",
        capture.body_bytes(),
    );
    try std.testing.expect(capture.finished);
}

test "helpers: send_buf degrades to the fallback document with a small scratch buffer" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    var scratch: [4]u8 = undefined;
    try errors.send_buf(&response, .{
        .status = .not_found,
        .code = "not_found",
        .message = "Not Found",
    }, &scratch);

    try std.testing.expectEqualStrings("404 Not Found", capture.status_line());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.body_bytes(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") != null);
}

test "helpers: method_not_allowed emits the Allow field and rejects CRLF injection" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try errors.method_not_allowed(&response, "GET, POST");

    try std.testing.expectEqualStrings("405 Method Not Allowed", capture.status_line());
    try std.testing.expectEqualStrings(
        "Allow: GET, POST\r\nContent-Type: application/json; charset=utf-8\r\n",
        capture.header_bytes(),
    );
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"Method Not Allowed\"}}",
        capture.body_bytes(),
    );

    var injection_capture = ResponseCapture{};
    var injection_response = Response{ .target = .{ .http3 = injection_capture.target() } };
    try std.testing.expectError(
        error.InvalidHeaders,
        errors.method_not_allowed(&injection_response, "GET\r\nX-Injected: yes"),
    );
    try std.testing.expect(!injection_response.is_started());
}

test "helpers: internal never echoes caller detail" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try errors.internal(&response);

    try std.testing.expectEqualStrings("500 Internal Server Error", capture.status_line());
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"internal\",\"message\":\"Internal Server Error\"}}",
        capture.body_bytes(),
    );
    try std.testing.expect(capture.finished);
}

test "helpers: negotiate parses entries, trims whitespace, and defaults q to 1" {
    const accept = negotiate.parse(" text/html ;q=0.5, application/json");
    try std.testing.expectEqual(@as(usize, 2), accept.count);
    try std.testing.expectEqualStrings("text", accept.entries[0].type);
    try std.testing.expectEqualStrings("html", accept.entries[0].subtype);
    try std.testing.expectEqual(@as(u16, 500), accept.entries[0].quality);
    try std.testing.expectEqual(@as(u16, 1000), accept.entries[1].quality);
}

test "helpers: negotiate prefers exact matches over wildcards" {
    const accept = negotiate.parse("*/*;q=0.4, text/*;q=0.8, text/html;q=0.1");
    try std.testing.expectEqual(@as(u16, 100), negotiate.score(accept, "text/html"));
    try std.testing.expectEqual(@as(u16, 800), negotiate.score(accept, "text/plain"));
    try std.testing.expectEqual(@as(u16, 400), negotiate.score(accept, "application/json"));
    try std.testing.expect(negotiate.accepts(accept, "text/html"));
}

test "helpers: negotiate q=0 rejects a media type" {
    const accept = negotiate.parse("text/html;q=0");
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "text/html"));
    try std.testing.expect(!negotiate.accepts(accept, "text/html"));
}

test "helpers: negotiate drops wildcard subtypes" {
    const accept = negotiate.parse("*/json, text/plain");
    try std.testing.expectEqual(@as(usize, 1), accept.count);
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "application/json"));
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "text/plain"));
}

test "helpers: negotiate compares media types case-insensitively" {
    const accept = negotiate.parse("Application/JSON");
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "application/json"));
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "APPLICATION/json"));

    const lowercase = negotiate.parse("application/json");
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(lowercase, "Application/Json"));
    try std.testing.expect(negotiate.accepts(lowercase, "APPLICATION/JSON"));
}

test "helpers: negotiate empty accept accepts everything" {
    const accept = negotiate.parse("");
    try std.testing.expectEqual(@as(usize, 0), accept.count);
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "application/json"));
    try std.testing.expect(negotiate.accepts(accept, "application/json"));

    const offers = [_][]const u8{ "text/plain", "application/json" };
    try std.testing.expectEqualStrings("text/plain", negotiate.best(accept, &offers).?);

    const blank = negotiate.parse(" , , ");
    try std.testing.expectEqual(@as(usize, 0), blank.count);
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(blank, "image/png"));
}

test "helpers: negotiate drops malformed entries and ignores non-q parameters" {
    const accept = negotiate.parse(
        "garbage, text/plain;q=abc, text/html;level=1, application/json;charset=utf-8;q=0.25",
    );
    try std.testing.expectEqual(@as(usize, 2), accept.count);
    try std.testing.expectEqualStrings("html", accept.entries[0].subtype);
    try std.testing.expectEqual(@as(u16, 1000), accept.entries[0].quality);
    try std.testing.expectEqual(@as(u16, 250), accept.entries[1].quality);
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "text/plain"));
    try std.testing.expect(negotiate.accepts(accept, "text/html"));
    try std.testing.expect(negotiate.accepts(accept, "application/json"));

    const bad_quality = negotiate.parse(
        "text/html;q=2, text/plain;q=0.1234, text/css;q=1.5, text/xml;q=.5, text/csv;q",
    );
    try std.testing.expectEqual(@as(usize, 0), bad_quality.count);
}

test "helpers: negotiate ignores entries past fixed capacity" {
    const header = "text/plain,text/plain,text/plain,text/plain," ++
        "text/plain,text/plain,text/plain,text/plain," ++
        "text/plain,text/plain,text/plain,text/plain," ++
        "text/plain,text/plain,text/plain,text/plain," ++
        "application/json";
    const accept = negotiate.parse(header);
    try std.testing.expectEqual(@as(usize, negotiate.max_entries), accept.count);
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "application/json"));
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "text/plain"));
}

test "helpers: negotiate best picks the highest quality and rejects the rest" {
    const accept = negotiate.parse("text/plain;q=0.3, application/json;q=0.9");
    const offers = [_][]const u8{ "text/plain", "application/json" };
    try std.testing.expectEqualStrings("application/json", negotiate.best(accept, &offers).?);

    const rejected = negotiate.parse("application/json");
    const other_offers = [_][]const u8{ "text/plain", "text/html" };
    try std.testing.expect(negotiate.best(rejected, &other_offers) == null);

    const tied = negotiate.parse("text/*");
    const text_offers = [_][]const u8{ "text/plain", "text/html" };
    try std.testing.expectEqualStrings("text/plain", negotiate.best(tied, &text_offers).?);
}

test "helpers: etag is deterministic, quoted, and lowercase hex" {
    var first: cache.EtagBuffer = undefined;
    var second: cache.EtagBuffer = undefined;
    var third: cache.EtagBuffer = undefined;

    const tag = cache.etag("hello world", &first);
    try std.testing.expectEqualStrings(tag, cache.etag("hello world", &second));
    try std.testing.expectEqual(@as(usize, 18), tag.len);
    try std.testing.expectEqual(@as(u8, '"'), tag[0]);
    try std.testing.expectEqual(@as(u8, '"'), tag[17]);
    for (tag[1..17]) |byte| {
        try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }

    const other = cache.etag("hello world!", &third);
    try std.testing.expect(!std.mem.eql(u8, tag, other));
}

test "helpers: is_not_modified matches exact, weak, list, and star validators" {
    var request = Request{};
    set_single_header(&request, "If-None-Match", "\"abc\"");
    try std.testing.expect(cache.is_not_modified(&request, "\"abc\""));
    try std.testing.expect(!cache.is_not_modified(&request, "\"other\""));

    set_single_header(&request, "If-None-Match", "W/\"abc\"");
    try std.testing.expect(cache.is_not_modified(&request, "\"abc\""));
    set_single_header(&request, "If-None-Match", "\"abc\"");
    try std.testing.expect(cache.is_not_modified(&request, "W/\"abc\""));

    set_single_header(&request, "If-None-Match", "\"one\", \"two\" , W/\"three\"");
    try std.testing.expect(cache.is_not_modified(&request, "\"two\""));
    try std.testing.expect(cache.is_not_modified(&request, "\"three\""));
    try std.testing.expect(!cache.is_not_modified(&request, "\"four\""));

    set_single_header(&request, "if-none-match", "*");
    try std.testing.expect(cache.is_not_modified(&request, "\"anything\""));

    var empty = Request{};
    try std.testing.expect(!cache.is_not_modified(&empty, "\"abc\""));
    try std.testing.expect(!cache.is_not_modified(&empty, ""));
}

test "helpers: is_not_modified scans every If-None-Match field case-insensitively" {
    var request = Request{};
    request.header_names[0] = "Accept";
    request.header_values[0] = "*/*";
    request.header_names[1] = "if-none-match";
    request.header_values[1] = "\"one\"";
    request.header_names[2] = "If-None-Match";
    request.header_values[2] = "\"two\"";
    request.header_count = 3;

    try std.testing.expect(cache.is_not_modified(&request, "\"two\""));
    try std.testing.expect(!cache.is_not_modified(&request, "\"three\""));
}

test "helpers: not_modified emits 304 with an ETag and empty body" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try cache.not_modified(&response, "\"0123456789abcdef\"");

    try std.testing.expectEqualStrings("304 Not Modified", capture.status_line());
    try std.testing.expectEqualStrings("ETag: \"0123456789abcdef\"\r\n", capture.header_bytes());
    try std.testing.expectEqual(@as(usize, 0), capture.body_len);
    try std.testing.expect(capture.finished);

    var injection_capture = ResponseCapture{};
    var injection_response = Response{ .target = .{ .http3 = injection_capture.target() } };
    try std.testing.expectError(
        error.InvalidHeaders,
        cache.not_modified(&injection_response, "\"abc\"\r\nX-Injected: yes"),
    );
    try std.testing.expect(!injection_response.is_started());
}
