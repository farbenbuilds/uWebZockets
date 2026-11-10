const std = @import("std");
const c = @import("c");
const xev = @import("xev");
const TestConnection = @import("file_stream_tests.zig").TestConnection;
const tls_helpers = @import("tls_tests.zig");
const net = std.Io.net;
const support = @import("test_support");
const response = support.http_response;
const Request = support.http_request.Request;

/// Forwards every handler I/O operation with the backend's original context.
const FileEffects = struct {
    base: std.Io,
    table: std.Io.VTable,
    opens: usize = 0,
    reads: usize = 0,
    closes: usize = 0,
    largest_read: usize = 0,

    fn init() FileEffects {
        var table = std.testing.io.vtable.*;
        table.dirOpenDir = open_dir;
        table.dirClose = close_dirs;
        table.dirOpenFile = open_file;
        table.fileStat = stat;
        table.fileReadPositional = read;
        table.fileClose = close_files;
        return .{ .base = std.testing.io, .table = table };
    }

    fn io(state: *FileEffects) std.Io {
        return .{ .userdata = state, .vtable = &state.table };
    }

    fn get(context: ?*anyopaque) *FileEffects {
        return @ptrCast(@alignCast(context.?));
    }

    fn open_dir(context: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
        const state = get(context);
        return state.base.vtable.dirOpenDir(state.base.userdata, dir, path, options);
    }

    fn close_dirs(context: ?*anyopaque, dirs: []const std.Io.Dir) void {
        const state = get(context);
        state.base.vtable.dirClose(state.base.userdata, dirs);
    }

    fn open_file(context: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        const state = get(context);
        const file = try state.base.vtable.dirOpenFile(state.base.userdata, dir, path, options);
        state.opens += 1;
        return file;
    }

    fn stat(context: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const state = get(context);
        return state.base.vtable.fileStat(state.base.userdata, file);
    }

    fn read(context: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const state = get(context);
        state.reads += 1;
        for (buffers) |buffer| state.largest_read = @max(state.largest_read, buffer.len);
        return state.base.vtable.fileReadPositional(state.base.userdata, file, buffers, offset);
    }

    fn close_files(context: ?*anyopaque, files: []const std.Io.File) void {
        const state = get(context);
        state.closes += files.len;
        state.base.vtable.fileClose(state.base.userdata, files);
    }
};

fn create_file(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, bytes, 0);
}

fn request_for(method: []const u8, path: []const u8) Request {
    var request = Request{ .method = method };
    request.route_param_names[0] = "path";
    request.route_param_values[0] = path;
    request.route_param_count = 1;
    return request;
}

pub const FileCapture = struct {
    source: ?response.FileSource = null,
    status: [64]u8 = undefined,
    status_len: usize = 0,
    headers: [1024]u8 = undefined,
    headers_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,
    file_calls: usize = 0,
    end_calls: usize = 0,
    failure: ?anyerror = null,

    pub fn target(state: *FileCapture, supported: bool) response.Http3Target {
        return .{ .context = state, .end_fn = end, .begin_fn = begin, .write_fn = write, .finish_fn = finish, .stream_file_fn = if (supported) accept_file else null };
    }

    fn accept_file(context: *anyopaque, status: []const u8, headers: []const u8, source: response.FileSource) anyerror!void {
        const state: *FileCapture = @ptrCast(@alignCast(context));
        state.file_calls += 1;
        if (state.failure) |err| return err;
        try state.capture(status, headers);
        state.source = source;
    }

    fn end(context: *anyopaque, status: []const u8, headers: []const u8, body: []const u8) anyerror!void {
        const state: *FileCapture = @ptrCast(@alignCast(context));
        state.end_calls += 1;
        try state.capture(status, headers);
        if (body.len > state.body.len) return error.CaptureOverflow;
        @memcpy(state.body[0..body.len], body);
        state.body_len = body.len;
    }

    fn capture(state: *FileCapture, status: []const u8, headers: []const u8) !void {
        if (status.len > state.status.len or headers.len > state.headers.len) return error.CaptureOverflow;
        @memcpy(state.status[0..status.len], status);
        @memcpy(state.headers[0..headers.len], headers);
        state.status_len = status.len;
        state.headers_len = headers.len;
    }

    fn begin(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.UnexpectedStreaming;
    }
    fn write(_: *anyopaque, _: []const u8) anyerror!void {
        return error.UnexpectedStreaming;
    }
    fn finish(_: *anyopaque) anyerror!void {
        return error.UnexpectedStreaming;
    }
};

test "static files: init rejects an index that request normalization would rewrite" {
    try std.testing.expectError(
        error.InvalidStaticIndex,
        support.static_files.static_files(8).init(std.testing.io, ".", .{ .index = "/index.html" }),
    );
}

