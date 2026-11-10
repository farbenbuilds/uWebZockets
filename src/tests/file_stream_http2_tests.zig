const std = @import("std");
const xev = @import("xev");
const c = @import("c");
const support = @import("test_support");
const response = support.http_response;
const http2 = support.http2;
const tls_helpers = @import("tls_tests.zig");
const net = std.Io.net;

/// Counts only file effects while preserving the real positional I/O backend.
const FileIo = struct {
    base: std.Io,
    vtable: std.Io.VTable,
    reads: usize = 0,
    closes: usize = 0,
    fail_read: bool = false,
    observed_conn: ?*support.tcp.TcpConnection = null,
    fault_free: usize = 0,

    fn init() FileIo {
        var table = std.testing.io.vtable.*;
        table.fileReadPositional = read;
        table.fileClose = close;
        return .{ .base = std.testing.io, .vtable = table };
    }

    fn io(state: *FileIo) std.Io {
        return .{ .userdata = state, .vtable = &state.vtable };
    }

    fn read(context: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const state: *FileIo = @ptrCast(@alignCast(context.?));
        state.reads += 1;
        if (state.fail_read) {
            if (state.observed_conn) |conn| state.fault_free = conn.write_queue.len - conn.write_len;
            return error.InputOutput;
        }
        return state.base.vtable.fileReadPositional(state.base.userdata, file, buffers, offset);
    }

    fn close(context: ?*anyopaque, files: []const std.Io.File) void {
        const state: *FileIo = @ptrCast(@alignCast(context.?));
        state.closes += files.len;
        state.base.vtable.fileClose(state.base.userdata, files);
    }
};

/// Stable native socket permits real teardown even when an assertion fails.
const TestConnection = struct {
    loop: support.loop.Loop = undefined,
    connection: support.tcp.TcpConnection = undefined,
    listener: support.tcp.TcpServer = undefined,
    peer: ?net.Stream = null,
    accepted: bool = false,
    bundle: support.tcp.Http2Session.Bundle(.{ .header_block_size = 1024, .request_header_size = 1024, .body_size = 128 }) = .{},
    router_bundle: support.radix.DefaultBundle = .{},
    router: support.radix.Router = .{},

    fn init(state: *TestConnection, ring: []u8) !void {
        state.loop = try support.loop.init();
        errdefer support.loop.deinit(&state.loop);
        state.listener = try support.tcp.init_server("127.0.0.1", 0, accept, state);
        errdefer {
            support.tcp.close_server(&state.listener, &state.loop);
            state.loop.xev_loop.run(.until_done) catch @panic("file fixture listener did not drain");
            support.tcp.deinit_server(&state.listener);
        }
        state.connection = .{
            .socket = undefined,
            .loop = state.loop.get_xev_loop(),
            .io = std.testing.io,
            .write_queue = ring,
            .write_batch_depth = 1,
        };
        errdefer if (state.accepted) support.tcp.close_connection(&state.connection);
        state.connection.h2 = try support.tcp.Http2Session.init(state.bundle.storage());
        state.connection.protocol_state = .http2;
        state.router = try support.radix.Router.init(state.router_bundle.storage());
        state.connection.router = &state.router;
        support.tcp.accept_start(&state.listener, &state.loop);
        var address = try net.IpAddress.parse("127.0.0.1", try support.tcp.listener_port(&state.listener));
        state.peer = try address.connect(std.testing.io, .{ .mode = .stream });
        errdefer {
            state.peer.?.close(std.testing.io);
            state.peer = null;
        }
        // Wake deferred accept without waiting for its timeout; teardown discards this byte.
        try tls_helpers.write_socket_request(std.testing.io, state.peer.?.socket.handle, "x");
        var rounds: usize = 0;
        while (!state.accepted and rounds < 8) : (rounds += 1) try state.loop.xev_loop.run(.once);
        if (!state.accepted) return error.FileFixtureAcceptMissing;
        support.tcp.close_server(&state.listener, &state.loop);
        try support.tcp.set_receive_timeout(state.peer.?.socket.handle, 25);
        var handshake: [64]u8 = undefined;
        @memcpy(handshake[0..http2.client_preface.len], http2.client_preface);
        var length: usize = http2.client_preface.len;
        try append_frame(&handshake, &length, .settings, 0, 0, "");
        try state.connection.h2.receive(handshake[0..length], state.connection.http2_callbacks());
    }

    fn accept(socket: xev.TCP, context: ?*anyopaque) void {
        const state: *TestConnection = @ptrCast(@alignCast(context.?));
        if (state.accepted) {
            support.tcp.close_socket(xev.tcp_fd(socket));
            return;
        }
        state.connection.socket = socket;
        state.accepted = true;
    }

    fn deinit(state: *TestConnection) void {
        support.tcp.close_connection(&state.connection);
        support.tcp.close_server(&state.listener, &state.loop);
        state.loop.xev_loop.run(.until_done) catch @panic("file fixture close did not drain");
        support.tcp.deinit_server(&state.listener);
        if (state.peer) |peer| peer.close(std.testing.io);
        support.loop.deinit(&state.loop);
    }
};

