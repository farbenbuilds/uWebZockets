const std = @import("std");
const builtin = @import("builtin");
const support = @import("test_support");
const response = support.http_response;
const Request = support.http_request.Request;
const basic = @import("static_files_tests.zig");
const FileCapture = basic.FileCapture;
const StaticFiles = support.static_files.static_files(64);

// Development-generated fixtures decode to identity; generation is not a build dependency.
const identity = "bounded precompressed static asset\n";
const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\xca\x2f\xcd\x4b\x49\x4d\x51\x28\x28\x4a\x4d\xce\xcf\x05\x92\xc5\xc5\x40\x5e\x71\x49\x62\x49\x66\xb2\x42\x22\x90\x53\xc2\x05\x00\x3e\xec\xfa\x01\x23\x00\x00\x00";
const brotli = "\x1b\x22\x00\x00\x04\x36\xe0\x7c\xa1\x1c\xca\x87\x89\x1c\x38\x64\x2d\xc0\xfb\x61\x03\x4e\xb8\x02\x7a\xf2\x9e\xfc\x21\x29\x8c\x25\x46\xb1\xa9\xe0\x00";
const timestamp: i96 = 1_700_000_000;

/// Observes descriptor balance and injects only named sidecar filesystem failures.
const ProbeIo = struct {
    base: std.Io,
    table: std.Io.VTable,
    opens: usize = 0,
    readable_opens: usize = 0,
    metadata_opens: usize = 0,
    metadata_closes: usize = 0,
    metadata_file: ?std.Io.File = null,
    fail_metadata_stat: ?std.Io.File.StatError = null,
    refuse_readable_sidecar: bool = false,
    forbidden_readable_opens: usize = 0,
    closes: usize = 0,
    dir_opens: usize = 0,
    dir_closes: usize = 0,
    reads: usize = 0,
    gzip_probes: usize = 0,
    br_probes: usize = 0,
    fail_open: ?std.Io.File.OpenError = null,
    fail_stat: ?std.Io.File.StatError = null,
    fault_suffix: []const u8 = ".gz",
    fault_file: ?std.Io.File = null,
    fail_preflight: ?std.Io.Dir.StatFileError = null,
    force_path_kind: ?std.Io.File.Kind = null,
    preflight_mtime: ?i96 = null,
    force_fd_kind: ?std.Io.File.Kind = null,

    fn init() ProbeIo {
        var table = std.testing.io.vtable.*;
        table.dirOpenDir = open_dir;
        table.dirClose = close_dirs;
        table.dirOpenFile = open_file;
        table.dirStatFile = stat_path;
        table.fileStat = stat;
        table.fileReadPositional = read;
        table.fileClose = close_files;
        return .{ .base = std.testing.io, .table = table };
    }

    fn io(state: *ProbeIo) std.Io {
        return .{ .userdata = state, .vtable = &state.table };
    }

    fn get(context: ?*anyopaque) *ProbeIo {
        return @ptrCast(@alignCast(context.?));
    }

    fn open_dir(context: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
        const state = get(context);
        const opened = try state.base.vtable.dirOpenDir(state.base.userdata, dir, path, options);
        state.dir_opens += 1;
        return opened;
    }

    fn close_dirs(context: ?*anyopaque, dirs: []const std.Io.Dir) void {
        const state = get(context);
        state.dir_closes += dirs.len;
        state.base.vtable.dirClose(state.base.userdata, dirs);
    }

    fn record_probe(state: *ProbeIo, path: []const u8) void {
        if (std.mem.endsWith(u8, path, ".gz")) state.gzip_probes += 1;
        if (std.mem.endsWith(u8, path, ".br")) state.br_probes += 1;
    }

    fn open_file(context: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        const state = get(context);
        state.record_probe(path);
        const matches = std.mem.endsWith(u8, path, state.fault_suffix);
        if (matches and !options.path_only) {
            if (state.refuse_readable_sidecar) {
                state.forbidden_readable_opens += 1;
                return error.Unexpected;
            }
            if (state.fail_open) |err| return err;
        }
        const file = try state.base.vtable.dirOpenFile(state.base.userdata, dir, path, options);
        state.opens += 1;
        if (options.path_only) {
            state.metadata_opens += 1;
            state.metadata_file = file;
        } else {
            state.readable_opens += 1;
            if (matches) state.fault_file = file;
        }
        return file;
    }

    fn stat_path(context: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
        const state = get(context);
        state.record_probe(path);
        const matches = std.mem.endsWith(u8, path, state.fault_suffix);
        if (matches) {
            if (state.fail_preflight) |err| return err;
        }
        var metadata = try state.base.vtable.dirStatFile(state.base.userdata, dir, path, options);
        if (matches) {
            if (state.force_path_kind) |kind| metadata.kind = kind;
            if (state.preflight_mtime) |mtime| metadata.mtime.nanoseconds = mtime;
        }
        return metadata;
    }

    fn stat(context: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const state = get(context);
        if (state.metadata_file) |probe| {
            if (probe.handle == file.handle) {
                if (state.fail_metadata_stat) |err| return err;
                var metadata = try state.base.vtable.fileStat(state.base.userdata, file);
                if (state.force_path_kind) |kind| metadata.kind = kind;
                if (state.preflight_mtime) |mtime| metadata.mtime.nanoseconds = mtime;
                return metadata;
            }
        }
        if (state.fault_file) |fault| {
            if (fault.handle == file.handle) {
                if (state.fail_stat) |err| return err;
            }
        }
        var metadata = try state.base.vtable.fileStat(state.base.userdata, file);
        if (state.fault_file) |fault| {
            if (fault.handle == file.handle) {
                if (state.force_fd_kind) |kind| metadata.kind = kind;
            }
        }
        return metadata;
    }

    fn read(context: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const state = get(context);
        state.reads += 1;
        return state.base.vtable.fileReadPositional(state.base.userdata, file, buffers, offset);
    }

    fn close_files(context: ?*anyopaque, files: []const std.Io.File) void {
        const state = get(context);
        state.closes += files.len;
        for (files) |file| {
            if (state.metadata_file) |probe| {
                if (probe.handle != file.handle) continue;
                state.metadata_file = null;
                state.metadata_closes += 1;
            }
        }
        state.base.vtable.fileClose(state.base.userdata, files);
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir = undefined,
    effects: ProbeIo = undefined,
    files: StaticFiles = undefined,

    fn init(state: *Fixture, enabled: bool) !void {
        state.tmp = std.testing.tmpDir(.{});
        errdefer state.tmp.cleanup();
        const root = try state.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        state.effects = ProbeIo.init();
        const options = if (enabled) support.static_files.Options{ .precompressed = true } else support.static_files.Options{};
        state.files = try StaticFiles.init(state.effects.io(), root, options);
    }

    fn populate(state: *Fixture) !void {
        try create_file(state.tmp.dir, "asset.txt", identity, timestamp);
        try create_file(state.tmp.dir, "asset.txt.gz", gzip, timestamp + 2);
        try create_file(state.tmp.dir, "asset.txt.br", brotli, timestamp + 4);
    }

    fn deinit(state: *Fixture) void {
        state.files.deinit();
        std.debug.assert(state.effects.opens == state.effects.closes);
        std.debug.assert(state.effects.dir_opens == state.effects.dir_closes);
        std.debug.assert(state.effects.metadata_opens == state.effects.metadata_closes);
        state.tmp.cleanup();
    }
};

fn create_file(dir: std.Io.Dir, name: []const u8, bytes: []const u8, modified_seconds: i96) !void {
    const file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, bytes, 0);
    try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = modified_seconds * std.time.ns_per_s } } });
}

