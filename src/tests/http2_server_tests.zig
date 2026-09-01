const std = @import("std");
const support = @import("test_support");
const http2 = support.http2;
const http2_server = support.http2_server;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const radix = support.radix;

const TestSession = http2_server.server_session(4, 4096, 4096, 1024);
const SingleStreamSession = http2_server.server_session(1, 4096, 4096, 1024);

const TestState = struct {
    session: *TestSession,
    router: radix.Router = radix.Router.init(),
    output: [8192]u8 = undefined,
    output_length: usize = 0,
    dispatch_order: [4]u32 = undefined,
    dispatch_count: usize = 0,
    middleware_count: usize = 0,
    async_state: support.http_response.AsyncResponseState = .{},
    pending_response: ?support.http_response.AsyncResponse = null,
    async_stream_id: u32 = 0,
    wake_count: usize = 0,
    saw_dynamic_header: bool = false,

    fn callbacks(self: *TestState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
            .stream_closed_fn = stream_closed,
        };
    }

    fn stream_closed(context: *anyopaque, stream_id: u32, _: u16) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        if (self.async_stream_id != stream_id) return;
        self.async_state.cancel();
        self.async_stream_id = 0;
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
    }

    fn dispatch(context: *anyopaque, request: *Request, stream_id: u32) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.dispatch_order[self.dispatch_count] = stream_id;
        self.dispatch_count += 1;

        var response = Response{ .target = .{ .http2 = .{
            .context = self,
            .router = &self.router,
            .stream_id = stream_id,
            .end_fn = response_end,
            .begin_fn = response_begin,
            .write_fn = response_write,
            .finish_fn = response_finish,
        } } };
        if (!request.valid_query_content_type()) {
            try response.end("400 Bad Request", "QUERY requires a valid Content-Type");
            return;
        }
        const method = radix.HttpMethod.parse(request.method);
        const route = self.router.match_request(request, method) orelse
            return error.RouteNotFound;
        if (self.router.run_middleware(request, &response) == .stop) return;
        const handler = route.handler orelse return error.RouteNotFound;
        switch (handler) {
            .synchronous => |callback| callback(request, &response),
            .contextual => |binding| binding.callback(binding.context, request, &response),
            .asynchronous => |callback| {
                self.async_stream_id = stream_id;
                const token = self.async_state.arm(.{
                    .context = self,
                    .complete_fn = async_complete,
                    .wake_fn = async_wake,
                });
                callback(request, token);
                return;
            },
            .contextual_async => |binding| {
                self.async_stream_id = stream_id;
                const token = self.async_state.arm(.{
                    .context = self,
                    .complete_fn = async_complete,
                    .wake_fn = async_wake,
                });
                binding.callback(binding.context, request, token);
                return;
            },
        }
        if (!response.is_complete()) return error.IncompleteResponse;
    }

    fn response_end(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.send_response(
            stream_id,
            status,
            headers,
            body,
            self.callbacks(),
        );
    }

    fn response_begin(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.begin_response(stream_id, status, headers, self.callbacks());
    }

    fn response_write(context: *anyopaque, stream_id: u32, bytes: []const u8) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.write_response_data(stream_id, bytes, self.callbacks());
    }

    fn response_finish(context: *anyopaque, stream_id: u32) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.finish_response(stream_id, self.callbacks());
    }

    fn async_complete(
        context: *anyopaque,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.send_response(
            self.async_stream_id,
            status,
            headers,
            body,
            self.callbacks(),
        );
    }

    fn async_wake(context: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.wake_count += 1;
    }
};

const RefusalState = struct {
    output: [8192]u8 = undefined,
    output_length: usize = 0,
    dispatch_count: usize = 0,
    saw_dynamic_header: bool = false,

    fn callbacks(self: *RefusalState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
        };
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *RefusalState = @ptrCast(@alignCast(context));
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
    }

    fn dispatch(context: *anyopaque, request: *Request, _: u32) !void {
        const self: *RefusalState = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
        const value = request.get_header("x-test") orelse return;
        self.saw_dynamic_header = std.mem.eql(u8, value, "value");
    }
};