fn create_file(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !std.Io.File {
    const file = try dir.createFile(std.testing.io, name, .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, bytes, 0);
    return file;
}

const FileRoute = struct {
    source: response.FileSource,
    status: []const u8 = "200 OK",
    path: []const u8 = "/file",
    target: ?response.Http2Target = null,
    headers: []const u8 = "",
    failure: ?anyerror = null,
    complete: bool = false,
    accepted: bool = false,

    fn handle(context: *anyopaque, _: *support.http_request.Request, output: *response.Response) void {
        const route: *FileRoute = @ptrCast(@alignCast(context));
        route.target = output.target.http2;
        output.stream_file(route.status, route.headers, route.source) catch |err| {
            route.failure = err;
            return;
        };
        route.accepted = true;
        route.complete = output.is_complete();
    }
};

fn dispatch(fixture: *TestConnection, route: *FileRoute, id: u32, method: []const u8, window: u32) !u16 {
    try fixture.router.route_context(support.radix.HttpMethod.parse(method) orelse return error.InvalidMethod, route.path, route, FileRoute.handle);
    const conn = &fixture.connection;
    const index = try conn.h2.connection.streams.acquire(id, 65_535, window);
    conn.h2.connection.streams.states[index] = .half_closed_remote;
    conn.h2.requests[index] = .{ .method = method, .path = route.path };
    const callbacks = conn.http2_callbacks();
    try callbacks.request_fn(callbacks.context, &conn.h2.requests[index], id);
    return index;
}

fn drain(fixture: *TestConnection, scratch: []u8) !void {
    const conn = &fixture.connection;
    conn.arm_write();
    var rounds: usize = 0;
    while (conn.is_writing and rounds < 256) : (rounds += 1) {
        @memset(scratch, 0xa5);
        try fixture.loop.xev_loop.run(.once);
        conn.arm_write();
    }
    try std.testing.expect(rounds < 256);
}

fn capture(fixture: *TestConnection, output: []u8, length: *usize) !void {
    while (length.* < output.len) {
        const count = tls_helpers.read_pattern_socket(fixture.peer.?.socket.handle, output[length.*..]) catch |err| switch (err) {
            error.PatternSocketTimeout => return,
            else => return err,
        };
        if (count == 0) return error.UnexpectedSocketClose;
        length.* += count;
    }
    return error.CaptureOverflow;
}

const Trace = struct {
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    headers: usize = 0,
    ends: usize = 0,
    resets: usize = 0,
    max_data: usize = 0,
    header_block: [512]u8 = undefined,
    header_len: usize = 0,
};

fn trace_frames(bytes: []const u8, stream_id: u32) !Trace {
    var trace = Trace{};
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 9) return error.TruncatedFrame;
        const header = try http2.FrameHeader.parse(bytes[offset..][0..9]);
        offset += 9;
        const end = offset + header.payload_length;
        if (end > bytes.len) return error.TruncatedFrame;
        const payload = bytes[offset..end];
        offset = end;
        if (header.stream_id != stream_id) continue;
        if (header.frame_type == @intFromEnum(http2.FrameType.headers)) {
            trace.headers += 1;
            if (payload.len > trace.header_block.len) return error.CaptureOverflow;
            @memcpy(trace.header_block[0..payload.len], payload);
            trace.header_len = payload.len;
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.data)) {
            if (payload.len > trace.body.len - trace.body_len) return error.CaptureOverflow;
            @memcpy(trace.body[trace.body_len..][0..payload.len], payload);
            trace.body_len += payload.len;
            trace.max_data = @max(trace.max_data, payload.len);
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream)) trace.resets += 1;
        if (header.flags & 1 != 0 and (header.frame_type == 0 or header.frame_type == 1)) trace.ends += 1;
    }
    return trace;
}

test "http2 file: exact bounded body finishes when final DATA exhausts both windows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "0123456789abcde";
    const file = try create_file(tmp.dir, "asset", body);
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [4]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var route = FileRoute{ .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = body.len } };
    defer if (!route.accepted) file.close(std.testing.io);
    fixture.connection.h2.connection.connection_send_window = body.len;
    const index = try dispatch(&fixture, &route, 1, "GET", body.len);
    try std.testing.expectEqual(@as(?anyerror, null), route.failure);
    try std.testing.expect(route.complete);
    try drain(&fixture, &scratch);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expectEqual(@as(i64, 0), fixture.connection.h2.connection.connection_send_window);
    try std.testing.expect(fixture.connection.h2_stream_producers[index] == null);
    var wire: [4096]u8 = undefined;
    var length: usize = 0;
    try capture(&fixture, &wire, &length);
    const trace = try trace_frames(wire[0..length], 1);
    try std.testing.expectEqualStrings(body, trace.body[0..trace.body_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.headers);
    try std.testing.expectEqual(@as(usize, 1), trace.ends);
    try std.testing.expectEqual(@as(usize, 0), trace.resets);
    try std.testing.expect(trace.max_data <= scratch.len);
    try expect_length(&trace, body.len);
}