test "static files: oversized framed response hands off selected file and stable scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "static-bounded-source" ** 8;
    try create_file(tmp.dir, "asset.txt", bytes);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
    defer files.deinit();
    var request = request_for("GET", "asset.txt");
    request.header_names[0] = "Range";
    request.header_values[0] = "bytes=7-99";
    request.header_count = 1;
    var capture = FileCapture{};
    defer if (capture.source) |source| source.file.close(source.io);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try files.serve(&request, &output);
    try std.testing.expect(output.is_complete());
    try std.testing.expectEqual(@as(usize, 1), capture.file_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.end_calls);
    const source = capture.source orelse return error.FileNotTransferred;
    try std.testing.expectEqual(@as(u64, 7), source.offset);
    try std.testing.expectEqual(@as(u64, 93), source.length);
    try std.testing.expectEqual(files.file_buffer[0..].ptr, source.buffer.ptr);
    try std.testing.expectEqual(files.file_buffer.len, source.buffer.len);
    try std.testing.expectEqual(@as(usize, 1), effects.opens);
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
    var probe: [93]u8 = undefined;
    try std.testing.expectEqual(probe.len, try source.file.readPositionalAll(std.testing.io, &probe, source.offset));
    try std.testing.expectEqualSlices(u8, bytes[7..100], &probe);
    try std.testing.expectEqualStrings("206 Partial Content", capture.status[0..capture.status_len]);
    try std.testing.expect(std.mem.indexOf(u8, capture.headers[0..capture.headers_len], "Content-Type: text/plain; charset=utf-8\r\n") != null);
    capture.source = null;
    source.file.close(source.io);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
}

/// Captures exact bytes and headers while enforcing a per-event write budget.
pub const Wire = struct {
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

    const table: support.quic_stream.StreamIo = .{
        .wantread = wantread,
        .read = read,
        .wantwrite = wantwrite,
        .write = write,
        .send_headers = send_headers,
        .shutdown = shutdown,
        .close = close,
    };
};

pub const TestStream = support.quic_stream.stream_with(Wire.table, .{ .response_header_count = 10 });

fn release(context: *anyopaque, _: *TestStream) void {
    const wire: *Wire = @ptrCast(@alignCast(context));
    wire.releases += 1;
}

pub fn init_stream(wire: *Wire, body: []u8, headers: []u8) TestStream {
    return .{
        .owner = wire,
        .release_fn = release,
        .stream = @ptrCast(wire),
        .response_body_storage = body,
        .response_header_storage = headers,
    };
}

pub fn drain_stream(quic: *TestStream, wire: *Wire, scratch: []u8) !void {
    for (0..4096) |_| {
        if (quic.response_phase == .done) break;
        @memset(scratch, 0xa5);
        wire.budget = 13;
        quic.on_write();
        try std.testing.expect(wire.valid);
    }
    try std.testing.expectEqual(.done, quic.response_phase);
    try std.testing.expectEqual(wire.expected.len, wire.bytes);
    try std.testing.expectEqual(@as(usize, 1), wire.fins);
}

test "static files: HTTP3 adapter streams exact range larger than route scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "static-source-data-" ** 400;
    try create_file(tmp.dir, "asset.txt", bytes);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(31).init(effects.io(), root, .{ .max_age = 60 });
    defer files.deinit();
    var request = request_for("GET", "asset.txt");
    request.header_names[0] = "Range";
    request.header_values[0] = "bytes=7-6999";
    request.header_count = 1;
    var wire = Wire{ .expected = bytes[7..7000] };
    var body: [17]u8 = undefined;
    var headers: [1024]u8 = undefined;
    var quic = init_stream(&wire, &body, &headers);
    defer quic.on_close();
    var output = response.Response{ .target = .{ .http3 = quic.target() } };
    try files.serve(&request, &output);
    try std.testing.expect(output.is_complete());
    try std.testing.expectEqual(@as(usize, 0), effects.closes);
    try drain_stream(&quic, &wire, &files.file_buffer);
    try std.testing.expectEqual(@as(?u64, 6993), wire.content_length);
    try std.testing.expectEqual(@as(u16, 206), wire.status);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(effects.reads > 1 and effects.largest_read <= files.file_buffer.len);
    try std.testing.expectEqual(body[0..].ptr, quic.response_body_storage.ptr);
    try std.testing.expectEqual(body.len, quic.response_body_storage.len);
}

test "static files: HTTP3 HEAD and empty responses hand off and close without reads" {
    for ([_]bool{ true, false }) |head| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try create_file(tmp.dir, "asset", if (head) "representation" else "");
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var effects = FileEffects.init();
        var files = try support.static_files.static_files(1).init(effects.io(), root, .{});
        defer files.deinit();
        var request = request_for(if (head) "HEAD" else "GET", "asset");
        var wire = Wire{};
        var body: [0]u8 = .{};
        var headers: [1024]u8 = undefined;
        var quic = init_stream(&wire, &body, &headers);
        quic.suppress_body = head;
        defer quic.on_close();
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        try files.serve(&request, &output);
        try std.testing.expect(output.is_complete());
        try drain_stream(&quic, &wire, &files.file_buffer);
        try std.testing.expectEqual(@as(?u64, if (head) 14 else 0), wire.content_length);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
        try std.testing.expectEqual(@as(usize, 1), wire.fins);
    }
}