const WriteBehavior = enum {
    accept,
    block_data,
    fail_data,
};

const FlowState = struct {
    output: [16 * 1024]u8 = undefined,
    output_length: usize = 0,
    dispatch_count: usize = 0,
    data_write_attempts: usize = 0,
    behavior: WriteBehavior = .accept,
    max_frame_payload: usize = http2.maximum_frame_size,
    write_capacity: usize = std.math.maxInt(usize),
    queued_length: usize = 0,

    fn callbacks(self: *FlowState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
            .max_frame_payload = self.max_frame_payload,
        };
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *FlowState = @ptrCast(@alignCast(context));
        if (parts.len == 0 or parts[0].len != 9) return error.InvalidFrame;
        const header = try http2.FrameHeader.parse(parts[0][0..9]);
        if ((header.frame_type == @intFromEnum(http2.FrameType.headers) or
            header.frame_type == @intFromEnum(http2.FrameType.data)) and
            header.payload_length > self.max_frame_payload)
        {
            return error.WouldBlock;
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.data)) {
            self.data_write_attempts += 1;
            switch (self.behavior) {
                .accept => {},
                .block_data => return error.WouldBlock,
                .fail_data => return error.TestWriteFailure,
            }
        }

        var total_length: usize = 0;
        for (parts) |part| {
            if (part.len > self.write_capacity -| total_length) return error.WouldBlock;
            total_length += part.len;
        }
        if (total_length > self.write_capacity -| self.queued_length) {
            return error.WouldBlock;
        }
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
        self.queued_length += total_length;
    }

    fn dispatch(context: *anyopaque, _: *Request, _: u32) !void {
        const self: *FlowState = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
    }

    fn drain(self: *FlowState) void {
        self.queued_length = 0;
    }
};

fn append_frame(
    output: []u8,
    offset: *usize,
    frame_type: http2.FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
) !void {
    if (9 + payload.len > output.len - offset.*) return error.OutputTooSmall;
    var frame_header: [9]u8 = undefined;
    try (http2.FrameHeader{
        .payload_length = @intCast(payload.len),
        .frame_type = @intFromEnum(frame_type),
        .flags = flags,
        .stream_id = stream_id,
    }).encode(&frame_header);
    @memcpy(output[offset.* .. offset.* + 9], &frame_header);
    offset.* += 9;
    @memcpy(output[offset.* .. offset.* + payload.len], payload);
    offset.* += payload.len;
}

fn reset_count(
    output: []const u8,
    stream_id: u32,
    code: http2_server.ErrorCode,
) !usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream) and
            header.stream_id == stream_id)
        {
            if (header.payload_length != 4) return error.InvalidFrameSize;
            const payload = output[offset + 9 ..][0..4];
            if (std.mem.readInt(u32, payload, .big) == @intFromEnum(code)) count += 1;
        }
        offset += frame_length;
    }
    return count;
}

fn frame_count(
    output: []const u8,
    frame_type: http2.FrameType,
    stream_id: u32,
) !usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(frame_type) and
            header.stream_id == stream_id)
        {
            count += 1;
        }
        offset += frame_length;
    }
    return count;
}

const DataFrames = struct {
    count: usize = 0,
    bytes_length: usize = 0,
    end_stream_count: usize = 0,
    final_end_stream: bool = false,
};

fn collect_data_frames(
    output: []const u8,
    stream_id: u32,
    bytes: []u8,
) !DataFrames {
    var result = DataFrames{};
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.data) and
            header.stream_id == stream_id)
        {
            if (header.payload_length > bytes.len - result.bytes_length) {
                return error.OutputTooSmall;
            }
            const payload = output[offset + 9 .. offset + frame_length];
            @memcpy(bytes[result.bytes_length .. result.bytes_length + payload.len], payload);
            result.bytes_length += payload.len;
            result.count += 1;
            result.final_end_stream = header.flags & 0x1 != 0;
            if (result.final_end_stream) result.end_stream_count += 1;
        }
        offset += frame_length;
    }
    return result;
}