fn expect_length(trace: *const Trace, expected: u64) !void {
    const hpack = support.http2_hpack;
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic, 0);
    var decoder = hpack.Decoder.init(&table, 512);
    var headers: [8]hpack.Header = undefined;
    var bytes: [512]u8 = undefined;
    const fields = try decoder.decode_fields(trace.header_block[0..trace.header_len], &headers, &bytes);
    var lengths: usize = 0;
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, "content-length")) continue;
        lengths += 1;
        try std.testing.expectEqual(expected, try std.fmt.parseUnsigned(u64, field.value, 10));
    }
    try std.testing.expectEqual(@as(usize, 1), lengths);
}

fn append_frame(output: []u8, length: *usize, kind: http2.FrameType, flags: u8, id: u32, payload: []const u8) !void {
    if (payload.len + 9 > output.len - length.*) return error.CaptureOverflow;
    var header: [9]u8 = undefined;
    try (http2.FrameHeader{ .payload_length = @intCast(payload.len), .frame_type = @intFromEnum(kind), .flags = flags, .stream_id = id }).encode(&header);
    @memcpy(output[length.*..][0..9], &header);
    @memcpy(output[length.* + 9 ..][0..payload.len], payload);
    length.* += 9 + payload.len;
}

fn credit(fixture: *TestConnection, id: u32, increment: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, increment, .big);
    var frame: [13]u8 = undefined;
    var length: usize = 0;
    try append_frame(&frame, &length, .window_update, 0, id, &payload);
    fixture.connection.route_decrypted_data(frame[0..length]);
    try std.testing.expect(!fixture.connection.closing);
}

test "http2 file: paused credit owns metadata and rereads poisoned shared scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "discard-exact-file-tail");
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [3]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var headers = "X-File: original\r\n".*;
    var route = FileRoute{ .headers = &headers, .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 8, .length = 10 } };
    defer if (!route.accepted) file.close(std.testing.io);
    const index = try dispatch(&fixture, &route, 1, "GET", 0);
    try std.testing.expect(route.accepted and route.complete);
    route.source.offset = 0;
    route.source.length = 1;
    @memset(&headers, '!');
    try drain(&fixture, &scratch);
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
    try std.testing.expect(fixture.connection.h2_stream_producers[index] != null);
    for (0..5) |_| {
        try credit(&fixture, 1, 2);
        try drain(&fixture, &scratch);
    }
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    var wire: [4096]u8 = undefined;
    var length: usize = 0;
    try capture(&fixture, &wire, &length);
    const trace = try trace_frames(wire[0..length], 1);
    try std.testing.expectEqualStrings("exact-file", trace.body[0..trace.body_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.ends);
    try std.testing.expect(trace.max_data <= 2);
    try expect_length(&trace, 10);
}

test "http2 file: HEAD and empty sources close once without reading" {
    for ([_]bool{ true, false }) |head| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "asset", "representation");
        var effects = FileIo.init();
        var ring: [256]u8 = undefined;
        var scratch: [1]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        var route = FileRoute{ .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = if (head) 14 else 0 } };
        defer if (!route.accepted) file.close(std.testing.io);
        _ = try dispatch(&fixture, &route, 1, if (head) "HEAD" else "GET", 0);
        try std.testing.expect(route.accepted and route.complete);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try drain(&fixture, &scratch);
        var wire: [1024]u8 = undefined;
        var length: usize = 0;
        try capture(&fixture, &wire, &length);
        const trace = try trace_frames(wire[0..length], 1);
        try std.testing.expectEqual(@as(usize, 0), trace.body_len);
        try std.testing.expectEqual(@as(usize, 1), trace.ends);
        try expect_length(&trace, if (head) 14 else 0);
    }
}

test "http2 file: forbidden framing and failed heads retain the caller descriptor" {
    const statuses = [_][]const u8{ "204 No Content", "205 Reset Content", "304 Not Modified", "200 OK", "200 OK" };
    for (statuses, 0..) |status, case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "asset", "caller");
        var effects = FileIo.init();
        var ring: [256]u8 = undefined;
        var scratch: [1]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        var route = FileRoute{ .status = status, .headers = if (case == 4) "Content-Length: 7\r\n" else "", .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = 6 } };
        defer if (!route.accepted) file.close(std.testing.io);
        _ = try dispatch(&fixture, &route, 1, if (case == 3) "CONNECT" else "GET", 1);
        try std.testing.expect(!route.accepted);
        try std.testing.expectEqual(@as(?anyerror, if (case == 4) error.InvalidHeaders else error.BodyNotAllowed), route.failure);
        try std.testing.expectEqual(@as(usize, 0), effects.closes);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        var bytes: [6]u8 = undefined;
        try std.testing.expectEqual(bytes.len, try file.readPositionalAll(std.testing.io, &bytes, 0));
        try std.testing.expectEqualStrings("caller", &bytes);
    }
}