test "static files: legacy default-null targets keep only their bounded fallback" {
    for ([_]bool{ true, false }) |small| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try create_file(tmp.dir, "asset", if (small) "small" else "too-large-for-handler");
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var effects = FileEffects.init();
        var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
        defer files.deinit();
        var request = request_for("GET", "asset");
        var capture = FileCapture{};
        var output = response.Response{ .target = .{ .http3 = capture.target(false) } };
        if (small) {
            try files.serve(&request, &output);
            try std.testing.expectEqualStrings("small", capture.body[0..capture.body_len]);
            try std.testing.expectEqual(@as(usize, 1), capture.end_calls);
        } else {
            try std.testing.expectError(error.FileTooLarge, files.serve(&request, &output));
            try std.testing.expectEqual(@as(usize, 0), capture.end_calls);
        }
        try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
    }
}

test "static files: framed errors close once and never fall back to a body copy" {
    for ([_]anyerror{ error.WouldBlock, error.OutputFailed }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try create_file(tmp.dir, "asset", "small");
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var effects = FileEffects.init();
        var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
        defer files.deinit();
        var request = request_for("GET", "asset");
        var capture = FileCapture{ .failure = failure };
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try std.testing.expectError(failure, files.serve(&request, &output));
        try std.testing.expectEqual(@as(usize, 1), capture.file_calls);
        try std.testing.expectEqual(@as(usize, 0), capture.end_calls);
        try std.testing.expectEqual(@as(usize, 0), effects.reads);
        try std.testing.expectEqual(@as(usize, 1), effects.closes);
    }
}

