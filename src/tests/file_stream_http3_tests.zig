const std = @import("std");
const c = @import("c");
const support = @import("test_support");
const response = support.http_response;
const stream = support.quic_stream;

/// Counts file effects without replacing the real positional read backend.
const FileEffects = struct {
    base: std.Io,
    vtable: std.Io.VTable,
    reads: usize = 0,
    closes: usize = 0,
    largest_read: usize = 0,
    short_limit: usize = std.math.maxInt(usize),
    fail_read: bool = false,

    fn init() FileEffects {
        var table = std.testing.io.vtable.*;
        table.fileReadPositional = read;
        table.fileClose = close;
        return .{ .base = std.testing.io, .vtable = table };
    }

    fn io(state: *FileEffects) std.Io {
        return .{ .userdata = state, .vtable = &state.vtable };
    }

    fn read(context: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const state: *FileEffects = @ptrCast(@alignCast(context.?));
        state.reads += 1;
        if (state.fail_read) return error.InputOutput;
        std.debug.assert(buffers.len == 1);
        state.largest_read = @max(state.largest_read, buffers[0].len);
        const window = buffers[0][0..@min(buffers[0].len, state.short_limit)];
        return state.base.vtable.fileReadPositional(state.base.userdata, file, &.{window}, offset);
    }

    fn close(context: ?*anyopaque, files: []const std.Io.File) void {
        const state: *FileEffects = @ptrCast(@alignCast(context.?));
        state.closes += files.len;
        state.base.vtable.fileClose(state.base.userdata, files);
    }
};

/// Captures exact bytes and headers while enforcing a per-event write budget.
const Wire = struct {
    expected: []const u8 = "",
    bytes: usize = 0,
    budget: usize = 0,
    short_writes: usize = 0,
    blocked_writes: usize = 0,
    heads: usize = 0,
    content_length: ?u64 = null,
    status: u16 = 0,
    fins: usize = 0,
    closes: usize = 0,
    releases: usize = 0,
    wanted: c_int = 0,
    valid: bool = true,
    fail_headers: bool = false,
    fail_write: bool = false,

    fn from(raw: ?*c.lsquic_stream) *Wire {
        return @ptrCast(@alignCast(raw.?));
    }

    fn wantread(_: ?*c.lsquic_stream, _: c_int) callconv(.c) c_int {
        return 0;
    }

    fn read(_: ?*c.lsquic_stream, _: ?*anyopaque, _: usize) callconv(.c) isize {
        return 0;
    }

    fn wantwrite(raw: ?*c.lsquic_stream, want: c_int) callconv(.c) c_int {
        from(raw).wanted = want;
        return 0;
    }

    fn write(raw: ?*c.lsquic_stream, buffer: ?*const anyopaque, length: usize) callconv(.c) isize {
        const wire = from(raw);
        if (wire.fail_write) return -1;
        const count = @min(length, @min(wire.budget, 113));
        if (count == 0) {
            wire.blocked_writes += 1;
            return 0;
        }
        if (count < length) wire.short_writes += 1;
        const bytes: [*]const u8 = @ptrCast(buffer.?);
        if (wire.fins != 0 or count > wire.expected.len - wire.bytes) {
            wire.valid = false;
            return -1;
        }
        if (!std.mem.eql(u8, bytes[0..count], wire.expected[wire.bytes..][0..count])) wire.valid = false;
        wire.bytes += count;
        wire.budget -= count;
        return @intCast(count);
    }

    fn send_headers(raw: ?*c.lsquic_stream, fields: [*c]const c.lsquic_http_headers_t, _: c_int) callconv(.c) c_int {
        const wire = from(raw);
        if (wire.fail_headers) return -1;
        wire.heads += 1;
        const field_array: [*]const c.struct_uz_lsxpack_header = @ptrCast(@alignCast(fields.*.headers orelse return -1));
        for (field_array[0..@intCast(fields.*.count)]) |field| {
            const name = field.buf[@intCast(field.name_offset)..][0..field.name_len];
            const value = field.buf[@intCast(field.val_offset)..][0..field.val_len];
            if (std.mem.eql(u8, name, "content-length")) {
                if (wire.content_length != null) wire.valid = false;
                wire.content_length = std.fmt.parseInt(u64, value, 10) catch {
                    wire.valid = false;
                    return -1;
                };
            }
            if (std.mem.eql(u8, name, ":status")) wire.status = std.fmt.parseInt(u16, value, 10) catch 0;
            if (std.mem.eql(u8, name, "transfer-encoding")) wire.valid = false;
        }
        return 0;
    }

    fn shutdown(raw: ?*c.lsquic_stream, how: c_int) callconv(.c) c_int {
        const wire = from(raw);
        if (how != 1 and how != 2) return 0;
        if (wire.bytes != wire.expected.len) wire.valid = false;
        wire.fins += 1;
        return 0;
    }

    fn close(raw: ?*c.lsquic_stream) callconv(.c) c_int {
        from(raw).closes += 1;
        return 0;
    }

    const table: stream.StreamIo = .{
        .wantread = wantread,
        .read = read,
        .wantwrite = wantwrite,
        .write = write,
        .send_headers = send_headers,
        .shutdown = shutdown,
        .close = close,
    };
};