test "http2 file: occupied slot and in-flight head pressure refuse before ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try create_file(tmp.dir, "first", "first");
    const second = try create_file(tmp.dir, "second", "second");
    var second_owned = true;
    defer if (second_owned) second.close(std.testing.io);
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [1]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var route = FileRoute{ .source = .{ .io = effects.io(), .file = first, .buffer = &scratch, .offset = 0, .length = 5 } };
    defer if (!route.accepted) first.close(std.testing.io);
    _ = try dispatch(&fixture, &route, 1, "GET", 0);
    try std.testing.expect(route.accepted);
    var output = response.Response{ .target = .{ .http2 = route.target.? } };
    const other = response.FileSource{ .io = effects.io(), .file = second, .buffer = &scratch, .offset = 0, .length = 6 };
    try expect_refusal(error.StreamAlreadyActive, &output, other, &second_owned);
    const conn = &fixture.connection;
    conn.arm_write();
    try xev.submit(conn.loop);
    try std.testing.expect(conn.is_writing);
    const padding: [256]u8 = @splat(0);
    try conn.write_data(padding[0 .. ring.len - conn.write_len]);
    const index = try conn.h2.connection.streams.acquire(3, 65_535, 1);
    conn.h2.requests[index] = .{ .method = "GET", .path = "/other" };
    var target = route.target.?;
    target.stream_id = 3;
    output = .{ .target = .{ .http2 = target } };
    try expect_refusal(error.WouldBlock, &output, other, &second_owned);
    try std.testing.expect(!conn.h2.response_started[index]);
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
}

fn expect_refusal(expected: anyerror, output: *response.Response, source: response.FileSource, caller_owns: *bool) !void {
    const result = output.stream_file("200 OK", "", source);
    if (result) |_| {
        caller_owns.* = false;
        return std.testing.expectError(expected, result);
    } else |err| return std.testing.expectEqual(expected, err);
}

test "http2 file: read faults and truncation reset only their stream" {
    for ([_]bool{ false, true }) |io_fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "asset", "short");
        var effects = FileIo.init();
        effects.fail_read = io_fault;
        var ring: [256]u8 = undefined;
        var scratch: [8]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        var route = FileRoute{ .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = 8 } };
        defer if (!route.accepted) file.close(std.testing.io);
        _ = try dispatch(&fixture, &route, 1, "GET", 8);
        try std.testing.expect(route.accepted and route.complete);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try drain(&fixture, &scratch);
        try std.testing.expect(!fixture.connection.closing);
        var wire: [1024]u8 = undefined;
        var length: usize = 0;
        try capture(&fixture, &wire, &length);
        const trace = try trace_frames(wire[0..length], 1);
        try std.testing.expectEqual(@as(usize, 1), trace.resets);
        try std.testing.expectEqual(@as(usize, 0), trace.body_len);
        try std.testing.expectEqual(@as(usize, 0), trace.ends);
    }
}

test "http2 file: reset closes before slot reuse and stale close cannot touch a sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try create_file(tmp.dir, "first", "cancelled");
    const second = try create_file(tmp.dir, "second", "next-file");
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [3]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var one = FileRoute{ .source = .{ .io = effects.io(), .file = first, .buffer = &scratch, .offset = 0, .length = 9 } };
    defer if (!one.accepted) first.close(std.testing.io);
    const index = try dispatch(&fixture, &one, 1, "GET", 0);
    try std.testing.expect(one.accepted);
    try fixture.connection.h2.reset_stream(1, .cancel, fixture.connection.http2_callbacks());
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    var two = FileRoute{ .path = "/next", .source = .{ .io = effects.io(), .file = second, .buffer = &scratch, .offset = 0, .length = 9 } };
    defer if (!two.accepted) second.close(std.testing.io);
    const reused = try dispatch(&fixture, &two, 3, "GET", 9);
    try std.testing.expectEqual(index, reused);
    try std.testing.expect(two.accepted);
    const callbacks = fixture.connection.http2_callbacks();
    callbacks.stream_closed_fn.?(callbacks.context, 1, index);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try drain(&fixture, &scratch);
    try std.testing.expectEqual(@as(usize, 2), effects.closes);
    var wire: [1024]u8 = undefined;
    var length: usize = 0;
    try capture(&fixture, &wire, &length);
    const trace = try trace_frames(wire[0..length], 3);
    try std.testing.expectEqualStrings("next-file", trace.body[0..trace.body_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.ends);
}

test "http2 file: connection close sweeps every owned stream with shared scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try create_file(tmp.dir, "first", "alpha");
    const second = try create_file(tmp.dir, "second", "bravo");
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [2]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var one = FileRoute{ .source = .{ .io = effects.io(), .file = first, .buffer = &scratch, .offset = 0, .length = 5 } };
    var two = FileRoute{ .path = "/other", .source = .{ .io = effects.io(), .file = second, .buffer = &scratch, .offset = 0, .length = 5 } };
    defer if (!one.accepted) first.close(std.testing.io);
    defer if (!two.accepted) second.close(std.testing.io);
    _ = try dispatch(&fixture, &one, 1, "GET", 0);
    _ = try dispatch(&fixture, &two, 3, "GET", 0);
    try std.testing.expect(one.accepted and two.accepted);
    try credit(&fixture, 1, 1);
    try credit(&fixture, 3, 1);
    try drain(&fixture, &scratch);
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    support.tcp.close_connection(&fixture.connection);
    support.tcp.close_connection(&fixture.connection);
    try std.testing.expectEqual(@as(usize, 2), effects.closes);
    for (fixture.connection.h2_stream_producers) |producer| try std.testing.expect(producer == null);
    for (fixture.connection.h2_files) |transfer| try std.testing.expect(transfer.file == null);
}

