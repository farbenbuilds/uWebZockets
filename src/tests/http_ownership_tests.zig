const std = @import("std");
const support = @import("test_support");
const Session = support.http2_server.server_session(2);
const response = support.http_response;

const capacities = Session.Capacities{
    .header_block_size = 127,
    .request_header_size = 257,
    .body_size = 131,
    .response_header_size = 149,
    .response_header_count = 7,
    .decoded_header_count = 97,
    .dynamic_table_size = 65,
    .route_param_extra_capacity = 3,
};

const Span = struct { start: usize, end: usize };

fn byte_span(comptime T: type, values: []T) Span {
    const start = @intFromPtr(values.ptr);
    return .{ .start = start, .end = start + values.len * @sizeOf(T) };
}

fn storage_spans(storage: Session.Storage) [18]Span {
    return .{
        byte_span(support.http_request.Request, storage.requests),
        byte_span(u8, storage.request_storage),
        byte_span(u8, storage.body_storage),
        byte_span(u8, storage.response_body_storage),
        byte_span(u8, storage.response_header_storage),
        byte_span(support.http2_hpack.Header, storage.decoded_headers),
        byte_span(u8, storage.decoded_header_bytes),
        byte_span(support.http2_hpack.DynamicEntry, storage.dynamic_entries),
        byte_span(u8, storage.dynamic_bytes),
        byte_span(u8, storage.header_block),
        byte_span(u8, storage.frame_buffer),
        byte_span(support.http2_hpack.Header, storage.response_fields),
        byte_span(u8, storage.response_encode),
        byte_span(u8, storage.lowercase_names),
        byte_span([]const u8, storage.header_extra_names),
        byte_span([]const u8, storage.header_extra_values),
        byte_span([]const u8, storage.route_param_names),
        byte_span([]const u8, storage.route_param_values),
    };
}

test "http ownership: HTTP2 exact and misaligned storage remains nonoverlapping" {
    const bytes = try Session.storage_bytes(capacities);
    var backing: [64 * 1024]u8 align(Session.storage_alignment) = undefined;
    try std.testing.expect(bytes + Session.storage_alignment <= backing.len);

    for (0..Session.storage_alignment) |offset| {
        const padding = if (offset == 0) 0 else Session.storage_alignment - offset;
        const region = backing[offset .. offset + padding + bytes];
        const storage = try Session.carve_storage(region, capacities);
        const spans = storage_spans(storage);
        const start = @intFromPtr(region.ptr) + padding;
        try std.testing.expectEqual(start, spans[0].start);
        try std.testing.expectEqual(start + bytes, spans[spans.len - 1].end);
        for (spans, 0..) |span, index| {
            try std.testing.expect(span.start >= start);
            try std.testing.expect(span.end <= start + bytes);
            if (index != 0) try std.testing.expect(spans[index - 1].end <= span.start);
        }
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage.requests.ptr) % @alignOf(support.http_request.Request));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage.decoded_headers.ptr) % @alignOf(support.http2_hpack.Header));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage.dynamic_entries.ptr) % @alignOf(support.http2_hpack.DynamicEntry));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage.response_fields.ptr) % @alignOf(support.http2_hpack.Header));
        try std.testing.expectEqual(@as(usize, 66), storage.header_extra_names.len);
        try std.testing.expectEqual(@as(usize, 6), storage.route_param_values.len);
        try std.testing.expectError(error.InvalidHttp2Capacity, Session.carve_storage(region[0 .. region.len - 1], capacities));
        _ = try Session.init(storage);
    }
}

