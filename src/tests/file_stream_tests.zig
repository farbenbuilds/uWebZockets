const std = @import("std");
const xev = @import("xev");
const c = @import("c");
const support = @import("test_support");
const response = support.http_response;
const tls_helpers = @import("tls_tests.zig");
const net = std.Io.net;

/// Counts only file effects while preserving the real positional I/O backend.
const FileIo = struct {
    base: std.Io,
    vtable: std.Io.VTable,
    reads: usize = 0,
    closes: usize = 0,

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
        return state.base.vtable.fileReadPositional(state.base.userdata, file, buffers, offset);
    }

    fn close(context: ?*anyopaque, files: []const std.Io.File) void {
        const state: *FileIo = @ptrCast(@alignCast(context.?));
        state.closes += files.len;
        state.base.vtable.fileClose(state.base.userdata, files);
    }
};

/// Stable native socket permits real teardown even when an assertion fails.
pub const TestConnection = struct {
    loop: support.loop.Loop = undefined,
    connection: support.tcp.TcpConnection = undefined,
    listener: support.tcp.TcpServer = undefined,
    peer: ?net.Stream = null,
    accepted: bool = false,

    pub fn init(state: *TestConnection, ring: []u8) !void {
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

    pub fn deinit(state: *TestConnection) void {
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

fn copy_output(conn: *support.tcp.TcpConnection, output: []u8, length: *usize) !void {
    if (conn.write_len > output.len - length.*) return error.CaptureOverflow;
    const first = @min(conn.write_len, conn.write_queue.len - conn.write_head);
    @memcpy(output[length.*..][0..first], conn.write_queue[conn.write_head..][0..first]);
    @memcpy(output[length.* + first ..][0 .. conn.write_len - first], conn.write_queue[0 .. conn.write_len - first]);
    length.* += conn.write_len;
    conn.write_len = 0;
    conn.write_head = 0;
}

/// Assertion failures must respect a descriptor unexpectedly accepted by the transport.
fn expect_file_refusal(expected: anyerror, output: *response.Response, status: []const u8, headers: []const u8, source: response.FileSource, caller_owns: *bool) !void {
    const result = output.stream_file(status, headers, source);
    if (result) |_| {
        caller_owns.* = false;
        return std.testing.expectError(expected, result);
    } else |err| return std.testing.expectEqual(expected, err);
}

test "file stream: known-length body survives bounded drains and ends the caller" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "bounded-file-" ** 90;
    const file = try create_file(tmp.dir, "asset", body);
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    var effects = FileIo.init();
    var ring: [128]u8 = undefined;
    var scratch: [31]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;
    var res = response.Response{ .target = .{ .tcp = conn } };
    try res.stream_file("200 OK", "X-File: yes\r\n", .{
        .io = effects.io(),
        .file = file,
        .buffer = &scratch,
        .offset = 7,
        .length = body.len - 13,
    });
    caller_owns = false;
    try std.testing.expect(res.is_complete());
    try std.testing.expectError(error.ResponseNotStreaming, res.write_chunk("extra"));
    try std.testing.expectError(error.ResponseNotStreaming, res.end_chunks());
    try std.testing.expect(conn.stream_producer != null);
    var output: [2048]u8 = undefined;
    var length: usize = 0;
    var rounds: usize = 0;
    while (conn.stream_producer != null and rounds < 128) : (rounds += 1) {
        try copy_output(conn, &output, &length);
        @memset(&scratch, 0xa5);
        conn.pump_stream_body();
    }
    try copy_output(conn, &output, &length);
    try std.testing.expect(rounds < 128);
    var head_buffer: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nX-File: yes\r\n\r\n", .{body.len - 13});
    try std.testing.expectEqualStrings(head, output[0..head.len]);
    try std.testing.expectEqualSlices(u8, body[7 .. body.len - 6], output[head.len..length]);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(effects.reads > 1);
    const reads = effects.reads;
    conn.pump_stream_body();
    try std.testing.expectEqual(reads, effects.reads);
    try std.testing.expectEqual(ring[0..].ptr, conn.write_queue.ptr);
    try std.testing.expectEqual(ring.len, conn.write_queue.len);
}

test "file stream: HEAD and empty bodies close without a file read" {
    for ([_]bool{ false, true }) |head| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "asset", "representation");
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        var effects = FileIo.init();
        var ring: [128]u8 = undefined;
        var scratch: [1]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        fixture.connection.suppress_response_body = head;
        var res = response.Response{ .target = .{ .tcp = &fixture.connection } };
        try res.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = if (head) 14 else 0,
        });
        caller_owns = false;
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try std.testing.expect(fixture.connection.stream_producer == null);
        try std.testing.expectEqualStrings(
            if (head) "HTTP/1.1 200 OK\r\nContent-Length: 14\r\n\r\n" else "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            ring[0..fixture.connection.write_len],
        );
    }
}