test "http2 file: shared scratch interleaves independent bounded streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try create_file(tmp.dir, "first", "alpha-alpha");
    const second = try create_file(tmp.dir, "second", "bravo-bravo");
    var effects = FileIo.init();
    var ring: [256]u8 = undefined;
    var scratch: [2]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var one = FileRoute{ .source = .{ .io = effects.io(), .file = first, .buffer = &scratch, .offset = 0, .length = 11 } };
    var two = FileRoute{ .path = "/other", .source = .{ .io = effects.io(), .file = second, .buffer = &scratch, .offset = 0, .length = 11 } };
    defer if (!one.accepted) first.close(std.testing.io);
    defer if (!two.accepted) second.close(std.testing.io);
    _ = try dispatch(&fixture, &one, 1, "GET", 0);
    _ = try dispatch(&fixture, &two, 3, "GET", 0);
    try std.testing.expect(one.accepted and two.accepted);
    for (0..11) |_| {
        try credit(&fixture, 1, 1);
        @memset(&scratch, 0x5a);
        try credit(&fixture, 3, 1);
        try drain(&fixture, &scratch);
    }
    var wire: [2048]u8 = undefined;
    var length: usize = 0;
    try capture(&fixture, &wire, &length);
    const a = try trace_frames(wire[0..length], 1);
    const b = try trace_frames(wire[0..length], 3);
    try std.testing.expectEqualStrings("alpha-alpha", a.body[0..a.body_len]);
    try std.testing.expectEqualStrings("bravo-bravo", b.body[0..b.body_len]);
    try std.testing.expectEqual(@as(usize, 1), a.ends);
    try std.testing.expectEqual(@as(usize, 1), b.ends);
    try std.testing.expectEqual(@as(usize, 2), effects.closes);
}

const PressureApp = support.app.app(1);
const pressure_body_size = 100 * 1024;

/// Uses real TLS records and an active socket write to pin the bounded reset FIFO.
const TlsPressure = struct {
    file: FileRoute,
    effects: *FileIo,
    success_effects: *FileIo,
    body: [pressure_body_size]u8 = undefined,
    offset: usize = 0,
    pressured: bool = false,
    healthy: bool = false,
    failure: ?anyerror = null,
    connection: ?*support.tcp.TcpConnection = null,
    stream_id: u32 = 0,
    frame_overhead: usize = 0,
    pressure_prefix: usize = 0,

    fn begin(context: *anyopaque, _: *support.http_request.Request, output: *response.Response) void {
        const state: *TlsPressure = @ptrCast(@alignCast(context));
        state.connection = @ptrCast(@alignCast(output.target.http2.context));
        state.effects.observed_conn = state.connection;
        state.stream_id = output.target.http2.stream_id;
        output.begin_stream("200 OK", "", state, produce) catch |err| {
            state.failure = err;
        };
    }

    fn health(context: *anyopaque, _: *support.http_request.Request, output: *response.Response) void {
        const state: *TlsPressure = @ptrCast(@alignCast(context));
        state.healthy = state.effects.closes == 1 and state.effects.fault_free == 140 and state.success_effects.closes == 1;
        output.end("200 OK", "ok") catch |err| {
            state.failure = err;
        };
    }

    fn produce(context: *anyopaque, output: *response.Response) anyerror!response.StreamStatus {
        const state: *TlsPressure = @ptrCast(@alignCast(context));
        const conn = state.connection.?;
        const index = conn.h2.connection.streams.find(state.stream_id) orelse return error.StreamClosed;
        if (conn.h2.connection.streams.send_windows[index] <= 0) return .pending;
        if (!state.pressured) return state.fill_pressure(output, conn);
        while (state.offset < state.body.len) {
            const size = @min(state.body.len - state.offset, 16 * 1024);
            output.write_chunk(state.body[state.offset..][0..size]) catch |err| {
                if (err == error.WouldBlock) return .pending;
                return err;
            };
            state.offset += size;
        }
        try output.end_chunks();
        return .done;
    }

    fn fill_pressure(state: *TlsPressure, output: *response.Response, conn: *support.tcp.TcpConnection) !response.StreamStatus {
        conn.begin_write_batch();
        defer conn.end_write_batch();
        const before = conn.write_len;
        try output.write_chunk(state.body[0..1]);
        state.offset = 1;
        state.frame_overhead = conn.write_len - before - 1;
        while (conn.write_queue.len - conn.write_len > 140) {
            const free = conn.write_queue.len - conn.write_len;
            if (free <= 140 + state.frame_overhead) return error.PressureBoundaryUnreachable;
            const size = @min(16 * 1024, free - 140 - state.frame_overhead);
            try output.write_chunk(state.body[state.offset..][0..size]);
            state.offset += size;
        }
        if (conn.write_queue.len - conn.write_len != 140) return error.PressureBoundaryMismatch;
        state.pressure_prefix = state.offset;
        state.pressured = true;
        // A submitted writer prevents the following file fault from flushing
        // the ring synchronously before its RST_STREAM reservation is tested.
        conn.arm_write();
        return .pending;
    }
};