fn request_for(method: []const u8, path: []const u8, encoding: ?[]const u8) Request {
    var request = Request{ .method = method };
    request.route_param_names[0] = "path";
    request.route_param_values[0] = path;
    request.route_param_count = 1;
    if (encoding) |value| {
        request.header_names[0] = "Accept-Encoding";
        request.header_values[0] = value;
        request.header_count = 1;
    }
    return request;
}

fn header_value(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn close_capture(capture: *FileCapture) void {
    const source = capture.source orelse return;
    capture.source = null;
    source.file.close(source.io);
}

fn expect_payload(capture: *FileCapture, expected: []const u8) !void {
    const source = capture.source orelse return error.NoSelectedFile;
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqual(@as(u64, expected.len), source.length);
    const count = try source.file.readPositionalAll(source.io, bytes[0..expected.len], source.offset);
    try std.testing.expectEqual(expected.len, count);
    try std.testing.expectEqualSlices(u8, expected, bytes[0..count]);
}

test "static sidecars: disabled default preserves identity despite sidecars and refusal" {
    var fixture = Fixture{};
    try fixture.init(false);
    defer fixture.deinit();
    try fixture.populate();
    var request = request_for("GET", "asset.txt", "br, gzip, identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try fixture.files.serve(&request, &output);
    try expect_payload(&capture, identity);
    try std.testing.expect(header_value(capture.headers[0..capture.headers_len], "Content-Encoding") == null);
    try std.testing.expect(header_value(capture.headers[0..capture.headers_len], "Vary") == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.gzip_probes + fixture.effects.br_probes);
    close_capture(&capture);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
}

test "static sidecars: available coding quality selects exact bytes and original MIME" {
    for ([_]bool{ false, true }) |prefer_br| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for("GET", "asset.txt", if (prefer_br) "br, gzip;q=0.5, identity;q=0" else "gzip, br;q=0.2, identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try std.testing.expect(output.is_complete());
        try expect_payload(&capture, if (prefer_br) brotli else gzip);
        const raw = capture.headers[0..capture.headers_len];
        try std.testing.expectEqualStrings(if (prefer_br) "br" else "gzip", header_value(raw, "Content-Encoding").?);
        try std.testing.expectEqualStrings("Accept-Encoding", header_value(raw, "Vary").?);
        try std.testing.expectEqualStrings("text/plain; charset=utf-8", header_value(raw, "Content-Type").?);
        try std.testing.expectEqual(@as(usize, 3), fixture.effects.readable_opens);
        try std.testing.expectEqual(fixture.effects.opens - 1, fixture.effects.closes);
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

fn add_header(request: *Request, name: []const u8, value: []const u8) void {
    const index = request.header_count;
    request.header_names[index] = name;
    request.header_values[index] = value;
    request.header_count += 1;
}

fn expect_status(capture: *const FileCapture, status: []const u8) !void {
    try std.testing.expectEqualStrings(status, capture.status[0..capture.status_len]);
}

fn expect_vary(capture: *const FileCapture) !void {
    try std.testing.expectEqualStrings("Accept-Encoding", header_value(capture.headers[0..capture.headers_len], "Vary").?);
}

test "static sidecars: every field including late duplicates and extras preserves refusal" {
    for (0..4) |case| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for("GET", "asset.txt", "br, gzip, identity;q=0");
        var extra_names = [_][]const u8{"aCcEpT-EnCoDiNg"};
        var extra_values = [_][]const u8{if (case == 0) "br;q=0" else "*;q=0,identity;q=0"};
        if (case == 0 or case == 3) {
            if (case == 3) request.header_count = 0;
            request.extra_header_names = &extra_names;
            request.extra_header_values = &extra_values;
            request.extra_header_count = 1;
        }
        if (case == 1) add_header(&request, "Accept-Encoding", "br;q=0");
        if (case == 2) {
            while (request.header_count < 63) add_header(&request, "X-Filler", "ignored");
            add_header(&request, "Accept-Encoding", "gzip;q=0, br;q=broken");
        }
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_vary(&capture);
        if (case < 2) {
            try expect_payload(&capture, gzip);
        } else {
            try expect_status(&capture, "406 Not Acceptable");
            try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
            try std.testing.expectEqual(@as(usize, 0), capture.body_len);
            try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
        }
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: absent and present-empty fields select varying identity" {
    for ([_]?[]const u8{ null, "" }) |field| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for("GET", "asset.txt", field);
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_payload(&capture, identity);
        try expect_vary(&capture);
        try std.testing.expect(header_value(capture.headers[0..capture.headers_len], "Content-Encoding") == null);
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: missing stale equal-time fresh and wrong-kind availability" {
    for (0..6) |case| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try create_file(fixture.tmp.dir, "asset.txt", identity, timestamp);
        if (case >= 1 and case <= 3) try create_file(fixture.tmp.dir, "asset.txt.gz", gzip, timestamp + @as(i96, @intCast(case)) - 2);
        if (case == 4) try fixture.tmp.dir.createDirPath(std.testing.io, "asset.txt.gz");
        if (case == 5) {
            try create_file(fixture.tmp.dir, "elsewhere", gzip, timestamp + 2);
            try fixture.tmp.dir.symLink(std.testing.io, "elsewhere", "asset.txt.gz", .{});
        }
        var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        if (case == 2 or case == 3) {
            try expect_payload(&capture, gzip);
        } else {
            try expect_status(&capture, "406 Not Acceptable");
            try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
        }
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: nonregular preflight and final fd checks both refuse without reads" {
    for ([_]bool{ false, true }) |after_open| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try create_file(fixture.tmp.dir, "asset.txt", identity, timestamp);
        try create_file(fixture.tmp.dir, "asset.txt.gz", gzip, timestamp + 2);
        if (after_open) fixture.effects.force_fd_kind = .named_pipe else fixture.effects.force_path_kind = .named_pipe;
        var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_status(&capture, "406 Not Acceptable");
        try std.testing.expectEqual(@as(usize, if (after_open) 2 else 1), fixture.effects.readable_opens);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
    }
}

test "static sidecars: orphan compressed files do not replace missing or nonregular sources" {
    for ([_]bool{ false, true }) |directory| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try create_file(fixture.tmp.dir, "asset.txt.gz", gzip, timestamp);
        if (directory) try fixture.tmp.dir.createDirPath(std.testing.io, "asset.txt");
        var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try std.testing.expectError(if (directory) error.IsDir else error.FileNotFound, fixture.files.serve(&request, &output));
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.gzip_probes + fixture.effects.br_probes);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: permission and I/O failures propagate and release earlier candidates" {
    for (0..5) |stage| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        if (stage == 0) fixture.effects.fail_open = error.AccessDenied;
        if (stage == 1) {
            fixture.effects.fail_preflight = error.PermissionDenied;
            fixture.effects.fail_metadata_stat = error.PermissionDenied;
        }
        if (stage == 2) fixture.effects.fail_stat = error.SystemResources;
        if (stage == 3) {
            fixture.effects.fault_suffix = ".br";
            fixture.effects.fail_stat = error.AccessDenied;
        }
        if (stage == 4) {
            fixture.effects.fault_suffix = ".txt";
            fixture.effects.fail_stat = error.AccessDenied;
        }
        var request = request_for("GET", "asset.txt", "gzip,br");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try std.testing.expectError(if (stage == 1) error.PermissionDenied else if (stage == 2) error.SystemResources else error.AccessDenied, fixture.files.serve(&request, &output));
        try std.testing.expectEqual(@as(usize, 0), capture.end_calls + capture.file_calls);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
    }
}

test "static sidecars: failed selected transfer closes once without buffered fallback" {
    for ([_]anyerror{ error.WouldBlock, error.OutputFailed }) |failure| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        var capture = FileCapture{ .failure = failure };
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try std.testing.expectError(failure, fixture.files.serve(&request, &output));
        try std.testing.expectEqual(@as(usize, 1), capture.file_calls);
        try std.testing.expectEqual(@as(usize, 0), capture.end_calls);
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
        try std.testing.expectEqual(@as(usize, 3), fixture.effects.readable_opens);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: coding ETags differ when every representation has identical metadata" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    // Opaque same-attribute bytes isolate the cache-key discrimination contract.
    for ([_][]const u8{ "asset.txt", "asset.txt.gz", "asset.txt.br" }) |path| try create_file(fixture.tmp.dir, path, "same-attrs", timestamp);
    var tags: [3][80]u8 = undefined;
    var lengths: [3]usize = undefined;
    for ([_][]const u8{ "identity", "gzip,identity;q=0", "br,identity;q=0" }, 0..) |field, index| {
        var request = request_for("GET", "asset.txt", field);
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        const tag = header_value(capture.headers[0..capture.headers_len], "ETag").?;
        @memcpy(tags[index][0..tag.len], tag);
        lengths[index] = tag.len;
    }
    try std.testing.expect(!std.mem.eql(u8, tags[0][0..lengths[0]], tags[1][0..lengths[1]]));
    try std.testing.expect(!std.mem.eql(u8, tags[1][0..lengths[1]], tags[2][0..lengths[2]]));
    try std.testing.expect(!std.mem.eql(u8, tags[0][0..lengths[0]], tags[2][0..lengths[2]]));
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
}

test "static sidecars: selected validators ranges and IfRange address exact encoded bytes" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.populate();
    var first = FileCapture{};
    defer close_capture(&first);
    var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
    var output = response.Response{ .target = .{ .http3 = first.target(true) } };
    try fixture.files.serve(&request, &output);
    close_capture(&first);
    const tag = header_value(first.headers[0..first.headers_len], "ETag").?;
    const modified = header_value(first.headers[0..first.headers_len], "Last-Modified").?;
    var original = FileCapture{};
    defer close_capture(&original);
    request = request_for("GET", "asset.txt", "identity");
    output = .{ .target = .{ .http3 = original.target(true) } };
    try fixture.files.serve(&request, &output);
    close_capture(&original);
    try std.testing.expect(!std.mem.eql(u8, modified, header_value(original.headers[0..original.headers_len], "Last-Modified").?));
    var range_buffer: [64]u8 = undefined;
    const selected_range = try std.fmt.bufPrint(&range_buffer, "bytes=2-{d}", .{gzip.len - 3});
    for (0..9) |case| {
        const reads = fixture.effects.reads;
        var capture = FileCapture{};
        defer close_capture(&capture);
        request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        if (case == 0) add_header(&request, "If-None-Match", tag);
        if (case == 1) add_header(&request, "If-Modified-Since", modified);
        if (case >= 2) add_header(&request, "Range", if (case == 3) "bytes=-7" else if (case == 4 or case == 5) "bytes=9999-" else selected_range);
        if (case == 2 or case == 5) add_header(&request, "If-Range", tag);
        if (case == 4) add_header(&request, "If-Range", "\"mismatch\"");
        if (case == 6) add_header(&request, "If-Range", modified);
        var weak: [84]u8 = undefined;
        if (case == 7) add_header(&request, "If-Range", try std.fmt.bufPrint(&weak, "W/{s}", .{tag}));
        if (case == 8) add_header(&request, "If-None-Match", "\"other-coding\"");
        output = .{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_vary(&capture);
        const raw = capture.headers[0..capture.headers_len];
        if (case < 2) {
            try expect_status(&capture, "304 Not Modified");
            try std.testing.expectEqualStrings("gzip", header_value(raw, "Content-Encoding").?);
            try std.testing.expectEqualStrings(modified, header_value(raw, "Last-Modified").?);
            try std.testing.expectEqualStrings(tag, header_value(raw, "ETag").?);
            try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
            try std.testing.expectEqual(reads, fixture.effects.reads);
        } else if (case == 5) {
            try expect_status(&capture, "416 Range Not Satisfiable");
            var expected: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "bytes */{d}", .{gzip.len}), header_value(raw, "Content-Range").?);
            try std.testing.expect(header_value(raw, "Content-Encoding") == null);
            try std.testing.expectEqual(@as(usize, 0), capture.body_len);
            try std.testing.expectEqual(reads, fixture.effects.reads);
        } else {
            const full = case == 4 or case == 7;
            try expect_status(&capture, if (full) "200 OK" else "206 Partial Content");
            const expected = if (full) gzip else if (case == 3) gzip[gzip.len - 7 ..] else gzip[2 .. gzip.len - 2];
            try expect_payload(&capture, expected);
            try std.testing.expectEqualStrings("gzip", header_value(raw, "Content-Encoding").?);
            if (!full) {
                var expected_range: [64]u8 = undefined;
                const start: usize = if (case == 3) gzip.len - 7 else 2;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_range, "bytes {d}-{d}/{d}", .{ start, start + expected.len - 1, gzip.len }), header_value(raw, "Content-Range").?);
            }
        }
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: injected H3 adapter emits selected HEAD length and encoded range bytes" {
    for ([_]bool{ false, true }) |head| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for(if (head) "HEAD" else "GET", "asset.txt", if (head) "br,identity;q=0" else "gzip,identity;q=0");
        if (!head) add_header(&request, "Range", "bytes=5-17");
        var wire = basic.Wire{ .expected = if (head) "" else gzip[5..18] };
        var body: [17]u8 = undefined;
        var headers: [1024]u8 = undefined;
        var quic = basic.init_stream(&wire, &body, &headers);
        defer quic.on_close();
        quic.suppress_body = head;
        var output = response.Response{ .target = .{ .http3 = quic.target() } };
        try fixture.files.serve(&request, &output);
        try basic.drain_stream(&quic, &wire, &fixture.files.file_buffer);
        try std.testing.expectEqual(@as(?u64, if (head) brotli.len else 13), wire.content_length);
        try std.testing.expectEqual(@as(u16, if (head) 200 else 206), wire.status);
        if (head) try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: legacy target fallback copies the selected compressed representation" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.populate();
    var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(false) } };
    try fixture.files.serve(&request, &output);
    try std.testing.expectEqualSlices(u8, gzip, capture.body[0..capture.body_len]);
    try std.testing.expectEqualStrings("gzip", header_value(capture.headers[0..capture.headers_len], "Content-Encoding").?);
    try expect_vary(&capture);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
}