fn middleware(
    context: *anyopaque,
    _: *Request,
    _: *Response,
) radix.MiddlewareResult {
    const state: *TestState = @ptrCast(@alignCast(context));
    state.middleware_count += 1;
    return .continue_dispatch;
}

fn route_handler(context: *anyopaque, request: *Request, response: *Response) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    _ = state;
    const id = request.get_param("id") orelse {
        response.end("500 Internal Server Error", "missing route parameter") catch
            @panic("test fixture response failed");
        return;
    };
    response.end_with_headers("200 OK", "Content-Type: text/plain\r\n", id) catch
        @panic("test fixture response failed");
}

fn async_route_handler(
    context: *anyopaque,
    _: *Request,
    response: support.http_response.AsyncResponse,
) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    state.pending_response = response;
}

fn trailer_route_handler(
    context: *anyopaque,
    request: *Request,
    response: *Response,
) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    if (request.get_header("x-test")) |value| {
        state.saw_dynamic_header = std.mem.eql(u8, value, "value");
    }
    response.end("200 OK", "ok") catch @panic("test fixture response failed");
}

test "http2 server: interleaved streams dispatch router and encode responses" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    try state.router.use(&state, middleware);
    try state.router.route_context(.get, "/items/:id", &state, route_handler);

    const first_headers = [_]u8{
        0x82, 0x86, 0x04, 0x0a,
        '/',  'i',  't',  'e',
        'm',  's',  '/',  'o',
        'n',  'e',
    };
    const third_headers = [_]u8{
        0x82, 0x86, 0x04, 0x0c,
        '/',  'i',  't',  'e',
        'm',  's',  '/',  't',
        'h',  'r',  'e',  'e',
    };
    var input: [256]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &first_headers);
    try append_frame(&input, &input_length, .headers, 0x4, 3, &third_headers);
    try append_frame(&input, &input_length, .data, 0x1, 3, "body-three");
    try append_frame(&input, &input_length, .data, 0x1, 1, "body-one");

    const callbacks = state.callbacks();
    try session.receive(input[0..7], callbacks);
    try session.receive(input[7..41], callbacks);
    try session.receive(input[41..input_length], callbacks);

    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expectEqualSlices(u32, &.{ 3, 1 }, state.dispatch_order[0..2]);
    try std.testing.expectEqual(@as(usize, 2), state.middleware_count);
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expect(session.connection.streams.find(3) == null);

    var offset: usize = 0;
    var response_headers: usize = 0;
    var response_data: usize = 0;
    var saw_three = false;
    var saw_one = false;
    while (offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[offset..][0..9]);
        const payload = state.output[offset + 9 .. offset + 9 + header.payload_length];
        if (header.frame_type == @intFromEnum(http2.FrameType.headers) and
            header.stream_id != 0)
        {
            response_headers += 1;
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.data)) {
            response_data += 1;
            if (header.stream_id == 3) saw_three = std.mem.eql(u8, payload, "three");
            if (header.stream_id == 1) saw_one = std.mem.eql(u8, payload, "one");
        }
        offset += 9 + header.payload_length;
    }
    try std.testing.expectEqual(@as(usize, 2), response_headers);
    try std.testing.expectEqual(@as(usize, 2), response_data);
    try std.testing.expect(saw_three and saw_one);
}