const TlsRunner = struct {
    server: *PressureApp,
    failure: ?anyerror = null,

    fn run(state: *TlsRunner) void {
        state.server.run() catch |err| {
            state.failure = err;
        };
    }
};

const TlsClient = struct {
    stream: net.Stream,
    context: *c.SSL_CTX,
    ssl: *c.SSL,
    bio: *c.BIO,

    fn connect(port: u16) !TlsClient {
        var address = try net.IpAddress.parse("127.0.0.1", port);
        const stream = try address.connect(std.testing.io, .{ .mode = .stream });
        errdefer stream.close(std.testing.io);
        try support.tcp.set_receive_timeout(stream.socket.handle, 5_000);
        const context = try tls_helpers.create_socket_client_context();
        errdefer c.SSL_CTX_free(context);
        const ssl = c.SSL_new(context) orelse return error.ClientSslFailed;
        errdefer c.SSL_free(ssl);
        const bio = try tls_helpers.attach_client_bio(ssl);
        errdefer _ = c.BIO_free(bio);
        c.SSL_set_connect_state(ssl);
        if (c.SSL_set_alpn_protos(ssl, "\x02h2", 3) != 0) return error.ClientAlpnFailed;
        try tls_helpers.drive_client_handshake(std.testing.io, stream.socket.handle, ssl, bio);
        try std.testing.expectEqual(support.tls.ApplicationProtocol.http2, support.tls.negotiated_protocol(ssl));
        return .{ .stream = stream, .context = context, .ssl = ssl, .bio = bio };
    }

    fn close(client: *TlsClient) void {
        c.SSL_free(client.ssl);
        _ = c.BIO_free(client.bio);
        c.SSL_CTX_free(client.context);
        client.stream.close(std.testing.io);
    }

    fn send(client: *TlsClient, bytes: []const u8) !void {
        try tls_helpers.ssl_write_all(std.testing.io, client.stream.socket.handle, client.ssl, client.bio, bytes);
    }

    fn read(client: *TlsClient, output: []u8) !usize {
        for (0..256) |_| {
            const count = c.SSL_read(client.ssl, output.ptr, @intCast(@min(output.len, 16 * 1024)));
            if (count > 0) return @intCast(count);
            const result = c.SSL_get_error(client.ssl, count);
            if (result != c.SSL_ERROR_WANT_READ and result != c.SSL_ERROR_WANT_WRITE) return error.ResponseTlsFailed;
            try tls_helpers.flush_cluster_bio(std.testing.io, client.stream.socket.handle, client.bio);
            if (result == c.SSL_ERROR_WANT_WRITE) continue;
            var input: [8192]u8 = undefined;
            const received = try tls_helpers.read_pattern_socket(client.stream.socket.handle, &input);
            if (received == 0) return error.ResponseTruncated;
            if (c.BIO_write(client.bio, &input, @intCast(received)) != received) return error.ClientBioFull;
        }
        return error.ResponseRetryLimit;
    }
};

/// Consumes complete frames until both the healthy end and the failed sibling reset arrive.
fn read_tls_frames(client: *TlsClient, bytes: []u8, healthy_id: u32, reset_id: ?u32) !usize {
    var length: usize = 0;
    var offset: usize = 0;
    var ended = false;
    var reset = reset_id == null;
    for (0..512) |_| {
        while (length - offset >= 9) {
            const head = try http2.FrameHeader.parse(bytes[offset..][0..9]);
            const size = 9 + head.payload_length;
            if (size > length - offset) break;
            if (head.stream_id == healthy_id and head.flags & 1 != 0 and (head.frame_type == 0 or head.frame_type == 1)) ended = true;
            if (reset_id) |id| {
                if (head.stream_id == id and head.frame_type == @intFromEnum(http2.FrameType.rst_stream)) reset = true;
            }
            offset += size;
        }
        if (ended and reset) return length;
        if (length == bytes.len) return error.CaptureOverflow;
        length += try client.read(bytes[length..]);
    }
    return error.ResponseRetryLimit;
}

fn append_request(bytes: []u8, length: *usize, id: u32, path: []const u8, head: bool) !void {
    var block: [64]u8 = undefined;
    var size: usize = 0;
    if (head) {
        @memcpy(block[0..6], "\x02\x04HEAD");
        size = 6;
    } else {
        block[0] = 0x82;
        size = 1;
    }
    block[size] = 0x87;
    block[size + 1] = 0x04;
    block[size + 2] = @intCast(path.len);
    @memcpy(block[size + 3 ..][0..path.len], path);
    size += 3 + path.len;
    try append_frame(bytes, length, .headers, 0x5, id, block[0..size]);
}