test "static sidecars: identity and encoded 304 responses close without file streaming" {
    for ([_]bool{ false, true }) |encoded| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        const field = if (encoded) "gzip,identity;q=0" else "identity";
        var first = FileCapture{};
        defer close_capture(&first);
        var request = request_for("GET", "asset.txt", field);
        var output = response.Response{ .target = .{ .http3 = first.target(true) } };
        try fixture.files.serve(&request, &output);
        close_capture(&first);
        const tag = header_value(first.headers[0..first.headers_len], "ETag").?;
        add_header(&request, "If-None-Match", tag);
        var wire = basic.Wire{};
        var body: [0]u8 = .{};
        var headers: [1024]u8 = undefined;
        var quic = basic.init_stream(&wire, &body, &headers);
        defer quic.on_close();
        output = .{ .target = .{ .http3 = quic.target() } };
        try fixture.files.serve(&request, &output);
        try basic.drain_stream(&quic, &wire, &fixture.files.file_buffer);
        try std.testing.expectEqual(@as(u16, 304), wire.status);
        try std.testing.expectEqual(@as(?u64, null), wire.content_length);
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        var capture = FileCapture{};
        defer close_capture(&capture);
        output = .{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_status(&capture, "304 Not Modified");
        try expect_vary(&capture);
        const coding = header_value(capture.headers[0..capture.headers_len], "Content-Encoding");
        if (encoded) try std.testing.expectEqualStrings("gzip", coding.?) else try std.testing.expect(coding == null);
    }
}