test "file stream: validation and atomic head refusal retain caller ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "body");
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    var effects = FileIo.init();
    var ring: [128]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;
    const source = response.FileSource{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = 4 };
    for ([_][]const u8{ "204 No Content", "205 Reset Content", "304 Not Modified" }) |status| {
        var res = response.Response{ .target = .{ .tcp = conn } };
        try expect_file_refusal(error.BodyNotAllowed, &res, status, "", source, &caller_owns);
        try std.testing.expect(!res.is_started());
    }
    var res = response.Response{ .target = .{ .tcp = conn } };
    try expect_file_refusal(error.InvalidStatus, &res, "999 invalid", "", source, &caller_owns);
    try expect_file_refusal(error.InvalidHeaders, &res, "200 OK", "Content-Length: 4\r\n", source, &caller_owns);
    var invalid = source;
    invalid.buffer = &.{};
    try expect_file_refusal(error.InvalidFileSource, &res, "200 OK", "", invalid, &caller_owns);
    invalid = source;
    invalid.offset = std.math.maxInt(u64);
    try expect_file_refusal(error.InvalidFileSource, &res, "200 OK", "", invalid, &caller_owns);
    conn.req.method = "CONNECT";
    try expect_file_refusal(error.BodyNotAllowed, &res, "200 OK", "", source, &caller_owns);
    conn.req.method = "GET";
    conn.write_len = ring.len;
    @memset(&ring, 0x71);
    // Keep real writer ownership until its completion, even if the peer accepts bytes.
    conn.arm_write();
    try xev.submit(conn.loop);
    try std.testing.expect(conn.is_writing);
    try std.testing.expectEqual(ring.len, conn.write_in_flight_len);
    try expect_file_refusal(error.WouldBlock, &res, "200 OK", "", source, &caller_owns);
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
    try std.testing.expect(conn.stream_producer == null);
    try std.testing.expect(!res.is_started());
}

/// The following handler must wait until the fixed-length body has drained.
const Pipeline = struct {
    source: response.FileSource,
    first: usize = 0,
    second: usize = 0,
    failure: ?anyerror = null,
    accepted: bool = false,

    fn file_route(context: *anyopaque, _: *support.http_request.Request, res: *response.Response) void {
        const state: *Pipeline = @ptrCast(@alignCast(context));
        state.first += 1;
        res.stream_file("200 OK", "", state.source) catch |err| {
            state.failure = err;
            return;
        };
        state.accepted = true;
    }

    fn next_route(context: *anyopaque, _: *support.http_request.Request, res: *response.Response) void {
        const state: *Pipeline = @ptrCast(@alignCast(context));
        state.second += 1;
        res.end("200 OK", "next") catch |err| {
            state.failure = err;
        };
    }
};

