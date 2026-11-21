const std = @import("std");
const support = @import("test_support");
const parking = support.connection_parking;
const tcp = support.tcp;
const response = support.http_response;
const NativeConnection = @import("file_stream_tests.zig").TestConnection;

fn increment(context: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

test "parking: replacement counts one slot and take transfers its action once" {
    var slot = parking.Slot{};
    var count: u16 = 0;
    var old_calls: usize = 0;
    var new_calls: usize = 0;
    var owner: u8 = 0;
    parking.park(&slot, &count, &owner, .{ .handler = .{ .context = &old_calls, .callback = increment } });
    parking.park(&slot, &count, &owner, .{ .handler = .{ .context = &new_calls, .callback = increment } });
    try std.testing.expectEqual(@as(u16, 1), count);
    const expiry = parking.take(&slot, &count).?;
    try std.testing.expectEqual(@as(u16, 0), count);
    try std.testing.expect(slot.pending == null);
    try std.testing.expect(parking.take(&slot, &count) == null);
    try std.testing.expectEqual(@as(*anyopaque, &owner), expiry.connection);
    expiry.action.handler.callback(expiry.action.handler.context);
    try std.testing.expectEqual(@as(usize, 0), old_calls);
    try std.testing.expectEqual(@as(usize, 1), new_calls);
}

/// Captures tokens without storing state outside the caller-owned fixture.
const Capture = struct {
    tokens: [2]response.AsyncResponse = undefined,
    length: usize = 0,

    fn receive(context: *anyopaque, _: *support.http_request.Request, token: response.AsyncResponse) void {
        const state: *Capture = @ptrCast(@alignCast(context));
        state.tokens[state.length] = token;
        state.length += 1;
    }
};

/// Real socket ownership with manually advanced timers keeps delay tests deterministic.
const Fixture = struct {
    native: NativeConnection = .{},
    scheduler: support.timer.Scheduler = undefined,
    router_bundle: support.radix.DefaultBundle = .{},
    router: support.radix.Router = .{},
    h2_bundle: tcp.Http2Session.Bundle(.{
        .header_block_size = 1024,
        .request_header_size = 1024,
        .body_size = 128,
    }) = .{},
    ring: [4096]u8 = undefined,
    request_buffer: [1024]u8 = undefined,
    capture: Capture = .{},

    fn init(state: *Fixture) !void {
        try state.native.init(&state.ring);
        errdefer state.native.deinit();
        state.scheduler = try support.timer.Scheduler.init(std.testing.io);
        errdefer state.scheduler.deinit();
        state.router = try support.radix.Router.init(state.router_bundle.storage());
        try state.router.route_async_context(.get, "/delay", &state.capture, Capture.receive);
        state.native.connection.router = &state.router;
        state.native.connection.request_buffer = &state.request_buffer;
        state.native.connection.attach_timer_scheduler(&state.scheduler, 60_000, 60_000);
    }

    fn deinit(state: *Fixture) void {
        state.native.deinit();
        state.scheduler.deinit();
    }

    fn http1(state: *Fixture) void {
        state.native.connection.protocol_state = .http;
        var request = "GET /delay HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
        state.native.connection.route_decrypted_data(&request);
    }

    fn http2(state: *Fixture) !void {
        const conn = &state.native.connection;
        conn.protocol_state = .http2;
        conn.h2 = try tcp.Http2Session.init(state.h2_bundle.storage());
        var input: [128]u8 = undefined;
        @memcpy(input[0..support.http2.client_preface.len], support.http2.client_preface);
        var length = support.http2.client_preface.len;
        try append_frame(&input, &length, .settings, 0, 0, "");
        const headers = [_]u8{ 0x82, 0x86, 0x04, 0x06, '/', 'd', 'e', 'l', 'a', 'y' };
        try append_frame(&input, &length, .headers, 0x5, 1, &headers);
        try append_frame(&input, &length, .headers, 0x5, 3, &headers);
        try conn.h2.receive(input[0..length], conn.http2_callbacks());
    }
};

fn append_frame(
    output: []u8,
    length: *usize,
    kind: support.http2.FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
) !void {
    if (9 + payload.len > output.len - length.*) return error.OutputTooSmall;
    var header: [9]u8 = undefined;
    try (support.http2.FrameHeader{
        .payload_length = @intCast(payload.len),
        .frame_type = @intFromEnum(kind),
        .flags = flags,
        .stream_id = stream_id,
    }).encode(&header);
    @memcpy(output[length.*..][0..9], &header);
    length.* += 9;
    @memcpy(output[length.*..][0..payload.len], payload);
    length.* += payload.len;
}

test "tcp parking: replacing an HTTP1 delay cancels the old deadline" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    state.http1();
    try std.testing.expectEqual(@as(usize, 1), state.capture.length);
    const token = state.capture.tokens[0];
    var first: usize = 0;
    var replacement: usize = 0;
    try token.sleep(10, &first, increment);
    const old_deadline = state.native.connection.sleep_slots[0].node.deadline_ms;
    try token.sleep(20, &replacement, increment);
    const new_deadline = state.native.connection.sleep_slots[0].node.deadline_ms;
    try std.testing.expectEqual(@as(u16, 1), state.native.connection.parked_sleeps);
    state.scheduler.wheel.advance(old_deadline);
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 0), replacement);
    state.scheduler.wheel.advance(new_deadline);
    try std.testing.expectEqual(@as(usize, 1), replacement);
    try std.testing.expectEqual(@as(u16, 0), state.native.connection.parked_sleeps);
}