fn fail_end(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
    return error.WouldBlock;
}

test "static sidecars: metadata and refusal write failures release every descriptor" {
    for (0..3) |case| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.populate();
        var request = request_for("GET", "asset.txt", if (case == 0) "*;q=0,identity;q=0" else "gzip,identity;q=0");
        if (case == 1) add_header(&request, "Range", "bytes=9999-");
        if (case == 2) add_header(&request, "If-None-Match", "*");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var target = capture.target(true);
        target.end_fn = fail_end;
        var output = response.Response{ .target = .{ .http3 = target } };
        try std.testing.expectError(error.WouldBlock, fixture.files.serve(&request, &output));
        // A request that refuses every coding opens only the source; the
        // other cases exercise both candidate sidecars plus the source.
        try std.testing.expectEqual(@as(usize, if (case == 0) 1 else 3), fixture.effects.readable_opens);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
    }
}

test "static sidecars: root and nested indexes preserve source HTML MIME" {
    for ([_][]const u8{ "", "nested/" }) |path| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.tmp.dir.createDirPath(std.testing.io, "nested");
        const source = if (path.len == 0) "index.html" else "nested/index.html";
        const sidecar = if (path.len == 0) "index.html.gz" else "nested/index.html.gz";
        try create_file(fixture.tmp.dir, source, identity, timestamp);
        try create_file(fixture.tmp.dir, sidecar, gzip, timestamp);
        var request = request_for("GET", path, "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        try expect_payload(&capture, gzip);
        try std.testing.expectEqualStrings("text/html; charset=utf-8", header_value(capture.headers[0..capture.headers_len], "Content-Type").?);
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
}

test "static sidecars: percent-encoded trailing slash selects the nested index" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(std.testing.io, "nested");
    try create_file(fixture.tmp.dir, "nested/index.html", identity, timestamp);
    try create_file(fixture.tmp.dir, "nested/index.html.gz", gzip, timestamp);
    var request = request_for("GET", "nested%2f", "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try fixture.files.serve(&request, &output);
    try expect_payload(&capture, gzip);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", header_value(capture.headers[0..capture.headers_len], "Content-Type").?);
    close_capture(&capture);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
}

test "static sidecars: symlink components and encoded traversal stay confined" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(std.testing.io, "real");
    try create_file(fixture.tmp.dir, "real/asset.txt", identity, timestamp);
    try create_file(fixture.tmp.dir, "real/asset.txt.gz", gzip, timestamp);
    try fixture.tmp.dir.symLink(std.testing.io, "real", "linked", .{ .is_directory = true });
    try fixture.tmp.dir.symLink(std.testing.io, "real/asset.txt", "source-link.txt", .{});
    for ([_][]const u8{ "linked/asset.txt", "source-link.txt", "%2e%2e/outside", "real/%2e%2e/asset.txt" }) |path| {
        var request = request_for("GET", path, "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        const result = fixture.files.serve(&request, &output);
        if (result) |_| return error.UnexpectedConfinementSuccess else |err| {
            try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop or err == error.InvalidStaticPath);
        }
        try std.testing.expectEqual(@as(usize, 0), capture.file_calls);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.gzip_probes + fixture.effects.br_probes);
}