test "http2 file: real TLS ciphertext pressure retries reset and preserves healthy streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "fault");
    var effects = FileIo.init();
    effects.fail_read = true;
    var scratch: [1]u8 = undefined;
    var success_effects = FileIo.init();
    var success_scratch: [8192]u8 = undefined;
    var state = TlsPressure{ .file = .{ .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = 1 } }, .effects = &effects, .success_effects = &success_effects };
    for (&state.body, 0..) |*byte, index| byte.* = @truncate((index * 37) ^ (index >> 3));
    defer if (!state.file.accepted) file.close(std.testing.io);
    const success_file = try create_file(tmp.dir, "success", &state.body);
    var success = FileRoute{ .source = .{ .io = success_effects.io(), .file = success_file, .buffer = &success_scratch, .offset = 0, .length = state.body.len } };
    defer if (!success.accepted) success_file.close(std.testing.io);
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var server = try PressureApp.init_configured(std.testing.io, allocations.allocator(), .{ .max_connections = 1 });
    defer server.deinit();
    server.tls_ctx = try support.tls.TlsContext.init_ephemeral(.{});
    _ = try server.get_context("/healthy", &state, TlsPressure.begin);
    _ = try server.get_context("/file", &state.file, FileRoute.handle);
    _ = try server.get_context("/health", &state, TlsPressure.health);
    _ = try server.get_context("/success", &success, FileRoute.handle);
    try server.listen("127.0.0.1", 0);
    var runner = TlsRunner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, TlsRunner.run, .{&runner});
    var joined = false;
    defer {
        server.request_shutdown();
        if (!joined) thread.join();
    }
    var client = try TlsClient.connect(try support.tcp.listener_port(&server.listeners[0]));
    defer client.close();
    var request: [256]u8 = undefined;
    @memcpy(request[0..http2.client_preface.len], http2.client_preface);
    var request_len: usize = http2.client_preface.len;
    try append_frame(&request, &request_len, .settings, 0, 0, "\x00\x04\x00\x00\x00\x00");
    try append_request(&request, &request_len, 1, "/healthy", false);
    try append_request(&request, &request_len, 3, "/file", false);
    const window: [4]u8 = .{ 0, 3, 0x0d, 0x40 };
    try append_frame(&request, &request_len, .window_update, 0, 0, &window);
    try append_frame(&request, &request_len, .window_update, 0, 1, &window);
    try append_frame(&request, &request_len, .window_update, 0, 3, "\x00\x00\x00\x01");
    try client.send(request[0..request_len]);
    var wire: [pressure_body_size + 8192]u8 = undefined;
    const length = try read_tls_frames(&client, &wire, 1, 3);
    const failed = try trace_frames(wire[0..length], 3);
    try std.testing.expectEqual(@as(usize, 1), failed.resets);
    try std.testing.expectEqual(@as(usize, 0), failed.body_len);
    var offset: usize = 0;
    var body_offset: usize = 0;
    var reset_offset: ?usize = null;
    var end_offset: ?usize = null;
    while (offset < length) {
        const head = try http2.FrameHeader.parse(wire[offset..][0..9]);
        const payload = wire[offset + 9 ..][0..head.payload_length];
        if (head.stream_id == 3 and head.frame_type == 3) reset_offset = offset;
        if (head.stream_id == 1 and head.frame_type == 0) {
            if (body_offset + payload.len > state.pressure_prefix) try std.testing.expect(reset_offset != null);
            try std.testing.expectEqualSlices(u8, state.body[body_offset..][0..payload.len], payload);
            body_offset += payload.len;
            if (head.flags & 1 != 0) end_offset = offset;
        }
        offset += 9 + payload.len;
    }
    try std.testing.expectEqual(state.body.len, body_offset);
    try std.testing.expect(reset_offset.? < end_offset.?);
    request_len = 0;
    try append_request(&request, &request_len, 5, "/success", false);
    try append_frame(&request, &request_len, .window_update, 0, 5, &window);
    try client.send(request[0..request_len]);
    const success_len = try read_tls_frames(&client, &wire, 5, null);
    try expect_tls_body(wire[0..success_len], 5, &state.body);
    request_len = 0;
    try append_request(&request, &request_len, 7, "/health", true);
    try client.send(request[0..request_len]);
    const health_len = try read_tls_frames(&client, &wire, 7, null);
    const health = try trace_frames(wire[0..health_len], 7);
    try std.testing.expectEqual(@as(usize, 1), health.ends);
    server.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null and state.failure == null and state.file.failure == null);
    try std.testing.expect(state.file.accepted and state.file.complete and state.pressured and state.healthy);
    try std.testing.expect(success.accepted and success.complete and success.failure == null);
    try std.testing.expectEqual(@as(usize, 1), success_effects.closes);
    try std.testing.expect(success_effects.reads > 1);
    try std.testing.expectEqual(@as(usize, 140), effects.fault_free);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expectEqual(@as(usize, 1), effects.reads);
    try std.testing.expectEqual(@as(usize, 64 * 1024), server.write_queue_storage.len);
    try std.testing.expectEqual(@as(usize, 1), allocations.allocations);
    try std.testing.expectEqual(@as(usize, 0), allocations.resize_index);
    try std.testing.expect(!allocations.has_induced_failure);
}

