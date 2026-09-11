const std = @import("std");
const support = @import("test_support");
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const fetch = support.fetch;
const streams = support.streams;

test "web standards: Request header and body methods adhere to Fetch API" {
    var req = Request{
        .method = "POST",
        .target = "/api/users?page=1",
        .path = "/api/users",
        .query = "page=1",
        .body = "{\"id\":42,\"name\":\"uWebZockets\"}",
    };
    req.header_names[0] = "Content-Type";
    req.header_values[0] = "application/json";
    req.header_names[1] = "X-Custom";
    req.header_values[1] = "test-value";
    req.header_count = 2;

    // HeadersView
    try std.testing.expect(req.has_header("content-type"));
    try std.testing.expect(req.has_header("X-CUSTOM"));
    try std.testing.expect(!req.has_header("authorization"));

    const headers = req.headers();
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("test-value", headers.get("x-custom").?);

    var it = req.header_entries();
    const first = it.next().?;
    try std.testing.expectEqualStrings("Content-Type", first.name);
    try std.testing.expectEqualStrings("application/json", first.value);
    const second = it.next().?;
    try std.testing.expectEqualStrings("X-Custom", second.name);
    try std.testing.expectEqualStrings("test-value", second.value);
    try std.testing.expect(it.next() == null);

    // Body
    try std.testing.expectEqualStrings("{\"id\":42,\"name\":\"uWebZockets\"}", req.text());
    try std.testing.expectEqualStrings("{\"id\":42,\"name\":\"uWebZockets\"}", req.bytes());
    try std.testing.expectEqualStrings("/api/users?page=1", req.url());

    const User = struct { id: u32, name: []const u8 };
    const parsed = try req.json(User, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 42), parsed.value.id);
    try std.testing.expectEqualStrings("uWebZockets", parsed.value.name);
}

test "web standards: WHATWG Streams zero-allocation BYOB reading and pipe_to" {
    var slice_ctx = streams.SliceReaderContext{
        .data = "Hello WHATWG Streams with zero allocation!",
    };
    var readable = streams.ReadableByteStream{
        .context = &slice_ctx,
        .read_fn = streams.SliceReaderContext.read,
    };

    const Sink = struct {
        buf: [128]u8 = undefined,
        len: usize = 0,
        closed: bool = false,

        fn write(context: *anyopaque, chunk: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.buf[self.len .. self.len + chunk.len], chunk);
            self.len += chunk.len;
        }

        fn close(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }
    };

    var sink = Sink{};
    var writable = streams.WritableByteStream{
        .context = &sink,
        .write_fn = Sink.write,
        .close_fn = Sink.close,
    };

    var transfer_buf: [16]u8 = undefined;
    const total = try streams.pipe_to(&readable, &writable, &transfer_buf);

    try std.testing.expectEqual(@as(usize, 42), total);
    try std.testing.expectEqualStrings("Hello WHATWG Streams with zero allocation!", sink.buf[0..sink.len]);
    try std.testing.expect(sink.closed);
    try std.testing.expect(readable.is_closed());
}

test "web standards: Fetch status helpers" {
    try std.testing.expect(fetch.is_ok(200));
    try std.testing.expect(fetch.is_ok(204));
    try std.testing.expect(!fetch.is_ok(301));
    try std.testing.expect(!fetch.is_ok(404));

    try std.testing.expect(fetch.is_redirect(301));
    try std.testing.expect(fetch.is_redirect(302));
    try std.testing.expect(fetch.is_redirect(307));
    try std.testing.expect(!fetch.is_redirect(200));

    try std.testing.expect(fetch.is_client_error(400));
    try std.testing.expect(fetch.is_client_error(404));
    try std.testing.expect(!fetch.is_client_error(500));

    try std.testing.expect(fetch.is_server_error(500));
    try std.testing.expect(fetch.is_server_error(503));
    try std.testing.expect(!fetch.is_server_error(404));
}