const TestStream = stream.stream_with(Wire.table, .{ .response_header_count = 2 });

fn release(context: *anyopaque, _: *TestStream) void {
    const wire: *Wire = @ptrCast(@alignCast(context));
    wire.releases += 1;
}

fn init_stream(wire: *Wire, body: []u8, headers: []u8) TestStream {
    return .{
        .owner = wire,
        .release_fn = release,
        .stream = @ptrCast(wire),
        .response_body_storage = body,
        .response_header_storage = headers,
    };
}

fn create_file(dir: std.Io.Dir, bytes: []const u8) !std.Io.File {
    const file = try dir.createFile(std.testing.io, "asset", .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, bytes, 0);
    return file;
}

fn drain(quic: *TestStream, wire: *Wire, scratch: []u8) !void {
    var rounds: usize = 0;
    while (quic.response_phase != .done and rounds < 2048) : (rounds += 1) {
        @memset(scratch, 0xa5);
        wire.budget = 151;
        quic.on_write();
        try std.testing.expect(wire.valid);
    }
    try std.testing.expect(rounds < 2048);
    try std.testing.expectEqual(wire.expected.len, wire.bytes);
    try std.testing.expectEqual(@as(usize, 1), wire.fins);
    try std.testing.expectEqual(@as(c_int, 0), wire.wanted);
}

test "file stream HTTP/3: known length survives short reads and partial drains" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [64 * 1024 + 41]u8 = undefined;
    for (&bytes, 0..) |*byte, offset| byte.* = @truncate(offset ^ (offset >> 8) ^ (offset >> 16));
    const file = try create_file(tmp.dir, &bytes);
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    var effects = FileEffects.init();
    effects.short_limit = 73;
    var wire = Wire{ .expected = bytes[9 .. bytes.len - 11] };
    var body: [16 * 1024]u8 = undefined;
    var headers: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var quic = init_stream(&wire, &body, &headers);
    defer quic.on_close();
    var output = response.Response{ .target = .{ .http3 = quic.target() } };
    try output.stream_file("206 Partial Content", "X-File: yes\r\n", .{
        .io = effects.io(),
        .file = file,
        .buffer = &scratch,
        .offset = 9,
        .length = wire.expected.len,
    });
    caller_owns = false;
    try std.testing.expect(output.is_complete());
    try std.testing.expectError(error.ResponseNotStreaming, output.write_chunk("extra"));
    try std.testing.expectError(error.ResponseNotStreaming, output.end_chunks());
    try std.testing.expect(quic.stream_producer != null);
    try std.testing.expectEqual(@as(c_int, 1), wire.wanted);
    const queued_reads = effects.reads;
    quic.on_write();
    try std.testing.expectEqual(queued_reads, effects.reads);
    try std.testing.expectEqual(@as(c_int, 1), wire.wanted);
    try drain(&quic, &wire, &scratch);
    try std.testing.expectEqual(@as(?u64, wire.expected.len), wire.content_length);
    try std.testing.expectEqual(@as(u16, 206), wire.status);
    try std.testing.expectEqual(@as(usize, 1), wire.heads);
    try std.testing.expect(wire.short_writes > 0);
    try std.testing.expect(wire.blocked_writes > 0);
    try std.testing.expect(effects.reads > 1);
    try std.testing.expectEqual(scratch.len, effects.largest_read);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expectEqual(body[0..].ptr, quic.response_body_storage.ptr);
    try std.testing.expectEqual(body.len, quic.response_body_storage.len);
    const reads = effects.reads;
    quic.on_write();
    try std.testing.expectEqual(reads, effects.reads);
    try std.testing.expectEqual(@as(usize, 1), wire.fins);
}