/// Verifies successful known-length file DATA separately from a sibling reset trace.
fn expect_tls_body(bytes: []const u8, id: u32, expected: []const u8) !void {
    var offset: usize = 0;
    var body_offset: usize = 0;
    var ends: usize = 0;
    var trace = Trace{};
    while (offset < bytes.len) {
        const header = try http2.FrameHeader.parse(bytes[offset..][0..9]);
        const payload = bytes[offset + 9 ..][0..header.payload_length];
        offset += 9 + payload.len;
        if (header.stream_id != id) continue;
        if (header.frame_type == 1) {
            @memcpy(trace.header_block[0..payload.len], payload);
            trace.header_len = payload.len;
            trace.headers += 1;
        }
        if (header.frame_type == 0) {
            try std.testing.expect(payload.len <= 8192);
            try std.testing.expectEqualSlices(u8, expected[body_offset..][0..payload.len], payload);
            body_offset += payload.len;
            if (header.flags & 1 != 0) ends += 1;
        }
        try std.testing.expect(header.frame_type != 3);
    }
    try std.testing.expectEqual(expected.len, body_offset);
    try std.testing.expectEqual(@as(usize, 1), ends);
    try std.testing.expectEqual(@as(usize, 1), trace.headers);
    try expect_length(&trace, expected.len);
}

// Refused heads and reset-only requests must not look like completed exchanges.
test "http2 file: immediate completion logs once across drain reset and slot reuse" {
    for ([_]bool{ true, false }) |head| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const log_file = try create_file(tmp.dir, "requests", "");
        defer log_file.close(std.testing.io);
        var sink = support.dev_log.Sink{};
        sink.enable(std.testing.io, log_file);
        var registry = support.metrics.Registry{};
        var effects = FileIo.init();
        var ring: [256]u8 = undefined;
        var scratch: [1]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        const conn = &fixture.connection;
        conn.dev_log = &sink;
        conn.metrics = &registry;
        const first = try create_file(tmp.dir, "first", "file");
        var done = FileRoute{ .source = .{ .io = effects.io(), .file = first, .buffer = &scratch, .offset = 0, .length = if (head) 4 else 0 } };
        defer if (!done.accepted) first.close(std.testing.io);
        const index = try dispatch(&fixture, &done, 1, if (head) "HEAD" else "GET", 0);
        try std.testing.expect(done.accepted and done.complete);
        try expect_request_log(log_file, if (head) "HEAD" else "GET", "/file");
        try drain(&fixture, &scratch);
        conn.pump_http2_streams();
        const callbacks = conn.http2_callbacks();
        callbacks.stream_closed_fn.?(callbacks.context, 1, index);
        const next_file = try create_file(tmp.dir, "next", "file");
        var next = FileRoute{ .path = "/reuse", .source = .{ .io = effects.io(), .file = next_file, .buffer = &scratch, .offset = 0, .length = 4 } };
        defer if (!next.accepted) next_file.close(std.testing.io);
        try std.testing.expectEqual(index, try dispatch(&fixture, &next, 3, "GET", 0));
        try std.testing.expect(next.accepted);
        try conn.h2.reset_stream(3, .cancel, callbacks);
        const fault_file = try create_file(tmp.dir, "fault", "file");
        var fault = FileRoute{ .path = "/fault", .source = .{ .io = effects.io(), .file = fault_file, .buffer = &scratch, .offset = 0, .length = 1 } };
        defer if (!fault.accepted) fault_file.close(std.testing.io);
        effects.fail_read = true;
        _ = try dispatch(&fixture, &fault, 5, "GET", 1);
        try std.testing.expect(fault.accepted);
        try drain(&fixture, &scratch);
        try std.testing.expectEqual(@as(usize, 3), effects.closes);
        try std.testing.expectEqual(@as(u64, 3), registry.get(.http_requests));
        try expect_request_log(log_file, if (head) "HEAD" else "GET", "/file");
        const refused_file = try create_file(tmp.dir, "refused", "file");
        var caller_owns = true;
        defer if (caller_owns) refused_file.close(std.testing.io);
        const padding: [256]u8 = @splat(0);
        try conn.write_data(&padding);
        conn.arm_write();
        try xev.submit(conn.loop);
        try std.testing.expect(conn.is_writing);
        const refused_index = try conn.h2.connection.streams.acquire(7, 65_535, 1);
        conn.h2.requests[refused_index] = .{ .method = "GET", .path = "/refused" };
        var target = done.target.?;
        target.stream_id = 7;
        var output = response.Response{ .target = .{ .http2 = target } };
        try expect_refusal(error.WouldBlock, &output, .{ .io = effects.io(), .file = refused_file, .buffer = &scratch, .offset = 0, .length = 4 }, &caller_owns);
        try expect_request_log(log_file, if (head) "HEAD" else "GET", "/file");
    }
}

fn expect_request_log(file: std.Io.File, method: []const u8, path: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const length = try file.readPositionalAll(std.testing.io, &buffer, 0);
    const contents = buffer[0..length];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, contents, "\n"));
    var prefix_buffer: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s}[{s}]{s} {s} : ", .{ support.dev_log.Ansi.cyan, method, support.dev_log.Ansi.reset, path });
    try std.testing.expect(std.mem.find(u8, contents, prefix) != null);
    try std.testing.expect(std.mem.find(u8, contents, "200" ++ support.dev_log.Ansi.reset) != null);
}