test "static sidecars: exact 1024-byte candidate bound does not truncate source paths" {
    for ([_]bool{ true, false }) |fits| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        var path: [1024]u8 = @splat('a');
        for (0..4) |index| path[index * 201 + 200] = '/';
        try fixture.tmp.dir.createDirPath(std.testing.io, path[0..803]);
        const length: usize = if (fits) 1021 else 1022;
        @memcpy(path[length - 4 .. length], ".txt");
        try create_file(fixture.tmp.dir, path[0..length], identity, timestamp);
        if (fits) {
            var candidate: [1024]u8 = undefined;
            @memcpy(candidate[0..length], path[0..length]);
            @memcpy(candidate[length..], ".gz");
            try create_file(fixture.tmp.dir, &candidate, gzip, timestamp);
        }
        var request = request_for("GET", path[0..length], "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        if (fits) {
            try expect_payload(&capture, gzip);
            try std.testing.expect(fixture.effects.gzip_probes > 0);
        } else {
            try expect_status(&capture, "406 Not Acceptable");
            try std.testing.expectEqual(@as(usize, 0), fixture.effects.gzip_probes + fixture.effects.br_probes);
        }
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        try std.testing.expectEqual(fixture.effects.dir_opens, fixture.effects.dir_closes + 1);
    }
}

