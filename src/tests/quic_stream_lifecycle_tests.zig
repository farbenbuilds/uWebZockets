const std = @import("std");
const c = @import("c");
const support = @import("test_support");
const stream = support.quic_stream;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const body = support.request_body;

const FakeStream = struct {
    data: []const u8 = "",
    offset: usize = 0,
    read_shutdowns: usize = 0,
    write_shutdowns: usize = 0,
    closes: usize = 0,
    fail_read_shutdown: bool = false,

    fn from(raw: ?*c.lsquic_stream) *FakeStream {
        return @ptrCast(@alignCast(raw.?));
    }

    fn want(_: ?*c.lsquic_stream, _: c_int) callconv(.c) c_int {
        return 0;
    }

    fn read(raw: ?*c.lsquic_stream, destination: ?*anyopaque, length: usize) callconv(.c) isize {
        const fake = from(raw);
        const count = @min(length, fake.data.len - fake.offset);
        const bytes: [*]u8 = @ptrCast(destination.?);
        @memcpy(bytes[0..count], fake.data[fake.offset..][0..count]);
        fake.offset += count;
        return @intCast(count);
    }

    fn write(_: ?*c.lsquic_stream, _: ?*const anyopaque, length: usize) callconv(.c) isize {
        return @intCast(length);
    }

    fn send_headers(_: ?*c.lsquic_stream, _: [*c]const c.lsquic_http_headers_t, _: c_int) callconv(.c) c_int {
        return 0;
    }

    fn flush(_: ?*c.lsquic_stream) callconv(.c) c_int {
        return 0;
    }

    fn shutdown(raw: ?*c.lsquic_stream, how: c_int) callconv(.c) c_int {
        const fake = from(raw);
        if (how != 1) {
            fake.read_shutdowns += 1;
            if (fake.fail_read_shutdown) return -1;
        }
        if (how != 0) fake.write_shutdowns += 1;
        return 0;
    }

    fn close(raw: ?*c.lsquic_stream) callconv(.c) c_int {
        from(raw).closes += 1;
        return 0;
    }

    const io = stream.StreamIo{
        .wantread = want,
        .read = read,
        .wantwrite = want,
        .write = write,
        .send_headers = send_headers,
        .flush = flush,
        .shutdown = shutdown,
        .close = close,
    };
};

const TestStream = stream.stream_with(FakeStream.io, stream.default_capacities);

const Capture = struct {
    fake: *FakeStream = undefined,
    handlers: usize = 0,
    ends: usize = 0,
    cancels: usize = 0,
    header_releases: usize = 0,
    stream_releases: usize = 0,
    read_closed_before_callback: bool = false,
    response_failed: bool = false,
    cancel_reason: ?body.BodyCancelReason = null,

    fn handle(context: *anyopaque, _: *Request, response: *Response) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.handlers += 1;
        capture.read_closed_before_callback = capture.fake.read_shutdowns == 1;
        response.end("200 OK", "ok") catch {
            capture.response_failed = true;
        };
    }

    fn begin(context: *anyopaque, _: *const support.streaming_request.StreamingRequest, _: body.BodyControl) !body.BodyBinding {
        return .{ .context = context, .readiness = .ready };
    }

    fn chunk(_: *anyopaque, input: []const u8) !body.BodyProgress {
        return .{ .consumed = input.len, .readiness = .ready };
    }

    fn end(context: *anyopaque, _: *const support.streaming_request.StreamingRequest, response: *Response) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.ends += 1;
        capture.read_closed_before_callback = capture.fake.read_shutdowns == 1;
        try response.end("200 OK", "ok");
    }

    fn cancel(context: *anyopaque, reason: body.BodyCancelReason) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.cancels += 1;
        capture.cancel_reason = reason;
    }

    fn release_header(context: *anyopaque, _: *stream.HeaderSet) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.header_releases += 1;
    }

    fn release_stream(context: *anyopaque, _: *TestStream) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.stream_releases += 1;
    }
};