fn header_value(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

test "static files: validators IfRange and unsatisfied ranges preserve source metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try create_file(tmp.dir, "asset.txt", "0123456789abcdef");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
    defer files.deinit();
    var original = FileCapture{};
    var request = request_for("GET", "asset.txt");
    var first = response.Response{ .target = .{ .http3 = original.target(true) } };
    try files.serve(&request, &first);
    const source = original.source.?;
    original.source = null;
    source.file.close(source.io);
    const raw = original.headers[0..original.headers_len];
    const etag = header_value(raw, "ETag").?;
    const modified = header_value(raw, "Last-Modified").?;
    for (0..6) |case| {
        var capture = FileCapture{};
        defer if (capture.source) |owned| owned.file.close(owned.io);
        request = request_for("GET", "asset.txt");
        request.header_names[0] = if (case == 0) "If-None-Match" else if (case == 1) "If-Modified-Since" else "Range";
        request.header_values[0] = if (case == 0) etag else if (case == 1) modified else if (case == 5) "bytes=99-" else "bytes=2-5";
        request.header_count = 1;
        if (case >= 2 and case < 5) {
            request.header_names[1] = "If-Range";
            request.header_values[1] = if (case == 2) etag else if (case == 3) modified else "\"mismatch\"";
            request.header_count = 2;
        }
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try files.serve(&request, &output);
        const status = capture.status[0..capture.status_len];
        if (case < 2) {
            try std.testing.expectEqualStrings("304 Not Modified", status);
            try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
            try std.testing.expectEqual(@as(usize, 0), capture.body_len);
            try std.testing.expectEqualStrings(etag, header_value(capture.headers[0..capture.headers_len], "ETag").?);
        } else if (case == 5) {
            try std.testing.expectEqualStrings("416 Range Not Satisfiable", status);
            try std.testing.expectEqualStrings("bytes */16", header_value(capture.headers[0..capture.headers_len], "Content-Range").?);
        } else {
            try std.testing.expectEqualStrings(if (case == 4) "200 OK" else "206 Partial Content", status);
            try std.testing.expectEqual(@as(u64, if (case == 4) 0 else 2), capture.source.?.offset);
            try std.testing.expectEqual(@as(u64, if (case == 4) 16 else 4), capture.source.?.length);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
}

test "static files: interleaved HTTP3 streams share only the handler read window" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = "first-file-" ** 70;
    const second = "second-file-" ** 80;
    try create_file(tmp.dir, "first", first);
    try create_file(tmp.dir, "second", second);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(23).init(effects.io(), root, .{});
    defer files.deinit();
    var a = Wire{ .expected = first };
    var b = Wire{ .expected = second };
    var body_a: [17]u8 = undefined;
    var body_b: [17]u8 = undefined;
    var head_a: [1024]u8 = undefined;
    var head_b: [1024]u8 = undefined;
    var quic_a = init_stream(&a, &body_a, &head_a);
    var quic_b = init_stream(&b, &body_b, &head_b);
    defer quic_a.on_close();
    defer quic_b.on_close();
    var request = request_for("GET", "first");
    var output_a = response.Response{ .target = .{ .http3 = quic_a.target() } };
    try files.serve(&request, &output_a);
    request = request_for("GET", "second");
    var output_b = response.Response{ .target = .{ .http3 = quic_b.target() } };
    try files.serve(&request, &output_b);
    for (0..512) |_| {
        if (quic_a.response_phase == .done and quic_b.response_phase == .done) break;
        @memset(&files.file_buffer, 0xa5);
        a.budget = 13;
        quic_a.on_write();
        @memset(&files.file_buffer, 0x5a);
        b.budget = 13;
        quic_b.on_write();
        try std.testing.expect(a.valid and b.valid);
    }
    try std.testing.expectEqual(first.len, a.bytes);
    try std.testing.expectEqual(second.len, b.bytes);
    try std.testing.expectEqual(@as(usize, 1), a.fins);
    try std.testing.expectEqual(@as(usize, 1), b.fins);
    try std.testing.expectEqual(@as(usize, 2), effects.closes);
}

const TlsClient = struct {
    stream: net.Stream,
    context: *c.SSL_CTX,
    ssl: *c.SSL,
    bio: *c.BIO,

    fn connect(port: u16, h2: bool) !TlsClient {
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
        if (c.SSL_set_alpn_protos(ssl, if (h2) "\x02h2" else "\x08http/1.1", if (h2) 3 else 9) != 0) return error.ClientAlpnFailed;
        try tls_helpers.drive_client_handshake(std.testing.io, stream.socket.handle, ssl, bio);
        try std.testing.expectEqual(if (h2) support.tls.ApplicationProtocol.http2 else support.tls.ApplicationProtocol.http1, support.tls.negotiated_protocol(ssl));
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

const logical_size = 100 * 1024 * 1024;
const prefix = "STATIC-BEGIN";
const suffix = "STATIC-END";
const StaticApp = support.app.app(1);

const StaticRunner = struct {
    server: *StaticApp,
    failure: ?anyerror = null,

    fn run(state: *StaticRunner) void {
        state.server.run() catch |err| {
            state.failure = err;
        };
    }
};

const StaticHealth = struct {
    effects: *FileEffects,
    unread: bool = false,
    drained: bool = false,
    failure: ?anyerror = null,

    fn handle(context: *anyopaque, request: *Request, output: *response.Response) void {
        const state: *StaticHealth = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, request.path, "/health-first")) state.unread = state.effects.reads == 0;
        if (std.mem.eql(u8, request.path, "/health-final")) state.drained = state.effects.opens == state.effects.closes;
        output.end("200 OK", "ok") catch |err| {
            state.failure = err;
        };
    }
};

const Expected = struct {
    status: u16 = 200,
    declared: ?u64,
    body_length: u64,
    source_offset: u64 = 0,
    literal: ?[]const u8 = null,
};

fn verify_bytes(bytes: []const u8, offset: u64, expected: Expected) !void {
    if (bytes.len > expected.body_length - offset) return error.StaticBodyOverflow;
    if (expected.literal) |literal| return std.testing.expectEqualSlices(u8, literal[@intCast(offset)..][0..bytes.len], bytes);
    var position: usize = @intCast(expected.source_offset + offset);
    var cursor: usize = 0;
    if (position < prefix.len) {
        const count = @min(bytes.len, prefix.len - position);
        try std.testing.expectEqualSlices(u8, prefix[position..][0..count], bytes[0..count]);
        cursor += count;
        position += count;
    }
    const zero_end = logical_size - suffix.len;
    if (position < zero_end) {
        const count = @min(bytes.len - cursor, zero_end - position);
        try std.testing.expect(std.mem.allEqual(u8, bytes[cursor..][0..count], 0));
        cursor += count;
        position += count;
    }
    if (cursor < bytes.len) try std.testing.expectEqualSlices(u8, suffix[position - zero_end ..][0 .. bytes.len - cursor], bytes[cursor..]);
}

fn expect_http1(client: *TlsClient, expected: Expected, headers: []u8) ![]const u8 {
    var buffer: [8192]u8 = undefined;
    var length: usize = 0;
    var boundary: usize = 0;
    while (boundary == 0) {
        if (length >= 2048) return error.StaticHeadTooLarge;
        length += try client.read(buffer[length..]);
        if (std.mem.indexOf(u8, buffer[0..length], "\r\n\r\n")) |end| boundary = end + 4;
    }
    if (boundary > headers.len) return error.StaticHeadTooLarge;
    @memcpy(headers[0..boundary], buffer[0..boundary]);
    const head = headers[0..boundary];
    try std.testing.expectEqual(expected.status, try std.fmt.parseUnsigned(u16, head[9..12], 10));
    if (expected.declared) |declared| {
        try std.testing.expectEqual(declared, try std.fmt.parseUnsigned(u64, header_value(head, "Content-Length").?, 10));
    } else try std.testing.expect(header_value(head, "Content-Length") == null);
    try std.testing.expect(header_value(head, "Transfer-Encoding") == null);
    var offset: u64 = length - boundary;
    try verify_bytes(buffer[boundary..length], 0, expected);
    while (offset < expected.body_length) {
        const count = try client.read(buffer[0..@intCast(@min(buffer.len, expected.body_length - offset))]);
        try verify_bytes(buffer[0..count], offset, expected);
        offset += count;
    }
    try std.testing.expectEqual(expected.body_length, offset);
    return head;
}

fn tls_read_exact(client: *TlsClient, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) offset += try client.read(bytes[offset..]);
}