test "web standards: header views truncate mismatched slices safely" {
    const names = [_][]const u8{ "first", "second" };
    const values = [_][]const u8{"value"};
    const headers = fetch.HeadersView.init(&names, &values);

    try std.testing.expectEqualStrings("value", headers.get("first").?);
    try std.testing.expect(headers.get("second") == null);

    var entries = headers.entries();
    _ = entries.next() orelse return error.MissingHeader;
    try std.testing.expect(entries.next() == null);

    var direct = fetch.HeaderIterator{
        .names = &names,
        .values = &values,
    };
    _ = direct.next() orelse return error.MissingHeader;
    try std.testing.expect(direct.next() == null);
}

test "web standards: request helpers preserve borrowed fallback fields" {
    var request = Request{};
    request.header_names[0] = "Connection";
    request.header_values[0] = "keep-alive";
    request.header_count = 1;
    const extra_names = [_][]const u8{ "X-Extra", "Connection" };
    const extra_values = [_][]const u8{ "value", "upgrade" };
    request.extra_header_names = &extra_names;
    request.extra_header_values = &extra_values;
    const param_names = [_][]const u8{"overflow"};
    const param_values = [_][]const u8{"capture"};
    request.extra_param_names = &param_names;
    request.extra_param_values = &param_values;

    try std.testing.expectEqualStrings("value", request.get_header("x-extra").?);
    try std.testing.expectEqual(@as(usize, 2), request.count_headers("connection"));
    try std.testing.expect(request.header_has_token("connection", "upgrade"));
    try std.testing.expectEqualStrings("capture", request.get_param("overflow").?);

    var entries = request.header_entries();
    try std.testing.expectEqualStrings("Connection", entries.next().?.name);
    try std.testing.expectEqualStrings("X-Extra", entries.next().?.name);
    try std.testing.expectEqualStrings("Connection", entries.next().?.name);
    try std.testing.expect(entries.next() == null);
}

test "web standards: pipe rejects an invalid callback byte count" {
    const InvalidReader = struct {
        cancelled: bool = false,

        fn read(_: *anyopaque, dest: []u8) anyerror!usize {
            return dest.len + 1;
        }

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancelled = true;
        }
    };
    const Sink = struct {
        fn write(_: *anyopaque, _: []const u8) anyerror!void {}
        fn close(_: *anyopaque) anyerror!void {}
    };

    var source = InvalidReader{};
    var reader = streams.ReadableByteStream{
        .context = &source,
        .read_fn = InvalidReader.read,
        .close_fn = InvalidReader.close,
    };
    var sink_context: u8 = 0;
    var writer = streams.WritableByteStream{
        .context = &sink_context,
        .write_fn = Sink.write,
        .close_fn = Sink.close,
    };
    var buffer: [8]u8 = undefined;

    try std.testing.expectError(
        error.InvalidReadCount,
        streams.pipe_to(&reader, &writer, &buffer),
    );
    try std.testing.expect(source.cancelled);
}

test "web standards: pipe closes both sides after a write failure" {
    var source = streams.SliceReaderContext{ .data = "payload" };
    const Sink = struct {
        closed: bool = false,

        fn write(_: *anyopaque, _: []const u8) anyerror!void {
            return error.WriteFailed;
        }

        fn close(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }
    };

    var reader = streams.ReadableByteStream{
        .context = &source,
        .read_fn = streams.SliceReaderContext.read,
    };
    var sink = Sink{};
    var writer = streams.WritableByteStream{
        .context = &sink,
        .write_fn = Sink.write,
        .close_fn = Sink.close,
    };
    var buffer: [8]u8 = undefined;

    try std.testing.expectError(error.WriteFailed, streams.pipe_to(&reader, &writer, &buffer));
    try std.testing.expect(sink.closed);
}

test "web standards: pipe does not retry a failed close" {
    var source = streams.SliceReaderContext{ .data = "payload" };
    const Sink = struct {
        close_count: usize = 0,

        fn write(_: *anyopaque, _: []const u8) anyerror!void {}

        fn close(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.close_count += 1;
            return error.CloseFailed;
        }
    };

    var reader = streams.ReadableByteStream{
        .context = &source,
        .read_fn = streams.SliceReaderContext.read,
    };
    var sink = Sink{};
    var writer = streams.WritableByteStream{
        .context = &sink,
        .write_fn = Sink.write,
        .close_fn = Sink.close,
    };
    var buffer: [8]u8 = undefined;

    try std.testing.expectError(error.CloseFailed, streams.pipe_to(&reader, &writer, &buffer));
    try std.testing.expectEqual(@as(usize, 1), sink.close_count);
}