test "file stream: direct buffered begin validates scratch and range bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "body");
    defer file.close(std.testing.io);
    var ring: [128]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;

    const empty = response.FileSource{
        .io = std.testing.io,
        .file = file,
        .buffer = &.{},
        .offset = 0,
        .length = 4,
    };
    try std.testing.expectError(
        error.InvalidFileSource,
        conn.begin_buffered_file_response("200 OK", "", "", empty, false),
    );

    const overflow = response.FileSource{
        .io = std.testing.io,
        .file = file,
        .buffer = &scratch,
        .offset = std.math.maxInt(u64),
        .length = 1,
    };
    try std.testing.expectError(
        error.InvalidFileSource,
        conn.begin_buffered_file_response("200 OK", "", "", overflow, false),
    );
    try std.testing.expect(!conn.dispatch_suspended);
    try std.testing.expect(conn.buffered_file.file == null);
}

test "file stream: a ring-filling final body drains before the next pipelined head" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = [_]u8{0x7b} ** 216;
    const file = try create_file(tmp.dir, "asset", &body);
    var effects = FileIo.init();
    var scratch: [256]u8 = undefined;
    var state = Pipeline{ .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = body.len } };
    defer if (!state.accepted) file.close(std.testing.io);
    var bundle = support.radix.Bundle(.{ .max_nodes = 8, .max_pattern_routes = 0, .max_route_path_size = 64, .registry_storage_size = 128 }){};
    var router = try support.radix.Router.init(bundle.storage());
    try router.route_context(.get, "/file", &state, Pipeline.file_route);
    try router.route_context(.get, "/next", &state, Pipeline.next_route);
    var ring: [128]u8 = undefined;
    var request: [256]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;
    conn.router = &router;
    conn.request_buffer = &request;
    conn.protocol_state = .http;
    var input = "GET /file HTTP/1.1\r\nHost: localhost\r\n\r\nGET /next HTTP/1.1\r\nHost: localhost\r\n\r\n".*;
    conn.route_decrypted_data(&input);
    try std.testing.expect(state.failure == null);
    try std.testing.expectEqual(@as(usize, 1), state.first);
    try std.testing.expectEqual(@as(usize, 0), state.second);
    try std.testing.expectEqual(ring.len, conn.write_len);
    var output: [512]u8 = undefined;
    var length: usize = 0;
    try copy_output(conn, &output, &length);
    conn.pump_stream_body();
    try std.testing.expectEqual(ring.len, conn.write_len);
    try std.testing.expectEqual(@as(usize, 0), state.second);
    conn.pump_stream_body();
    try std.testing.expectEqual(@as(usize, 0), state.second);
    try std.testing.expect(!conn.closing);
    try copy_output(conn, &output, &length);
    conn.pump_stream_body();
    try std.testing.expectEqual(@as(usize, 1), state.second);
    try std.testing.expect(state.failure == null);
    try std.testing.expect(!conn.closing);
    try copy_output(conn, &output, &length);
    try std.testing.expectEqualSlices(
        u8,
        "HTTP/1.1 200 OK\r\nContent-Length: 216\r\n\r\n" ++ body ++ "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnext",
        output[0..length],
    );
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
}