test "static sidecars: filesystem leaf suffix overflow makes coding unavailable" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    const leaf: [255]u8 = @splat('x');
    try create_file(fixture.tmp.dir, &leaf, identity, timestamp);
    var request = request_for("GET", &leaf, "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try fixture.files.serve(&request, &output);
    try expect_status(&capture, "406 Not Acceptable");
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
}

test "static sidecars: large selected encoding retains the legacy target scratch ceiling" {
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try create_file(fixture.tmp.dir, "asset.txt", identity, timestamp);
    // A valid gzip extra field keeps the same decoded bytes above the 64-byte scratch.
    const large_gzip = gzip[0..3] ++ "\x04" ++ gzip[4..10] ++ "\x40\x00UW\x3c\x00" ++ ("0" ** 60) ++ gzip[10..];
    try create_file(fixture.tmp.dir, "asset.txt.gz", large_gzip, timestamp);
    var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(false) } };
    try std.testing.expectError(error.FileTooLarge, fixture.files.serve(&request, &output));
    try std.testing.expectEqual(@as(usize, 0), capture.end_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
}

test "static sidecars: Linux metadata preflight rejects a stable real FIFO" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    try create_file(fixture.tmp.dir, "asset.txt", identity, timestamp);
    const rc = std.os.linux.mknodat(fixture.tmp.dir.handle, "asset.txt.gz", std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FifoCreationFailed;
    fixture.effects.refuse_readable_sidecar = true;
    var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try fixture.files.serve(&request, &output);
    try expect_status(&capture, "406 Not Acceptable");
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.forbidden_readable_opens);
    try std.testing.expectEqual(@as(usize, 1), fixture.effects.readable_opens);
    try std.testing.expectEqual(fixture.effects.metadata_opens, fixture.effects.metadata_closes);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
}