fn expect_http2(client: *TlsClient, id: u32, expected: Expected) !void {
    var bytes: [8192]u8 = undefined;
    var body_offset: u64 = 0;
    var heads: usize = 0;
    for (0..32768) |_| {
        var raw: [9]u8 = undefined;
        try tls_read_exact(client, &raw);
        const header = try support.http2.FrameHeader.parse(&raw);
        var remaining: usize = header.payload_length;
        if (header.stream_id == id and header.frame_type == 1) {
            if (remaining > 2048) return error.StaticHeadTooLarge;
            try tls_read_exact(client, bytes[0..remaining]);
            try verify_h2_headers(bytes[0..remaining], expected);
            heads += 1;
            remaining = 0;
        }
        while (remaining != 0) {
            const size = @min(remaining, bytes.len);
            try tls_read_exact(client, bytes[0..size]);
            if (header.stream_id == id and header.frame_type == 0) {
                try verify_bytes(bytes[0..size], body_offset, expected);
                body_offset += size;
            }
            remaining -= size;
        }
        if (header.stream_id != id) continue;
        try std.testing.expect(header.frame_type != 3);
        if ((header.frame_type == 0 or header.frame_type == 1) and header.flags & 1 != 0) {
            try std.testing.expectEqual(@as(usize, 1), heads);
            try std.testing.expectEqual(expected.body_length, body_offset);
            return;
        }
    }
    return error.StaticFrameLimit;
}

fn verify_h2_headers(block: []const u8, expected: Expected) !void {
    const hpack = support.http2_hpack;
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic, 0);
    var decoder = hpack.Decoder.init(&table, 2048);
    var fields: [16]hpack.Header = undefined;
    var storage: [2048]u8 = undefined;
    const headers = try decoder.decode_fields(block, &fields, &storage);
    var length: ?u64 = null;
    var status: u16 = 0;
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, ":status")) status = try std.fmt.parseUnsigned(u16, header.value, 10);
        if (std.mem.eql(u8, header.name, "content-length")) {
            try std.testing.expect(length == null);
            length = try std.fmt.parseUnsigned(u64, header.value, 10);
        }
        try std.testing.expect(!std.mem.eql(u8, header.name, "transfer-encoding"));
    }
    try std.testing.expectEqual(expected.status, status);
    try std.testing.expectEqual(expected.declared, length);
}

fn append_frame(bytes: []u8, length: *usize, kind: support.http2.FrameType, flags: u8, id: u32, payload: []const u8) !void {
    if (9 + payload.len > bytes.len - length.*) return error.StaticRequestOverflow;
    var raw: [9]u8 = undefined;
    try (support.http2.FrameHeader{ .payload_length = @intCast(payload.len), .frame_type = @intFromEnum(kind), .flags = flags, .stream_id = id }).encode(&raw);
    @memcpy(bytes[length.*..][0..9], &raw);
    @memcpy(bytes[length.* + 9 ..][0..payload.len], payload);
    length.* += 9 + payload.len;
}

fn send_h2(client: *TlsClient, id: u32, path: []const u8, head: bool) !void {
    var block: [128]u8 = undefined;
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
    var frame: [256]u8 = undefined;
    var length: usize = 0;
    try append_frame(&frame, &length, .headers, 0x5, id, block[0..size]);
    try client.send(frame[0..length]);
}

test "static files: real TLS downloads sparse logical 100 MiB through fixed storage" {
    try expect_real_static(false);
}

test "static files: real HTTP2 TLS downloads sparse logical 100 MiB through fixed storage" {
    try expect_real_static(true);
}