test "tcp parking: HTTP2 sibling cancellation preserves a parked peer and restores idle" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    try state.http2();
    const conn = &state.native.connection;
    try std.testing.expectEqual(@as(usize, 2), state.capture.length);
    var first: usize = 0;
    var sibling: usize = 0;
    try state.capture.tokens[0].sleep(100, &first, increment);
    try state.capture.tokens[1].sleep(100, &sibling, increment);
    conn.touch_activity();
    try std.testing.expectEqual(support.timer_wheel.TimerState.idle, conn.idle_timer.state);
    const sibling_index = conn.h2.connection.streams.find(3).?;
    const deadline = conn.sleep_slots[sibling_index + 1].node.deadline_ms;
    try conn.h2.reset_stream(1, .cancel, conn.http2_callbacks());
    try std.testing.expectEqual(@as(u16, 1), conn.parked_sleeps);
    try std.testing.expect(!state.capture.tokens[0].is_pending());
    try std.testing.expect(state.capture.tokens[1].is_pending());
    try std.testing.expectEqual(support.timer_wheel.TimerState.idle, conn.idle_timer.state);
    state.scheduler.wheel.advance(deadline);
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 1), sibling);
    try std.testing.expectEqual(@as(u16, 0), conn.parked_sleeps);
    try std.testing.expectEqual(support.timer_wheel.TimerState.queued, conn.idle_timer.state);
}

test "tcp parking: closing cancels every slot and invalidates delayed tokens" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    try state.http2();
    const conn = &state.native.connection;
    try state.capture.tokens[0].sleep_complete(100, "200 OK", "", "first");
    try state.capture.tokens[1].sleep_complete(100, "200 OK", "", "second");
    tcp.close_connection(conn);
    try std.testing.expectEqual(@as(u16, 0), conn.parked_sleeps);
    try std.testing.expectEqual(@as(usize, 0), state.scheduler.wheel.count);
    for (&conn.sleep_slots) |*slot| try std.testing.expect(slot.pending == null);
    for (state.capture.tokens[0..state.capture.length]) |token| try std.testing.expect(!token.is_pending());
    state.scheduler.wheel.advance(state.scheduler.wheel.now_ms + 1000);
    try std.testing.expectEqual(@as(usize, 0), state.scheduler.wheel.count);
}

test "tcp parking: missing scheduler closes HTTP1 instead of leaving it parked" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    state.http1();
    const conn = &state.native.connection;
    conn.cancel_timers();
    try state.capture.tokens[0].sleep_complete(100, "200 OK", "", "unreachable");
    try std.testing.expect(conn.closing);
    try std.testing.expectEqual(@as(u16, 0), conn.parked_sleeps);
    try std.testing.expect(!state.capture.tokens[0].is_pending());
}

test "tcp parking: stale expiry ignores an empty reused slot before reading its owner" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    state.http1();
    const conn = &state.native.connection;
    var calls: usize = 0;
    try state.capture.tokens[0].sleep(100, &calls, increment);
    const expire = conn.sleep_slots[0].node.callback;
    conn.cancel_timers();
    conn.sleep_slots[0] = .{};
    expire(&conn.sleep_slots[0]);
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(@as(u16, 0), conn.parked_sleeps);
}

test "tcp parking: delayed completion releases borrowed fields before waking dispatch" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    state.http1();
    const conn = &state.native.connection;
    try state.capture.tokens[0].sleep_complete(100, "200 OK", "X-Delay: retained\r\n", "done");
    state.scheduler.wheel.advance(conn.sleep_slots[0].node.deadline_ms);
    try std.testing.expectEqual(response.AsyncState.completed, conn.async_response_state.state);
    try std.testing.expect(conn.sleep_slots[0].pending == null);
    try std.testing.expectEqual(@as(u16, 0), conn.parked_sleeps);
    try std.testing.expect(!conn.dispatch_suspended);
    try std.testing.expect(std.mem.indexOf(u8, state.ring[0..conn.write_len], "X-Delay: retained\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, state.ring[0..conn.write_len], "done"));
}

/// Reuses the expired slot inside application code, as a synchronous release may.
const Recycle = struct {
    connection: *tcp.TcpConnection,
    observed_cleared: bool = false,
    calls: usize = 0,

    fn mark_reused(context: *anyopaque) void {
        const state: *Recycle = @ptrCast(@alignCast(context));
        const conn = state.connection;
        state.observed_cleared = conn.parked_sleeps == 0 and conn.sleep_slots[0].pending == null;
        state.calls += 1;
        conn.cancel_timers();
        conn.sleep_slots[0] = .{};
        conn.parked_sleeps = 42;
    }
};

test "tcp parking: resume can recycle its slot without a later connection access" {
    var state = Fixture{};
    try state.init();
    defer state.deinit();
    state.http1();
    const conn = &state.native.connection;
    var recycled = Recycle{ .connection = conn };
    try state.capture.tokens[0].sleep(100, &recycled, Recycle.mark_reused);
    state.scheduler.wheel.advance(conn.sleep_slots[0].node.deadline_ms);
    try std.testing.expect(recycled.observed_cleared);
    try std.testing.expectEqual(@as(usize, 1), recycled.calls);
    try std.testing.expectEqual(@as(u16, 42), conn.parked_sleeps);
    try std.testing.expect(conn.timer_scheduler == null);
    conn.parked_sleeps = 0;
}