test "http2 server: invalid QUERY metadata bypasses middleware" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    try state.router.use(&state, middleware);

    const request_headers = [_]u8{
        0x02, 0x05, 'Q',  'U', 'E', 'R',  'Y',
        0x87, 0x01, 0x09, 'l', 'o', 'c',  'a',
        'l',  'h',  'o',  's', 't', 0x04, 0x06,
        '/',  'q',  'u',  'e', 'r', 'y',  0x0f,
        0x10, 0x14, 't',  'e', 'x', 't',  '/',
        'p',  'l',  'a',  'i', 'n', ';',  ' ',
        'c',  'h',  'a',  'r', 's', 'e',  't',
        '=',
    };
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(usize, 0), state.middleware_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output[0..state.output_length],
        "QUERY requires a valid Content-Type",
    ) != null);
}

test "http2 server: trailers preserve HPACK dynamic table synchronization" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    try state.router.route_context(.get, "/trail", &state, trailer_route_handler);

    const request_headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 't', 'r', 'a', 'i', 'l',
    };
    const trailer = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't', 0x05, 'v', 'a', 'l', 'u', 'e',
    };
    const dynamic_request_headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 't', 'r', 'a', 'i', 'l', 0xbe,
    };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &request_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &trailer);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &dynamic_request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expect(state.saw_dynamic_header);
}

test "http2 server: refused END_HEADERS preserves HPACK dynamic table state" {
    var session: SingleStreamSession = .{};
    try session.reset();
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const refused_headers = [_]u8{
        0x82, 0x86, 0x84, 0x40, 0x06,
        'x',  '-',  't',  'e',  's',
        't',  0x05, 'v',  'a',  'l',
        'u',  'e',
    };
    var input: [160]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &refused_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(u32, 3), session.connection.highest_peer_stream_id);
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var late_headers_frame: [64]u8 = undefined;
    var late_headers_length: usize = 0;
    const late_headers = [_]u8{
        0x40, 0x06, 'x', '-', 'l', 'a', 't', 'e',
        0x05, 'l',  'a', 't', 'e', 'r',
    };
    try append_frame(
        &late_headers_frame,
        &late_headers_length,
        .headers,
        0x5,
        3,
        &late_headers,
    );
    try session.receive(late_headers_frame[0..late_headers_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var follow_up: [64]u8 = undefined;
    var follow_up_length: usize = 0;
    const cancel = [_]u8{ 0, 0, 0, 8 };
    try append_frame(&follow_up, &follow_up_length, .rst_stream, 0, 1, &cancel);
    const indexed_headers = [_]u8{ 0x82, 0x86, 0x84, 0xbf };
    try append_frame(&follow_up, &follow_up_length, .headers, 0x5, 5, &indexed_headers);
    try session.receive(follow_up[0..follow_up_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expect(state.saw_dynamic_header);
}

test "http2 server: fragmented refused headers reset only after completion" {
    var session: SingleStreamSession = .{};
    try session.reset();
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const refused_headers = [_]u8{
        0x82, 0x86, 0x84, 0x40, 0x06,
        'x',  '-',  't',  'e',  's',
        't',  0x05, 'v',  'a',  'l',
        'u',  'e',
    };
    const split = 8;
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(
        &input,
        &input_length,
        .headers,
        0x1,
        3,
        refused_headers[0..split],
    );
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var continuation: [64]u8 = undefined;
    var continuation_length: usize = 0;
    try append_frame(
        &continuation,
        &continuation_length,
        .continuation,
        0x4,
        3,
        refused_headers[split..],
    );
    try session.receive(continuation[0..continuation_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );
}

test "http2 server: skipped-stream headers preserve HPACK before reset" {
    var session: TestSession = .{};
    try session.reset();
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const closed_headers = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't',
        0x05, 'v',  'a', 'l', 'u', 'e',
    };
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 3, &active_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &closed_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );
}

test "http2 server: half-closed fragmented headers reset after completion" {
    var session: TestSession = .{};
    try session.reset();
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const closed_headers = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't',
        0x05, 'v',  'a', 'l', 'u', 'e',
    };
    const split = 7;
    var input: [112]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(
        &input,
        &input_length,
        .headers,
        0,
        1,
        closed_headers[0..split],
    );
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );

    var continuation: [64]u8 = undefined;
    var continuation_length: usize = 0;
    try append_frame(
        &continuation,
        &continuation_length,
        .continuation,
        0x4,
        1,
        closed_headers[split..],
    );
    try session.receive(continuation[0..continuation_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );
}

test "http2 server: duplicate Host and authority mismatch are stream errors" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };

    const duplicate_host = [_]u8{
        0x82, 0x86, 0x84,
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
    };
    const mismatched = [_]u8{
        0x82, 0x86, 0x01, 0x0b,
        'e',  'x',  'a',  'm',
        'p',  'l',  'e',  '.',
        'c',  'o',  'm',  0x84,
        0x00, 0x04, 'h',  'o',
        's',  't',  0x0b, 'e',
        'x',  'a',  'm',  'p',
        'l',  'e',  '.',  'n',
        'e',  't',
    };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &duplicate_host);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &mismatched);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .protocol_error),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 3, .protocol_error),
    );
}