/// Legacy target initializers have no file slot and must remain source compatible.
const UnsupportedTarget = struct {
    fn end2(_: *anyopaque, _: u32, _: []const u8, _: []const u8, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn begin2(_: *anyopaque, _: u32, _: []const u8, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn write2(_: *anyopaque, _: u32, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn finish2(_: *anyopaque, _: u32) !void {
        return error.UnexpectedDispatch;
    }
    fn end3(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn begin3(_: *anyopaque, _: []const u8, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn write3(_: *anyopaque, _: []const u8) !void {
        return error.UnexpectedDispatch;
    }
    fn finish3(_: *anyopaque) !void {
        return error.UnexpectedDispatch;
    }
};

test "file stream: unavailable framed targets preserve descriptor ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "body");
    defer file.close(std.testing.io);
    var effects = FileIo.init();
    var scratch: [16]u8 = undefined;
    var context: u8 = 0;
    const targets = [_]response.ConnectionTarget{
        .{ .http2 = .{
            .context = &context,
            .router = &context,
            .stream_id = 1,
            .end_fn = UnsupportedTarget.end2,
            .begin_fn = UnsupportedTarget.begin2,
            .write_fn = UnsupportedTarget.write2,
            .finish_fn = UnsupportedTarget.finish2,
        } },
        .{ .http3 = .{
            .context = &context,
            .end_fn = UnsupportedTarget.end3,
            .begin_fn = UnsupportedTarget.begin3,
            .write_fn = UnsupportedTarget.write3,
            .finish_fn = UnsupportedTarget.finish3,
        } },
    };
    for (targets) |target| {
        var res = response.Response{ .target = target };
        try std.testing.expectError(error.FileStreamingUnsupported, res.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = 4,
        }));
        try std.testing.expect(!res.is_started());
    }
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
}

test "file stream: a post-accept EOF closes internally without returning ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try create_file(tmp.dir, "asset", "short");
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    var effects = FileIo.init();
    var scratch: [16]u8 = undefined;
    var ring: [128]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var res = response.Response{ .target = .{ .tcp = &fixture.connection } };
    try res.stream_file("200 OK", "", .{
        .io = effects.io(),
        .file = file,
        .buffer = &scratch,
        .offset = 0,
        .length = 16,
    });
    caller_owns = false;
    try std.testing.expect(res.is_complete());
    try std.testing.expect(fixture.connection.closing);
    try std.testing.expect(fixture.connection.stream_producer == null);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    support.tcp.close_connection(&fixture.connection);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
}

test "file stream: mid-transfer truncation and connection teardown close once" {
    for ([_]bool{ false, true }) |truncate| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "asset", "bounded file contents" ** 8);
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        const writer = try tmp.dir.openFile(std.testing.io, "asset", .{ .mode = .write_only });
        defer writer.close(std.testing.io);
        var effects = FileIo.init();
        var scratch: [16]u8 = undefined;
        var ring: [128]u8 = undefined;
        var fixture = TestConnection{};
        try fixture.init(&ring);
        defer fixture.deinit();
        const conn = &fixture.connection;
        var res = response.Response{ .target = .{ .tcp = conn } };
        try res.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = 160,
        });
        caller_owns = false;
        try std.testing.expectEqual(@as(usize, 1), effects.reads);
        if (truncate) {
            try writer.setLength(std.testing.io, 16);
            conn.write_len = 0;
            conn.write_head = 0;
            conn.pump_stream_body();
        } else support.tcp.close_connection(conn);
        try std.testing.expect(conn.closing);
        try std.testing.expect(conn.stream_producer == null);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        support.tcp.close_connection(conn);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
    }
}

test "file stream: protocol reset releases ownership before the slot is reused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try create_file(tmp.dir, "first", "old-file" ** 8);
    var owns_first = true;
    defer if (owns_first) first.close(std.testing.io);
    const second = try create_file(tmp.dir, "second", "new-file");
    var owns_second = true;
    defer if (owns_second) second.close(std.testing.io);
    var effects = FileIo.init();
    var scratch: [4]u8 = undefined;
    var ring: [128]u8 = undefined;
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;
    var h2 = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2.storage());
    var old = response.Response{ .target = .{ .tcp = conn } };
    try old.stream_file("200 OK", "", .{
        .io = effects.io(),
        .file = first,
        .buffer = &scratch,
        .offset = 0,
        .length = 64,
    });
    owns_first = false;
    var next = response.Response{ .target = .{ .tcp = conn } };
    const source = response.FileSource{ .io = effects.io(), .file = second, .buffer = &scratch, .offset = 0, .length = 8 };
    try std.testing.expectError(error.FileBodyAlreadyActive, next.stream_file("200 OK", "", source));
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    conn.write_len = 0;
    conn.write_head = 0;
    try conn.reset_protocol();
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(conn.stream_producer == null);
    try next.stream_file("200 OK", "", source);
    owns_second = false;
    var output: [128]u8 = undefined;
    var length: usize = 0;
    var rounds: usize = 0;
    while (conn.stream_producer != null and rounds < 8) : (rounds += 1) {
        try copy_output(conn, &output, &length);
        conn.pump_stream_body();
    }
    try copy_output(conn, &output, &length);
    try std.testing.expect(rounds < 8);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nnew-file", output[0..length]);
    try std.testing.expectEqual(@as(usize, 2), effects.closes);
}