fn expect_real_static(h2: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(std.testing.io, "asset.bin", .{});
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, logical_size);
        try file.writePositionalAll(std.testing.io, prefix, 0);
        try file.writePositionalAll(std.testing.io, suffix, logical_size - suffix.len);
    }
    try create_file(tmp.dir, "empty.txt", "");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var health = StaticHealth{ .effects = &effects };
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var server = try StaticApp.init_configured(std.testing.io, allocations.allocator(), .{ .max_connections = 1 });
    defer server.deinit();
    server.tls_ctx = try support.tls.TlsContext.init_ephemeral(.{});
    _ = try server.static("/static", root, .{});
    _ = try server.get_context("/health-first", &health, StaticHealth.handle);
    _ = try server.get_context("/health-final", &health, StaticHealth.handle);
    const handler = server.static_handlers[0].?;
    handler.io = effects.io();
    const scratch = handler.file_buffer[0..];
    const queue = server.write_queue_storage;
    try server.listen("127.0.0.1", 0);
    // This counter covers the supplied allocator. App.static's stable handler
    // and TLS C heaps are separate startup allocations, outside that counter.
    const baseline = allocations.alloc_index;
    const resize_baseline = allocations.resize_index;
    allocations.fail_index = baseline;
    allocations.resize_fail_index = resize_baseline;
    var runner = StaticRunner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, StaticRunner.run, .{&runner});
    var joined = false;
    defer {
        server.request_shutdown();
        if (!joined) thread.join();
    }
    var client = try TlsClient.connect(try support.tcp.listener_port(&server.listeners[0]), h2);
    defer client.close();
    if (h2) try download_h2(&client) else try download_h1(&client);
    server.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null and health.failure == null);
    try std.testing.expect(health.unread and health.drained);
    try std.testing.expectEqual(effects.opens, effects.closes);
    try std.testing.expect(effects.reads > 1 and effects.largest_read <= 16 * 1024);
    try std.testing.expectEqual(@as(usize, 64 * 1024), queue.len);
    try std.testing.expectEqual(queue.ptr, server.write_queue_storage.ptr);
    try std.testing.expectEqual(queue.len, server.write_queue_storage.len);
    try std.testing.expectEqual(scratch.ptr, handler.file_buffer[0..].ptr);
    try std.testing.expectEqual(scratch.len, handler.file_buffer.len);
    try std.testing.expectEqual(baseline, allocations.alloc_index);
    try std.testing.expectEqual(resize_baseline, allocations.resize_index);
    try std.testing.expect(!allocations.has_induced_failure);
}

fn download_h1(client: *TlsClient) !void {
    var head: [2048]u8 = undefined;
    try client.send("HEAD /static/asset.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const raw = try expect_http1(client, .{ .declared = logical_size, .body_length = 0 }, &head);
    const etag = header_value(raw, "ETag").?;
    var tag: [80]u8 = undefined;
    @memcpy(tag[0..etag.len], etag);
    const tag_len = etag.len;
    try std.testing.expectEqualStrings("application/octet-stream", header_value(raw, "Content-Type").?);
    try client.send("GET /static/empty.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    _ = try expect_http1(client, .{ .declared = 0, .body_length = 0 }, &head);
    var request: [256]u8 = undefined;
    var bytes = try std.fmt.bufPrint(&request, "GET /static/asset.bin HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: {s}\r\n\r\n", .{tag[0..tag_len]});
    try client.send(bytes);
    _ = try expect_http1(client, .{ .status = 304, .declared = null, .body_length = 0 }, &head);
    try client.send("GET /static/asset.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999999999-\r\n\r\n");
    _ = try expect_http1(client, .{ .status = 416, .declared = 0, .body_length = 0 }, &head);
    try client.send("GET /health-first HTTP/1.1\r\nHost: localhost\r\n\r\n");
    _ = try expect_http1(client, .{ .declared = 2, .body_length = 2, .literal = "ok" }, &head);
    bytes = try std.fmt.bufPrint(&request, "GET /static/asset.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-31\r\nIf-Range: {s}\r\n\r\n", .{tag[0..tag_len]});
    try client.send(bytes);
    _ = try expect_http1(client, .{ .status = 206, .declared = 32, .body_length = 32 }, &head);
    try client.send("GET /static/asset.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");
    _ = try expect_http1(client, .{ .declared = logical_size, .body_length = logical_size }, &head);
    try client.send("HEAD /static/asset.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=5-12\r\nIf-Range: \"mismatch\"\r\n\r\n");
    _ = try expect_http1(client, .{ .declared = logical_size, .body_length = 0 }, &head);
    try client.send("GET /health-final HTTP/1.1\r\nHost: localhost\r\n\r\n");
    _ = try expect_http1(client, .{ .declared = 2, .body_length = 2, .literal = "ok" }, &head);
}

fn download_h2(client: *TlsClient) !void {
    var request: [128]u8 = undefined;
    @memcpy(request[0..support.http2.client_preface.len], support.http2.client_preface);
    var length: usize = support.http2.client_preface.len;
    try append_frame(&request, &length, .settings, 0, 0, "\x00\x04\x0c\x80\x00\x00");
    try append_frame(&request, &length, .window_update, 0, 0, "\x0c\x80\x00\x00");
    try client.send(request[0..length]);
    try send_h2(client, 1, "/static/asset.bin", true);
    try expect_http2(client, 1, .{ .declared = logical_size, .body_length = 0 });
    try send_h2(client, 3, "/static/empty.txt", false);
    try expect_http2(client, 3, .{ .declared = 0, .body_length = 0 });
    try send_h2(client, 5, "/health-first", false);
    try expect_http2(client, 5, .{ .declared = 2, .body_length = 2, .literal = "ok" });
    try send_h2(client, 7, "/static/asset.bin", false);
    try expect_http2(client, 7, .{ .declared = logical_size, .body_length = logical_size });
    try send_h2(client, 9, "/health-final", false);
    try expect_http2(client, 9, .{ .declared = 2, .body_length = 2, .literal = "ok" });
}

test "static files: kernel-path backpressure never reads a buffered fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try create_file(tmp.dir, "asset", "small");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
    defer files.deinit();
    var ring: [512]u8 = @splat(0);
    var fixture = TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    const conn = &fixture.connection;
    const padding: [512]u8 = @splat(0);
    try conn.write_data(&padding);
    conn.arm_write();
    try xev.submit(conn.loop);
    try std.testing.expect(conn.is_writing);
    var request = request_for("GET", "asset");
    conn.req = request;
    var output = response.Response{ .target = .{ .tcp = conn } };
    try std.testing.expectError(error.WouldBlock, files.serve(&request, &output));
    try std.testing.expect(!output.is_started());
    try std.testing.expectEqual(@as(usize, 0), effects.reads);
    try std.testing.expectEqual(@as(usize, 1), effects.opens);
    try std.testing.expectEqual(@as(usize, 1), effects.closes);
    try std.testing.expect(conn.file_body == null and conn.buffered_file.file == null);
}

test "static files: invalid and encoded parent paths remain confined" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var effects = FileEffects.init();
    var files = try support.static_files.static_files(8).init(effects.io(), root, .{});
    defer files.deinit();
    for ([_][]const u8{ "../outside", "%2e%2e/outside", "nested/../outside", "bad%00path", "bad%5cpath" }) |path| {
        var request = request_for("GET", path);
        var capture = FileCapture{};
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try std.testing.expectError(error.InvalidStaticPath, files.serve(&request, &output));
        try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
    }
    try std.testing.expectEqual(@as(usize, 0), effects.opens);
}