test "http2 server: regular CONNECT receives an ordinary 501 response" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };

    const connect_headers = [_]u8{
        0x02, 0x07, 'C', 'O', 'N', 'N', 'E', 'C', 'T',
        0x01, 0x0b, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        '.',  'c',  'o', 'm',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &connect_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .rst_stream, 1),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .headers, 1),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output[0..state.output_length],
        "CONNECT is not supported",
    ) != null);
}

test "http2 server: 205 responses reject a body" {
    var session: TestSession = .{};
    try session.reset();
    var state = RefusalState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectError(
        error.BodyNotAllowed,
        session.send_response(
            1,
            "205 Reset Content",
            "",
            "forbidden",
            state.callbacks(),
        ),
    );
    try session.send_response(1, "205 Reset Content", "", "", state.callbacks());
}

test "http2 server: pending body resumes through partial stream credit" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const zero_window = [_]u8{ 0x00, 0x04, 0, 0, 0, 0 };
    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, &zero_window);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    try session.send_response(1, "200 OK", "", "abcdef", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    try std.testing.expect(session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 2 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.pending_body_offsets[index]);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 4 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 2),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );
}

test "http2 server: connection and stream response credit are independent" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    session.connection.connection_send_window = 0;
    try session.send_response(1, "200 OK", "", "abc", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 5 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 2 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.pending_body_offsets[index]);

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 1 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
}

test "http2 server: blocked and failed DATA writes retain offsets and credit" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    const connection_window = session.connection.connection_send_window;
    const stream_window = session.connection.streams.send_windows[index];
    state.behavior = .block_data;
    try session.send_response(1, "200 OK", "", "blocked", state.callbacks());
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);
    try std.testing.expectEqual(connection_window, session.connection.connection_send_window);
    try std.testing.expectEqual(stream_window, session.connection.streams.send_windows[index]);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    state.behavior = .accept;
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    var failed_session: TestSession = .{};
    try failed_session.reset();
    var failed_state = FlowState{};
    try failed_session.receive(input[0..input_length], failed_state.callbacks());
    const failed_index = failed_session.connection.streams.find(1) orelse
        return error.MissingStream;
    const failed_connection_window = failed_session.connection.connection_send_window;
    const failed_stream_window = failed_session.connection.streams.send_windows[failed_index];
    failed_state.behavior = .fail_data;
    try std.testing.expectError(
        error.TestWriteFailure,
        failed_session.send_response(
            1,
            "200 OK",
            "",
            "failed",
            failed_state.callbacks(),
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        failed_session.pending_body_offsets[failed_index],
    );
    try std.testing.expectEqual(
        failed_connection_window,
        failed_session.connection.connection_send_window,
    );
    try std.testing.expectEqual(
        failed_stream_window,
        failed_session.connection.streams.send_windows[failed_index],
    );

    failed_state.behavior = .accept;
    try failed_session.flush_pending(failed_state.callbacks());
    try std.testing.expect(failed_session.connection.streams.find(1) == null);
}