test "static sidecars: Linux source FIFO is rejected without a blocking open" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture = Fixture{};
    try fixture.init(true);
    defer fixture.deinit();
    const rc = std.os.linux.mknodat(fixture.tmp.dir.handle, "asset.txt", std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FifoCreationFailed;
    var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
    var capture = FileCapture{};
    defer close_capture(&capture);
    var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
    try std.testing.expectError(error.FileNotFound, fixture.files.serve(&request, &output));
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.readable_opens);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects.reads);
    try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
    try std.testing.expectEqual(fixture.effects.metadata_opens, fixture.effects.metadata_closes);
}

test "static sidecars: freshness comes from readable descriptor rather than preflight" {
    for ([_]bool{ false, true }) |fresh| {
        var fixture = Fixture{};
        try fixture.init(true);
        defer fixture.deinit();
        try create_file(fixture.tmp.dir, "asset.txt", identity, timestamp);
        try create_file(fixture.tmp.dir, "asset.txt.gz", gzip, timestamp + @as(i96, if (fresh) 2 else -2));
        fixture.effects.preflight_mtime = (timestamp + @as(i96, if (fresh) -100 else 100)) * std.time.ns_per_s;
        var request = request_for("GET", "asset.txt", "gzip,identity;q=0");
        var capture = FileCapture{};
        defer close_capture(&capture);
        var output = response.Response{ .target = .{ .http3 = capture.target(true) } };
        try fixture.files.serve(&request, &output);
        if (fresh) try expect_payload(&capture, gzip) else try expect_status(&capture, "406 Not Acceptable");
        close_capture(&capture);
        try std.testing.expectEqual(fixture.effects.opens, fixture.effects.closes);
        try std.testing.expectEqual(fixture.effects.metadata_opens, fixture.effects.metadata_closes);
    }
}