test "file stream HTTP/3: interleaved streams copy a shared read window" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "interleaved-file-range" ** 1500;
    const first_file = try create_file(tmp.dir, bytes);
    var first_owned = true;
    defer if (first_owned) first_file.close(std.testing.io);
    const second_file = try tmp.dir.openFile(std.testing.io, "asset", .{});
    var second_owned = true;
    defer if (second_owned) second_file.close(std.testing.io);
    var first_effects = FileEffects.init();
    var second_effects = FileEffects.init();
    var first_wire = Wire{ .expected = bytes[3 .. bytes.len - 7] };
    var second_wire = Wire{ .expected = bytes[11 .. bytes.len - 19] };
    var first_body: [1024]u8 = undefined;
    var second_body: [1024]u8 = undefined;
    var first_headers: [128]u8 = undefined;
    var second_headers: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var first = init_stream(&first_wire, &first_body, &first_headers);
    defer first.on_close();
    var second = init_stream(&second_wire, &second_body, &second_headers);
    defer second.on_close();
    var first_output = response.Response{ .target = .{ .http3 = first.target() } };
    try first_output.stream_file("200 OK", "", .{
        .io = first_effects.io(),
        .file = first_file,
        .buffer = &scratch,
        .offset = 3,
        .length = first_wire.expected.len,
    });
    first_owned = false;
    var second_output = response.Response{ .target = .{ .http3 = second.target() } };
    try second_output.stream_file("200 OK", "", .{
        .io = second_effects.io(),
        .file = second_file,
        .buffer = &scratch,
        .offset = 11,
        .length = second_wire.expected.len,
    });
    second_owned = false;
    var rounds: usize = 0;
    while ((first.response_phase != .done or second.response_phase != .done) and rounds < 1024) : (rounds += 1) {
        @memset(&scratch, 0xcc);
        first_wire.budget = 151;
        first.on_write();
        @memset(&scratch, 0xa5);
        second_wire.budget = 151;
        second.on_write();
        try std.testing.expect(first_wire.valid and second_wire.valid);
    }
    try std.testing.expect(rounds < 1024);
    try std.testing.expectEqual(first_wire.expected.len, first_wire.bytes);
    try std.testing.expectEqual(second_wire.expected.len, second_wire.bytes);
    try std.testing.expectEqual(@as(?u64, first_wire.expected.len), first_wire.content_length);
    try std.testing.expectEqual(@as(?u64, second_wire.expected.len), second_wire.content_length);
    try std.testing.expectEqual(@as(usize, 1), first_effects.closes);
    try std.testing.expectEqual(@as(usize, 1), second_effects.closes);
    try std.testing.expectEqual(@as(usize, 1), first_wire.fins);
    try std.testing.expectEqual(@as(usize, 1), second_wire.fins);
    try std.testing.expect(first_wire.short_writes > 0 and second_wire.short_writes > 0);
}

test "file stream HTTP/3: HEAD and empty files need no body storage or read" {
    for ([_]bool{ false, true }) |head| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "representation");
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        var effects = FileEffects.init();
        var wire = Wire{};
        var headers: [128]u8 = undefined;
        var scratch: [1]u8 = undefined;
        var quic = init_stream(&wire, &.{}, &headers);
        defer quic.on_close();
        quic.suppress_body = head;
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        const length: u64 = if (head) std.math.maxInt(u64) else 0;
        try output.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = length,
        });
        caller_owns = false;
        try std.testing.expect(output.is_complete());
        try drain(&quic, &wire, &scratch);
        try std.testing.expectEqual(@as(?u64, length), wire.content_length);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
    }
}

/// One refused transfer must preserve both the descriptor and response state.
const Refusal = struct {
    status: []const u8 = "200 OK",
    headers: []const u8 = "",
    error_value: anyerror,
    offset: u64 = 0,
    length: u64 = 1,
    body_capacity: usize = 16,
    header_capacity: usize = 128,
    scratch_capacity: usize = 16,
    connect: bool = false,
};