const file_size = 100 * 1024;
const FileApp = support.app.app(1);

/// The route scratch is stable and distinct from the TLS ciphertext scratch.
const SocketFile = struct {
    source: response.FileSource,
    effects: *FileIo,
    accepted: bool = false,
    healthy: bool = false,
    failure: ?anyerror = null,

    fn handle(context: *anyopaque, _: *support.http_request.Request, res: *response.Response) void {
        const state: *SocketFile = @ptrCast(@alignCast(context));
        res.stream_file("200 OK", "Content-Type: application/octet-stream\r\n", state.source) catch |err| {
            state.failure = err;
            return;
        };
        state.accepted = true;
    }

    fn health(context: *anyopaque, _: *support.http_request.Request, res: *response.Response) void {
        const state: *SocketFile = @ptrCast(@alignCast(context));
        if (state.effects.closes != 1) {
            state.failure = error.FileNotReleasedBeforeNextRequest;
            return;
        }
        res.end("200 OK", "ok") catch |err| {
            state.failure = err;
            return;
        };
        state.healthy = true;
    }
};

/// Owns no server storage; the application remains at one stable address.
const FileRunner = struct {
    server: *FileApp,
    failure: ?anyerror = null,

    fn run(state: *FileRunner) void {
        state.server.run() catch |err| {
            state.failure = err;
        };
    }
};

/// SSL owns its peer BIO; the returned network BIO has a separate reference.
const FileClient = struct {
    stream: net.Stream,
    context: ?*c.SSL_CTX = null,
    ssl: ?*c.SSL = null,
    bio: ?*c.BIO = null,
};

test "file stream: real TLS sends a large exact-length file through an 8 KiB window" {
    try expect_socket_file(true);
}

test "file stream: plaintext buffered fallback preserves exact bytes and keepalive" {
    try expect_socket_file(false);
}