test "http2 server: small transport queues make bounded DATA progress" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    var body: [100]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    state.output_length = 0;
    state.write_capacity = 64;
    state.max_frame_payload = 55;
    state.drain();
    try session.send_response(1, "200 OK", "", &body, state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    try std.testing.expect(session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);

    state.drain();
    try session.flush_pending(state.callbacks());
    try std.testing.expectEqual(@as(usize, 55), session.pending_body_offsets[index]);

    state.drain();
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        http2.default_window_size - body.len,
        session.connection.connection_send_window,
    );

    var received: [body.len]u8 = undefined;
    const frames = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &received,
    );
    try std.testing.expectEqual(@as(usize, 2), frames.count);
    try std.testing.expectEqual(body.len, frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), frames.end_stream_count);
    try std.testing.expect(frames.final_end_stream);
    try std.testing.expectEqualSlices(u8, &body, &received);
}

test "http2 server: oversized response HEADERS fail before state commit" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    state.output_length = 0;
    state.max_frame_payload = 0;
    try std.testing.expectError(
        error.ResponseHeadersTooLarge,
        session.begin_response(1, "200 OK", "", state.callbacks()),
    );
    try std.testing.expect(!session.response_started[index]);
    try std.testing.expect(!session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), state.output_length);

    state.max_frame_payload = http2.maximum_frame_size;
    try session.send_response(1, "200 OK", "", "", state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .headers, 1),
    );
}

test "http2 server: streaming DATA retry precedes END_STREAM" {
    var session: TestSession = .{};
    try session.reset();
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    try session.begin_response(1, "200 OK", "", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    const connection_window = session.connection.connection_send_window;
    const stream_window = session.connection.streams.send_windows[index];
    state.output_length = 0;
    state.data_write_attempts = 0;
    session.connection.peer_settings.max_frame_size = 4;
    try std.testing.expectError(
        error.ResponseDataTooLarge,
        session.write_response_data(1, "abcdef", state.callbacks()),
    );
    try std.testing.expect(session.stream_write_retry_required[index]);
    try std.testing.expectEqual(@as(usize, 0), state.data_write_attempts);
    try std.testing.expectEqual(connection_window, session.connection.connection_send_window);
    try std.testing.expectEqual(stream_window, session.connection.streams.send_windows[index]);
    try std.testing.expectError(
        error.ResponseWritePending,
        session.finish_response(1, state.callbacks()),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    session.connection.peer_settings.max_frame_size = http2.default_max_frame_size;
    try session.write_response_data(1, "abcdef", state.callbacks());
    state.behavior = .block_data;
    try session.finish_response(1, state.callbacks());
    try std.testing.expect(session.pending_stream_end[index]);
    try std.testing.expect(session.connection.streams.find(1) != null);

    state.behavior = .accept;
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);

    var received: [6]u8 = undefined;
    const frames = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &received,
    );
    try std.testing.expectEqual(@as(usize, 2), frames.count);
    try std.testing.expectEqual(@as(usize, 6), frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), frames.end_stream_count);
    try std.testing.expect(frames.final_end_stream);
    try std.testing.expectEqualStrings("abcdef", &received);
}

test "http2 server: first peer frame must be non-ack settings" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    var input: [64]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .ping, 0, 0, "12345678");
    try session.receive(input[0..input_length], state.callbacks());
    try std.testing.expect(session.is_closed());

    const settings = try http2.FrameHeader.parse(state.output[0..9]);
    try std.testing.expectEqual(@intFromEnum(http2.FrameType.settings), settings.frame_type);
    var setting_offset: usize = 9;
    while (setting_offset < 9 + settings.payload_length) : (setting_offset += 6) {
        try std.testing.expect(std.mem.readInt(
            u16,
            state.output[setting_offset..][0..2],
            .big,
        ) != 0x8);
    }
    const goaway_offset = 9 + settings.payload_length;
    const goaway = try http2.FrameHeader.parse(state.output[goaway_offset..][0..9]);
    try std.testing.expectEqual(@intFromEnum(http2.FrameType.goaway), goaway.frame_type);
    const code_offset = goaway_offset + 9 + 4;
    try std.testing.expectEqual(
        @intFromEnum(http2_server.ErrorCode.protocol_error),
        std.mem.readInt(u32, state.output[code_offset..][0..4], .big),
    );
}