/// Route-level sink for the live HTTP/2 upload proof.
const UploadSink = struct {
    bytes: u64 = 0,
    begins: usize = 0,
    ends: usize = 0,
    cancels: usize = 0,
    failure: ?anyerror = null,

    fn route(self: *UploadSink) support.request_body.BodyRoute {
        return .{
            .sink = .{
                .context = self,
                .begin = begin,
                .chunk = chunk,
                .end = end,
                .cancel = cancel,
            },
            .limits = .{ .max_body_bytes = 128 * 1024 * 1024, .max_active = 1 },
            .middleware_policy = .headers_only,
        };
    }

    fn begin(
        context: *anyopaque,
        request: *const support.streaming_request.StreamingRequest,
        _: support.request_body.BodyControl,
    ) !support.request_body.BodyBinding {
        const self: *UploadSink = @ptrCast(@alignCast(context));
        self.begins += 1;
        self.bytes = 0;
        if (!std.mem.eql(u8, request.method, "POST")) return error.UnexpectedMethod;
        if (!std.mem.eql(u8, request.path, "/upload")) return error.UnexpectedPath;
        return .{ .context = self, .readiness = .ready };
    }

    fn chunk(context: *anyopaque, input: []const u8) !support.request_body.BodyProgress {
        const self: *UploadSink = @ptrCast(@alignCast(context));
        self.bytes += input.len;
        return .{ .consumed = input.len, .readiness = .ready };
    }

    fn end(
        context: *anyopaque,
        _: *const support.streaming_request.StreamingRequest,
        output: *response.Response,
    ) !void {
        const self: *UploadSink = @ptrCast(@alignCast(context));
        self.ends += 1;
        var buffer: [32]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer, "{d}", .{self.bytes});
        try output.end("200 OK", body);
    }

    fn cancel(context: *anyopaque, reason: support.request_body.BodyCancelReason) void {
        const self: *UploadSink = @ptrCast(@alignCast(context));
        self.cancels += 1;
        if (reason == .sink_failure) self.failure = error.UnexpectedSinkFailure;
    }
};

fn append_h2_literal(
    buffer: []u8,
    offset: usize,
    name: []const u8,
    value: []const u8,
) !usize {
    const required = 2 + name.len + 1 + value.len;
    if (required > buffer.len - offset) return error.UploadHeaderOverflow;
    var cursor = offset;
    buffer[cursor] = 0;
    cursor += 1;
    buffer[cursor] = @intCast(name.len);
    cursor += 1;
    @memcpy(buffer[cursor..][0..name.len], name);
    cursor += name.len;
    buffer[cursor] = @intCast(value.len);
    cursor += 1;
    @memcpy(buffer[cursor..][0..value.len], value);
    return cursor + value.len;
}

fn send_h2_upload_head(client: *TlsClient, id: u32, path: []const u8, length: u64) !void {
    var block: [256]u8 = undefined;
    var size: usize = 0;
    size = try append_h2_literal(&block, size, ":method", "POST");
    size = try append_h2_literal(&block, size, ":scheme", "https");
    size = try append_h2_literal(&block, size, ":path", path);
    size = try append_h2_literal(&block, size, ":authority", "localhost");
    var length_buffer: [32]u8 = undefined;
    const length_text = try std.fmt.bufPrint(&length_buffer, "{d}", .{length});
    size = try append_h2_literal(&block, size, "content-length", length_text);
    var frame: [512]u8 = undefined;
    var frame_length: usize = 0;
    try append_frame(&frame, &frame_length, .headers, 0x4, id, block[0..size]);
    try client.send(frame[0..frame_length]);
}

const H2Frame = struct {
    header: support.http2.FrameHeader,
    payload: []const u8,
};