const ResponseSink = struct {
    status: [32]u8 = undefined,
    status_len: usize = 0,
    headers: [256]u8 = undefined,
    headers_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    chunks: [512]u8 = undefined,
    chunks_len: usize = 0,
    begun: bool = false,
    finished: bool = false,

    fn end_fn(context: *anyopaque, status: []const u8, headers: []const u8, body: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        @memcpy(self.status[0..status.len], status);
        self.status_len = status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        @memcpy(self.body[0..body.len], body);
        self.body_len = body.len;
    }

    fn begin_fn(context: *anyopaque, status: []const u8, headers: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        @memcpy(self.status[0..status.len], status);
        self.status_len = status.len;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        self.begun = true;
    }

    fn write_fn(context: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        @memcpy(self.chunks[self.chunks_len .. self.chunks_len + chunk.len], chunk);
        self.chunks_len += chunk.len;
    }

    fn finish_fn(context: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.finished = true;
    }
};

test "web standards: Response helper methods format standard Web responses" {
    var sink = ResponseSink{};
    var res = Response{
        .target = .{
            .http3 = .{
                .context = &sink,
                .end_fn = ResponseSink.end_fn,
                .begin_fn = ResponseSink.begin_fn,
                .write_fn = ResponseSink.write_fn,
                .finish_fn = ResponseSink.finish_fn,
            },
        },
    };

    // text
    try res.text("Hello World");
    try std.testing.expectEqualStrings("200 OK", sink.status[0..sink.status_len]);
    try std.testing.expectEqualStrings("Content-Type: text/plain; charset=utf-8\r\n", sink.headers[0..sink.headers_len]);
    try std.testing.expectEqualStrings("Hello World", sink.body[0..sink.body_len]);

    // reset for next test
    res.state = .idle;
    sink = ResponseSink{};
    try res.html("<h1>Hello</h1>");
    try std.testing.expectEqualStrings("Content-Type: text/html; charset=utf-8\r\n", sink.headers[0..sink.headers_len]);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", sink.body[0..sink.body_len]);

    // json_buf zero-allocation
    res.state = .idle;
    sink = ResponseSink{};
    var json_buf: [128]u8 = undefined;
    try res.json_buf(.{ .status = "ok", .count = @as(u32, 5) }, &json_buf);
    try std.testing.expectEqualStrings("Content-Type: application/json; charset=utf-8\r\n", sink.headers[0..sink.headers_len]);
    try std.testing.expect(std.mem.indexOf(u8, sink.body[0..sink.body_len], "\"status\":\"ok\"") != null);

    // json with allocator
    res.state = .idle;
    sink = ResponseSink{};
    try res.json(.{ .message = "allocated" }, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, sink.body[0..sink.body_len], "\"message\":\"allocated\"") != null);

    // redirect
    res.state = .idle;
    sink = ResponseSink{};
    try res.redirect("https://example.com/login", 307);
    try std.testing.expectEqualStrings("307 Temporary Redirect", sink.status[0..sink.status_len]);
    try std.testing.expectEqualStrings("Location: https://example.com/login\r\n", sink.headers[0..sink.headers_len]);

    res.state = .idle;
    try std.testing.expectError(
        error.InvalidHeaders,
        res.redirect("https://example.com/\r\nX-Injected: yes", 302),
    );
}

test "web standards: Response.writable_stream pipes stream chunks into chunked HTTP response" {
    var sink = ResponseSink{};
    var res = Response{
        .target = .{
            .http3 = .{
                .context = &sink,
                .end_fn = ResponseSink.end_fn,
                .begin_fn = ResponseSink.begin_fn,
                .write_fn = ResponseSink.write_fn,
                .finish_fn = ResponseSink.finish_fn,
            },
        },
    };

    var stream = res.writable_stream();
    try stream.write("part-one; ");
    try stream.write("part-two; ");
    try stream.close();

    try std.testing.expect(sink.begun);
    try std.testing.expect(sink.finished);
    try std.testing.expectEqualStrings("part-one; part-two; ", sink.chunks[0..sink.chunks_len]);
    try std.testing.expect(res.is_complete());
}