test "http2 server: deferred response token retains one stream only" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    try state.router.route_async_context(.get, "/async", &state, async_route_handler);

    const headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 'a', 's', 'y', 'n', 'c',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &headers);
    try session.receive(input[0..input_length], state.callbacks());

    const token = state.pending_response orelse return error.MissingAsyncToken;
    try std.testing.expect(token.is_pending());
    try std.testing.expect(session.connection.streams.find(1) != null);
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Content-Length: 9\r\n",
            "later",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Content-Length: 5\r\nContent-Length: 5\r\n",
            "later",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Connection: close\r\n",
            "",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        token.complete_with_headers("200 OK", "Content-Length: 5\r\n", "later"),
    );
    try std.testing.expect(token.is_pending());
    try std.testing.expect(session.connection.streams.find(1) != null);
    try std.testing.expectEqual(@as(usize, 0), state.wake_count);
    try token.complete("200 OK", "later");
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(@as(usize, 1), state.wake_count);
    try std.testing.expectError(
        error.AsyncResponseAlreadyCompleted,
        token.complete("200 OK", "again"),
    );
}

test "http2 server: peer reset expires a retained async response" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };
    try state.router.route_async_context(.get, "/async", &state, async_route_handler);

    const headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 'a', 's', 'y', 'n', 'c',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &headers);
    try session.receive(input[0..input_length], state.callbacks());
    const token = state.pending_response orelse return error.MissingAsyncToken;

    var reset: [16]u8 = undefined;
    var reset_length: usize = 0;
    const cancel = [_]u8{ 0, 0, 0, 8 };
    try append_frame(&reset, &reset_length, .rst_stream, 0, 1, &cancel);
    try session.receive(reset[0..reset_length], state.callbacks());
    try std.testing.expectError(
        error.AsyncResponseExpired,
        token.complete("200 OK", "too late"),
    );
}

test "http2 server: content length is unique numeric and exact" {
    var session: TestSession = .{};
    try session.reset();
    var state = TestState{ .session = &session };

    const length_five = [_]u8{ 0x82, 0x86, 0x84, 0x0f, 0x0d, 0x01, '5' };
    const duplicate = [_]u8{
        0x82, 0x86, 0x84,
        0x0f, 0x0d, 0x01,
        '0',  0x0f, 0x0d,
        0x01, '0',
    };
    const non_numeric = [_]u8{ 0x82, 0x86, 0x84, 0x0f, 0x0d, 0x01, 'x' };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &length_five);
    try append_frame(&input, &input_length, .data, 0x1, 1, "four");
    try append_frame(&input, &input_length, .headers, 0x5, 3, &duplicate);
    try append_frame(&input, &input_length, .headers, 0x5, 5, &non_numeric);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    var output_offset: usize = 0;
    var reset_frame_count: usize = 0;
    while (output_offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[output_offset..][0..9]);
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream)) {
            reset_frame_count += 1;
        }
        output_offset += 9 + header.payload_length;
    }
    try std.testing.expectEqual(@as(usize, 3), reset_frame_count);
}

test "tls: ALPN prefers h2 and falls back to http 1.1" {
    try std.testing.expectEqual(
        support.tls.ApplicationProtocol.http2,
        support.tls.select_http_protocol("\x08http/1.1\x02h2").?,
    );
    try std.testing.expectEqual(
        support.tls.ApplicationProtocol.http1,
        support.tls.select_http_protocol("\x08http/1.1").?,
    );
    try std.testing.expect(support.tls.select_http_protocol("\x03h2") == null);
}