const Fixture = struct {
    fake: FakeStream = .{},
    capture: Capture = .{},
    router_bundle: support.radix.DefaultBundle = .{},
    router: support.radix.Router = .{},
    headers: stream.HeaderSet = .{},
    request_headers: [stream.header_capacity]u8 = undefined,
    request_body: [64]u8 = undefined,
    response_body: [64]u8 = undefined,
    response_headers: [stream.response_header_capacity]u8 = undefined,
    quic: TestStream = .{},
    route: body.BodyRoute = undefined,

    fn init(fixture: *Fixture, streaming: bool, data: []const u8) !void {
        fixture.fake.data = data;
        fixture.capture.fake = &fixture.fake;
        fixture.router = try support.radix.Router.init(fixture.router_bundle.storage());
        if (streaming) {
            fixture.route = .{
                .sink = .{ .context = &fixture.capture, .begin = Capture.begin, .chunk = Capture.chunk, .end = Capture.end, .cancel = Capture.cancel },
                .limits = .{ .max_body_bytes = 64, .max_active = 1 },
                .middleware_policy = .headers_only,
            };
            try fixture.router.route_stream(.post, "/", &fixture.route);
        } else {
            try fixture.router.route_context(.get, "/", &fixture.capture, Capture.handle);
        }
        fixture.headers.reset(&fixture.capture, Capture.release_header, &fixture.request_headers, &.{}, &.{}, stream.default_capacities);
        fixture.headers.request.method = if (streaming) "POST" else "GET";
        fixture.headers.request.target = "/";
        fixture.headers.request.path = "/";
        fixture.headers.content_length = data.len;
        fixture.headers.finished = true;
        fixture.quic.reset(
            &fixture.capture,
            Capture.release_stream,
            @ptrCast(&fixture.fake),
            &fixture.router,
            &fixture.request_body,
            &fixture.response_body,
            &fixture.response_headers,
            &.{},
            &.{},
            &.{},
            &.{},
        );
        fixture.quic.attach_headers(&fixture.headers);
    }

    fn close(fixture: *Fixture) !void {
        fixture.quic.on_close();
        fixture.quic.on_close();
        try std.testing.expectEqual(@as(usize, 1), fixture.capture.header_releases);
        try std.testing.expectEqual(@as(usize, 1), fixture.capture.stream_releases);
    }
};

test "quic lifecycle: buffered EOF closes reads before dispatch and releases once" {
    const bodies = [_][]const u8{ "", "body", "x" ** 64 };
    for (bodies) |data| {
        var fixture = Fixture{};
        try fixture.init(false, data);
        fixture.quic.on_read();
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.read_shutdowns);
        try std.testing.expect(fixture.capture.read_closed_before_callback);
        try std.testing.expectEqual(@as(usize, 1), fixture.capture.handlers);
        try std.testing.expect(!fixture.capture.response_failed);
        fixture.quic.on_write();
        fixture.quic.on_write();
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.read_shutdowns);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.write_shutdowns);
        try std.testing.expectEqual(@as(usize, 0), fixture.fake.closes);
        try fixture.close();
    }
}

test "quic lifecycle: buffered read shutdown failure prevents dispatch" {
    var fixture = Fixture{};
    try fixture.init(false, "");
    fixture.fake.fail_read_shutdown = true;
    fixture.quic.on_read();
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.handlers);
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.read_shutdowns);
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.closes);
    try std.testing.expectEqual(@as(usize, 0), fixture.fake.write_shutdowns);
    try fixture.close();
}

test "quic lifecycle: streaming EOF closes reads before the sink ends" {
    var fixture = Fixture{};
    try fixture.init(true, "body");
    fixture.quic.on_read();
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.read_shutdowns);
    try std.testing.expect(fixture.capture.read_closed_before_callback);
    try std.testing.expectEqual(@as(usize, 1), fixture.capture.ends);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.cancels);
    fixture.quic.on_write();
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.write_shutdowns);
    try fixture.close();
}

test "quic lifecycle: streaming read shutdown failure cancels the sink once" {
    var fixture = Fixture{};
    try fixture.init(true, "body");
    fixture.fake.fail_read_shutdown = true;
    fixture.quic.on_read();
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.ends);
    try std.testing.expectEqual(@as(usize, 1), fixture.capture.cancels);
    try std.testing.expectEqual(body.BodyCancelReason.peer_closed, fixture.capture.cancel_reason.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.closes);
    try std.testing.expect(!fixture.quic.streaming_active);
    try fixture.close();
    try std.testing.expectEqual(@as(usize, 1), fixture.capture.cancels);
}