test "file stream HTTP/3: framing source capacity and head refusals retain the caller file" {
    const cases = [_]Refusal{
        .{ .status = "204 No Content", .error_value = error.BodyNotAllowed },
        .{ .status = "204 No Content", .length = 0, .error_value = error.BodyNotAllowed },
        .{ .status = "205 Reset Content", .error_value = error.BodyNotAllowed },
        .{ .status = "304 Not Modified", .error_value = error.BodyNotAllowed },
        .{ .status = "205 Reset Content", .length = 0, .error_value = error.BodyNotAllowed },
        .{ .status = "304 Not Modified", .length = 0, .error_value = error.BodyNotAllowed },
        .{ .connect = true, .error_value = error.BodyNotAllowed },
        .{ .body_capacity = 0, .error_value = error.WouldBlock },
        .{ .scratch_capacity = 0, .error_value = error.InvalidFileSource },
        .{ .offset = std.math.maxInt(u64), .error_value = error.InvalidFileSource },
        .{ .headers = "Content-Length: 1\r\n", .error_value = error.InvalidHeaders },
        .{ .headers = "Connection: close\r\n", .error_value = error.InvalidHeaders },
        .{ .headers = "X-A: 1\r\nX-B: 2\r\n", .error_value = error.BufferOverflow },
        .{ .header_capacity = 13, .error_value = error.BufferOverflow },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "representation");
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        var effects = FileEffects.init();
        var wire = Wire{};
        var body: [16]u8 = undefined;
        var headers: [128]u8 = undefined;
        var scratch: [16]u8 = undefined;
        var quic = init_stream(&wire, body[0..case.body_capacity], headers[0..case.header_capacity]);
        defer quic.on_close();
        var request_headers = stream.HeaderSet{};
        request_headers.request.method = if (case.connect) "CONNECT" else "GET";
        quic.header_set = &request_headers;
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        const result = output.stream_file(case.status, case.headers, .{
            .io = effects.io(),
            .file = file,
            .buffer = scratch[0..case.scratch_capacity],
            .offset = case.offset,
            .length = case.length,
        });
        if (result) |_| {
            caller_owns = false;
            try std.testing.expectError(case.error_value, result);
        } else |err| try std.testing.expectEqual(case.error_value, err);
        try std.testing.expectEqual(@as(usize, 0), effects.closes);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try std.testing.expectEqual(@as(usize, 0), wire.heads);
        try std.testing.expect(quic.stream_producer == null);
        try std.testing.expect(quic.response_phase == .idle);
        try std.testing.expect(!output.is_started());
        var probe: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try file.readPositionalAll(std.testing.io, &probe, 0));
    }
}

const Stop = enum { peer_close, local_abort, header_failure, body_failure, reuse };

test "file stream HTTP/3: reset abort write failures and reuse close the descriptor once" {
    for ([_]Stop{ .peer_close, .local_abort, .header_failure, .body_failure, .reuse }) |stop| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const bytes = "bounded-output" ** 100;
        const file = try create_file(tmp.dir, bytes);
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        var effects = FileEffects.init();
        var wire = Wire{ .expected = bytes };
        var body: [32]u8 = undefined;
        var headers: [128]u8 = undefined;
        var scratch: [16]u8 = undefined;
        var quic = init_stream(&wire, &body, &headers);
        defer quic.on_close();
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        try output.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = bytes.len,
        });
        caller_owns = false;
        try std.testing.expectEqual(@as(usize, 0), effects.closes);
        switch (stop) {
            .peer_close => quic.on_close(),
            .local_abort => quic.target().abort_fn.?(quic.target().context),
            .header_failure => {
                wire.fail_headers = true;
                quic.on_write();
            },
            .body_failure => {
                wire.fail_write = true;
                quic.on_write();
            },
            .reuse => quic.reset(&wire, release, @ptrCast(&wire), undefined, &.{}, &body, &headers, &.{}, &.{}, &.{}, &.{}),
        }
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try std.testing.expect(quic.stream_producer == null);
        try std.testing.expect(quic.stream_producer_context == null);
        const replacement = try tmp.dir.openFile(std.testing.io, "asset", .{});
        defer replacement.close(std.testing.io);
        quic.on_close();
        quic.on_close();
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        var probe: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try replacement.readPositionalAll(std.testing.io, &probe, 0));
    }
}