fn read_h2_frame(client: *TlsClient, storage: []u8) !H2Frame {
    var raw: [9]u8 = undefined;
    try tls_read_exact(client, &raw);
    const header = try support.http2.FrameHeader.parse(&raw);
    if (header.payload_length > storage.len) return error.UploadFrameTooLarge;
    try tls_read_exact(client, storage[0..header.payload_length]);
    return .{ .header = header, .payload = storage[0..header.payload_length] };
}

test "static files: live HTTP2 100 MB upload streams through a route sink" {
    var sink = UploadSink{};
    var route = sink.route();
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var server = try StaticApp.init_configured(std.testing.io, allocations.allocator(), .{ .max_connections = 1 });
    defer server.deinit();
    server.tls_ctx = try support.tls.TlsContext.init_ephemeral(.{});
    _ = try server.post_stream("/upload", &route);
    try server.listen("127.0.0.1", 0);
    const baseline = allocations.alloc_index;
    const resize_baseline = allocations.resize_index;
    allocations.fail_index = baseline;
    allocations.resize_fail_index = resize_baseline;

    var runner = StaticRunner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, StaticRunner.run, .{&runner});
    var joined = false;
    defer {
        server.request_shutdown();
        if (!joined) thread.join();
    }

    var client = try TlsClient.connect(try support.tcp.listener_port(&server.listeners[0]), true);
    defer client.close();

    var preface: [256]u8 = undefined;
    @memcpy(preface[0..support.http2.client_preface.len], support.http2.client_preface);
    var preface_length: usize = support.http2.client_preface.len;
    try append_frame(&preface, &preface_length, .settings, 0, 0, "\x00\x04\x0c\x80\x00\x00");
    try append_frame(&preface, &preface_length, .window_update, 0, 0, "\x0c\x80\x00\x00");
    try client.send(preface[0..preface_length]);

    var storage: [16 * 1024]u8 = undefined;
    const server_settings = try read_h2_frame(&client, &storage);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(support.http2.FrameType.settings)),
        server_settings.header.frame_type,
    );
    var ack: [9]u8 = undefined;
    var ack_length: usize = 0;
    try append_frame(&ack, &ack_length, .settings, 0x1, 0, "");
    try client.send(ack[0..ack_length]);

    const total: u64 = 100 * 1024 * 1024;
    try send_h2_upload_head(&client, 1, "/upload", total);

    var connection_window: i64 = 65_535;
    var stream_window: i64 = 65_535;
    var payload: [16 * 1024]u8 = undefined;
    @memset(&payload, 0x5a);
    var sent: u64 = 0;
    while (sent < total) {
        const count: usize = @intCast(@min(payload.len, total - sent));
        while (connection_window < count or stream_window < count) {
            const frame = try read_h2_frame(&client, &storage);
            if (frame.header.frame_type != @intFromEnum(support.http2.FrameType.window_update)) continue;
            const increment = std.mem.readInt(u32, frame.payload[0..4], .big) & 0x7fff_ffff;
            if (frame.header.stream_id == 0) {
                connection_window += increment;
            } else if (frame.header.stream_id == 1) {
                stream_window += increment;
            }
        }
        var frame: [9 + payload.len]u8 = undefined;
        var frame_length: usize = 0;
        try append_frame(&frame, &frame_length, .data, 0, 1, payload[0..count]);
        try client.send(frame[0..frame_length]);
        connection_window -= @intCast(count);
        stream_window -= @intCast(count);
        sent += count;
    }

    var end_frame: [9]u8 = undefined;
    var end_length: usize = 0;
    try append_frame(&end_frame, &end_length, .data, 0x1, 1, "");
    try client.send(end_frame[0..end_length]);

    var body: [64]u8 = undefined;
    var body_length: usize = 0;
    while (true) {
        const frame = try read_h2_frame(&client, &storage);
        if (frame.header.stream_id != 1) continue;
        if (frame.header.frame_type == @intFromEnum(support.http2.FrameType.rst_stream)) {
            return error.UploadStreamReset;
        }
        if (frame.header.frame_type != @intFromEnum(support.http2.FrameType.data)) continue;
        if (frame.payload.len > body.len - body_length) return error.UploadResponseTooLarge;
        @memcpy(body[body_length..][0..frame.payload.len], frame.payload);
        body_length += frame.payload.len;
        if (frame.header.flags & 0x1 != 0) break;
    }

    server.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null and sink.failure == null);
    try std.testing.expectEqualStrings("104857600", body[0..body_length]);
    try std.testing.expectEqual(@as(usize, 1), sink.begins);
    try std.testing.expectEqual(@as(usize, 1), sink.ends);
    try std.testing.expectEqual(@as(usize, 0), sink.cancels);
    try std.testing.expectEqual(total, sink.bytes);
    try std.testing.expectEqual(baseline, allocations.alloc_index);
    try std.testing.expectEqual(resize_baseline, allocations.resize_index);
    try std.testing.expect(!allocations.has_induced_failure);
}