fn expect_socket_file(encrypted: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var body: [file_size]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate((index * 37) ^ (index >> 3));
    const file = try create_file(tmp.dir, "asset", &body);
    var effects = FileIo.init();
    var scratch: [8192]u8 = undefined;
    var state = SocketFile{
        .source = .{ .io = effects.io(), .file = file, .buffer = &scratch, .offset = 0, .length = body.len },
        .effects = &effects,
    };
    defer if (!state.accepted) file.close(std.testing.io);
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var server = try FileApp.init_configured(std.testing.io, allocations.allocator(), .{ .max_connections = 1 });
    defer server.deinit();
    if (encrypted) server.tls_ctx = try support.tls.TlsContext.init_ephemeral(.{});
    _ = try server.get_context("/file", &state, SocketFile.handle);
    _ = try server.get_context("/health", &state, SocketFile.health);
    try server.listen("127.0.0.1", 0);
    const port = try support.tcp.listener_port(&server.listeners[0]);
    const queue = server.write_queue_storage;
    var runner = FileRunner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, FileRunner.run, .{&runner});
    var joined = false;
    defer {
        server.request_shutdown();
        if (!joined) thread.join();
    }
    var client = try connect_file_client(port, encrypted);
    defer close_file_client(&client);
    try send_file_request(&client, "GET /file HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try expect_file_bytes(&client, "HTTP/1.1 200 OK\r\nContent-Length: 102400\r\nContent-Type: application/octet-stream\r\n\r\n", &body);
    try send_file_request(&client, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try expect_file_bytes(&client, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", "ok");
    server.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
    try std.testing.expect(state.failure == null);
    try std.testing.expect(state.accepted and state.healthy);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(effects.reads > 1);
    try std.testing.expectEqual(@as(usize, 64 * 1024), queue.len);
    try std.testing.expectEqual(queue.ptr, server.write_queue_storage.ptr);
    try std.testing.expectEqual(queue.len, server.write_queue_storage.len);
    // Covers the supplied Zig slab allocator, not TLS or Io backend heaps.
    try std.testing.expectEqual(@as(usize, 1), allocations.allocations);
    try std.testing.expectEqual(@as(usize, 0), allocations.resize_index);
    try std.testing.expect(!allocations.has_induced_failure);
}

fn connect_file_client(port: u16, encrypted: bool) !FileClient {
    var address = try net.IpAddress.parse("127.0.0.1", port);
    var client = FileClient{ .stream = try address.connect(std.testing.io, .{ .mode = .stream }) };
    errdefer close_file_client(&client);
    try support.tcp.set_receive_timeout(client.stream.socket.handle, 5_000);
    if (!encrypted) return client;
    client.context = try tls_helpers.create_socket_client_context();
    client.ssl = c.SSL_new(client.context.?) orelse return error.FileClientSslFailed;
    client.bio = try tls_helpers.attach_client_bio(client.ssl.?);
    c.SSL_set_connect_state(client.ssl.?);
    if (c.SSL_set_alpn_protos(client.ssl.?, "\x08http/1.1", 9) != 0) return error.FileClientAlpnFailed;
    try tls_helpers.drive_client_handshake(std.testing.io, client.stream.socket.handle, client.ssl.?, client.bio.?);
    return client;
}

fn close_file_client(client: *FileClient) void {
    if (client.ssl) |ssl| c.SSL_free(ssl);
    if (client.bio) |bio| _ = c.BIO_free(bio);
    if (client.context) |context| c.SSL_CTX_free(context);
    client.stream.close(std.testing.io);
}

fn send_file_request(client: *FileClient, bytes: []const u8) !void {
    if (client.ssl) |ssl| {
        return tls_helpers.ssl_write_all(std.testing.io, client.stream.socket.handle, ssl, client.bio.?, bytes);
    }
    return tls_helpers.write_socket_request(std.testing.io, client.stream.socket.handle, bytes);
}

fn expect_file_bytes(client: *FileClient, head: []const u8, body: []const u8) !void {
    var output: [file_size + 512]u8 = undefined;
    const expected = head.len + body.len;
    if (expected > output.len) return error.FileCaptureOverflow;
    var length: usize = 0;
    var rounds: usize = 0;
    while (length < expected and rounds < 128) : (rounds += 1) {
        const count = try read_file_client(client, output[length..expected]);
        if (count == 0) return error.FileResponseTruncated;
        length += count;
    }
    try std.testing.expectEqual(expected, length);
    try std.testing.expectEqualStrings(head, output[0..head.len]);
    try std.testing.expectEqualSlices(u8, body, output[head.len..length]);
}

fn read_file_client(client: *FileClient, output: []u8) !usize {
    const ssl = client.ssl orelse return tls_helpers.read_pattern_socket(client.stream.socket.handle, output);
    var rounds: usize = 0;
    while (rounds < 128) : (rounds += 1) {
        const count = c.SSL_read(ssl, output.ptr, @intCast(@min(output.len, 16 * 1024)));
        if (count > 0) return @intCast(count);
        const result = c.SSL_get_error(ssl, count);
        if (result != c.SSL_ERROR_WANT_READ and result != c.SSL_ERROR_WANT_WRITE) return error.FileResponseTlsFailed;
        try tls_helpers.flush_cluster_bio(std.testing.io, client.stream.socket.handle, client.bio.?);
        if (result == c.SSL_ERROR_WANT_WRITE) continue;
        var input: [8192]u8 = undefined;
        const received = try tls_helpers.read_pattern_socket(client.stream.socket.handle, &input);
        if (received == 0) return error.FileResponseTruncated;
        const written = c.BIO_write(client.bio.?, &input, @intCast(received));
        if (written != received) return error.FileClientBioFull;
    }
    return error.FileResponseRetryLimit;
}