test "file stream HTTP/3: synchronous EOF and read faults accept ownership then fail normally" {
    for ([_]bool{ false, true }) |read_fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try create_file(tmp.dir, "short");
        var caller_owns = true;
        defer if (caller_owns) file.close(std.testing.io);
        var effects = FileEffects.init();
        effects.fail_read = read_fault;
        var wire = Wire{};
        var body: [32]u8 = undefined;
        var headers: [128]u8 = undefined;
        var scratch: [16]u8 = undefined;
        var quic = init_stream(&wire, &body, &headers);
        defer quic.on_close();
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        try output.stream_file("200 OK", "", .{
            .io = effects.io(),
            .file = file,
            .buffer = &scratch,
            .offset = 0,
            .length = 16,
        });
        caller_owns = false;
        try std.testing.expect(output.is_complete());
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try drain(&quic, &wire, &scratch);
        try std.testing.expectEqual(@as(u16, 500), wire.status);
        try std.testing.expect(wire.content_length == null);
    }
}

test "file stream HTTP/3: truncation after the head fails only its stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "truncate-file-contents" ** 50;
    const file = try create_file(tmp.dir, bytes);
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    var effects = FileEffects.init();
    var wire = Wire{ .expected = bytes };
    var body: [32]u8 = undefined;
    var headers: [128]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var quic = init_stream(&wire, &body, &headers);
    defer quic.on_close();
    var output = response.Response{ .target = .{ .http3 = quic.target() } };
    try output.stream_file("200 OK", "", .{
        .io = effects.io(),
        .file = file,
        .buffer = &scratch,
        .offset = 0,
        .length = bytes.len,
    });
    caller_owns = false;
    const writer = try tmp.dir.openFile(std.testing.io, "asset", .{ .mode = .read_write });
    defer writer.close(std.testing.io);
    try writer.setLength(std.testing.io, 16);
    wire.budget = 151;
    quic.on_write();
    try std.testing.expectEqual(@as(usize, 1), wire.heads);
    try std.testing.expectEqual(@as(usize, 16), wire.bytes);
    try std.testing.expectEqual(@as(usize, 0), wire.fins);
    try std.testing.expectEqual(@as(usize, 1), wire.closes);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(quic.response_phase == .done);
    var sibling_wire = Wire{ .expected = "healthy", .budget = 151 };
    var sibling_body: [32]u8 = undefined;
    var sibling_headers: [128]u8 = undefined;
    var sibling = init_stream(&sibling_wire, &sibling_body, &sibling_headers);
    defer sibling.on_close();
    var sibling_output = response.Response{ .target = .{ .http3 = sibling.target() } };
    try sibling_output.end("200 OK", "healthy");
    sibling.on_write();
    try std.testing.expect(sibling_wire.valid);
    try std.testing.expectEqual(@as(usize, 1), sibling_wire.fins);
    try std.testing.expectEqual(@as(usize, 0), sibling_wire.closes);
}

test "file stream HTTP/3: an occupied stream retains a second caller descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "occupied-stream" ** 20;
    const first_file = try create_file(tmp.dir, bytes);
    var first_owned = true;
    defer if (first_owned) first_file.close(std.testing.io);
    const second_file = try tmp.dir.openFile(std.testing.io, "asset", .{});
    var second_owned = true;
    defer if (second_owned) second_file.close(std.testing.io);
    var first_effects = FileEffects.init();
    var second_effects = FileEffects.init();
    var wire = Wire{ .expected = bytes };
    var body: [32]u8 = undefined;
    var headers: [128]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var quic = init_stream(&wire, &body, &headers);
    defer quic.on_close();
    var first = response.Response{ .target = .{ .http3 = quic.target() } };
    try first.stream_file("200 OK", "", .{
        .io = first_effects.io(),
        .file = first_file,
        .buffer = &scratch,
        .offset = 0,
        .length = bytes.len,
    });
    first_owned = false;
    var second = response.Response{ .target = .{ .http3 = quic.target() } };
    const result = second.stream_file("200 OK", "", .{
        .io = second_effects.io(),
        .file = second_file,
        .buffer = &scratch,
        .offset = 0,
        .length = bytes.len,
    });
    if (result) |_| {
        second_owned = false;
        try std.testing.expectError(error.ResponseAlreadyStarted, result);
    } else |err| try std.testing.expectEqual(error.ResponseAlreadyStarted, err);
    try std.testing.expectEqual(@as(usize, 0), second_effects.reads);
    try std.testing.expectEqual(@as(usize, 0), second_effects.closes);
    try drain(&quic, &wire, &scratch);
    try std.testing.expectEqual(@as(usize, 1), first_effects.closes);
    var probe: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try second_file.readPositionalAll(std.testing.io, &probe, 0));
}