test "http ownership: HTTP2 storage rejects empty and overflowing capacities" {
    const invalid = [_]Session.Capacities{
        .{ .header_block_size = 0 },
        .{ .request_header_size = 0 },
        .{ .body_size = 0 },
        .{ .response_header_size = 0 },
        .{ .response_header_count = 0 },
        .{ .decoded_header_count = 0 },
        .{ .body_size = std.math.maxInt(usize) },
        .{ .decoded_header_count = std.math.maxInt(usize) },
        .{ .dynamic_table_size = std.math.maxInt(usize) },
        .{ .route_param_extra_capacity = std.math.maxInt(usize) },
    };
    var region: [16]u8 = undefined;
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidHttp2Capacity, Session.storage_bytes(value));
        try std.testing.expectError(error.InvalidHttp2Capacity, Session.carve_storage(&region, value));
    }
}

const AsyncCapture = struct {
    owner: *response.AsyncResponseState,
    completions: usize = 0,
    wakes: usize = 0,
    observed_completing: bool = false,
    observed_settled: bool = false,

    fn fail(context: *anyopaque, _: []const u8, _: []const u8, _: []const u8) !void {
        const capture: *AsyncCapture = @ptrCast(@alignCast(context));
        capture.completions += 1;
        capture.observed_completing = capture.owner.state == .completing and capture.owner.target != null;
        return error.SimulatedTransportFailure;
    }

    fn wake(context: *anyopaque) void {
        const capture: *AsyncCapture = @ptrCast(@alignCast(context));
        capture.wakes += 1;
        capture.observed_settled = capture.owner.state == .completed and capture.owner.target == null;
    }

    fn on_resume(_: *anyopaque) void {}
};

test "http ownership: async callback failure consumes and wakes exactly once" {
    var owner = response.AsyncResponseState{};
    var capture = AsyncCapture{ .owner = &owner };
    const token = owner.arm(.{
        .context = &capture,
        .complete_fn = AsyncCapture.fail,
        .wake_fn = AsyncCapture.wake,
    });

    try std.testing.expectError(error.SimulatedTransportFailure, token.complete("200 OK", "body"));
    try std.testing.expect(capture.observed_completing);
    try std.testing.expect(capture.observed_settled);
    try std.testing.expectError(error.AsyncResponseAlreadyCompleted, token.complete("200 OK", "again"));
    try std.testing.expectEqual(@as(usize, 1), capture.completions);
    try std.testing.expectEqual(@as(usize, 1), capture.wakes);
}

test "http ownership: unavailable timers leave valid async tokens pending" {
    var owner = response.AsyncResponseState{};
    var capture = AsyncCapture{ .owner = &owner };
    const token = owner.arm(.{
        .context = &capture,
        .complete_fn = AsyncCapture.fail,
        .wake_fn = AsyncCapture.wake,
    });

    try std.testing.expectError(error.TimerUnavailable, token.sleep(1, &capture, AsyncCapture.on_resume));
    try std.testing.expectError(error.InvalidStatus, token.sleep_complete(1, "600 Invalid", "", ""));
    try std.testing.expectError(error.InvalidHeaders, token.sleep_complete(1, "200 OK", "Content-Length: 0\r\n", ""));
    try std.testing.expectError(error.BodyNotAllowed, token.sleep_complete(1, "204 No Content", "", "body"));
    try std.testing.expectError(error.TimerUnavailable, token.sleep_complete(1, "200 OK", "", "body"));
    try std.testing.expect(token.is_pending());
    try std.testing.expectEqual(@as(usize, 0), capture.completions);
    try std.testing.expectEqual(@as(usize, 0), capture.wakes);

    owner.cancel();
    try std.testing.expectError(error.AsyncResponseExpired, token.sleep(1, &capture, AsyncCapture.on_resume));
    try std.testing.expectError(error.AsyncResponseExpired, token.sleep_complete(1, "200 OK", "", "body"));
}

test "http ownership: public async aliases preserve token and state types" {
    try std.testing.expect(support.public_api.AsyncResponse == response.AsyncResponse);
    try std.testing.expect(support.public_api.AsyncResponseState == response.AsyncResponseState);
    try std.testing.expect(support.public_api.AsyncResponseStatus == response.AsyncState);
}
