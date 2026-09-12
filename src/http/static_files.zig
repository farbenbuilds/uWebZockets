const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Options = struct {
    index: ?[]const u8 = "index.html",
    etag: bool = true,
    max_age: u32 = 0,
};

pub const ByteRange = struct {
    start: u64,
    end: u64,

    pub fn length(self: ByteRange) u64 {
        return self.end - self.start + 1;
    }
};

/// Returns a fixed-capacity static directory handler.
pub fn static_files(comptime file_capacity: usize) type {
    if (file_capacity == 0) @compileError("static file capacity must be greater than zero");

    return struct {
        const Self = @This();

        io: std.Io,
        directory: std.Io.Dir,
        options: Options,
        file_buffer: [file_capacity]u8 = undefined,
        path_buffer: [1024]u8 = undefined,

        pub fn init(io: std.Io, root: []const u8, options: Options) !Self {
            if (options.index) |index| {
                var index_buffer: [1024]u8 = undefined;
                _ = try normalize_path(index, &index_buffer);
            }
            const directory = try std.Io.Dir.cwd().openDir(io, root, .{
                .access_sub_paths = true,
                .iterate = false,
                .follow_symlinks = false,
            });
            return .{ .io = io, .directory = directory, .options = options };
        }

        pub fn deinit(self: *Self) void {
            self.directory.close(self.io);
        }

        pub fn handler(context: *anyopaque, request: *Request, response: *Response) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.serve(request, response) catch |err| switch (err) {
                error.InvalidStaticPath, error.AccessDenied => end_best_effort(response, "403 Forbidden"),
                error.FileNotFound, error.NotDir => end_best_effort(response, "404 Not Found"),
                error.FileTooLarge => end_best_effort(response, "413 Content Too Large"),
                else => end_best_effort(response, "500 Internal Server Error"),
            };
        }

        pub fn serve(self: *Self, request: *const Request, response: *Response) !void {
            const captured = request.get_param("path") orelse "";
            var path = try normalize_path(captured, &self.path_buffer);
            if (path.len == 0) {
                path = self.options.index orelse return error.FileNotFound;
            } else if (captured[captured.len - 1] == '/') {
                const index = self.options.index orelse return error.FileNotFound;
                if (path.len + 1 + index.len > self.path_buffer.len) return error.InvalidStaticPath;
                self.path_buffer[path.len] = '/';
                @memcpy(self.path_buffer[path.len + 1 ..][0..index.len], index);
                path = self.path_buffer[0 .. path.len + 1 + index.len];
            }

            var file = try self.directory.openFile(self.io, path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file) return error.FileNotFound;
            if (stat.size > self.file_buffer.len) return error.FileTooLarge;

            var etag_buffer: [80]u8 = undefined;
            const entity_tag = if (self.options.etag)
                try format_etag(&etag_buffer, stat.size, stat.mtime.nanoseconds)
            else
                "";
            var modified_buffer: [32]u8 = undefined;
            const modified = format_http_date(&modified_buffer, stat.mtime.nanoseconds) catch "";
            if (not_modified(request, entity_tag, modified)) {
                var headers_buffer: [512]u8 = undefined;
                const headers = try format_headers(
                    &headers_buffer,
                    path,
                    entity_tag,
                    modified,
                    self.options.max_age,
                    stat.size,
                    null,
                );
                try response.end_with_headers("304 Not Modified", headers, "");
                return;
            }

            const bytes_read = try file.readPositionalAll(self.io, self.file_buffer[0..@intCast(stat.size)], 0);
            if (bytes_read != @as(usize, @intCast(stat.size))) return error.UnexpectedEndOfFile;
            const range = if (request.get_unique_header("range")) |value|
                parse_range(value, stat.size) catch {
                    var content_range_buffer: [80]u8 = undefined;
                    const content_range = try std.fmt.bufPrint(
                        &content_range_buffer,
                        "Content-Range: bytes */{d}\r\n",
                        .{stat.size},
                    );
                    try response.end_with_headers("416 Range Not Satisfiable", content_range, "");
                    return;
                }
            else
                null;

            var headers_buffer: [768]u8 = undefined;
            const headers = try format_headers(
                &headers_buffer,
                path,
                entity_tag,
                modified,
                self.options.max_age,
                stat.size,
                range,
            );
            if (range) |selected| {
                const start: usize = @intCast(selected.start);
                const end: usize = @intCast(selected.end + 1);
                try response.end_with_headers("206 Partial Content", headers, self.file_buffer[start..end]);
                return;
            }
            try response.end_with_headers("200 OK", headers, self.file_buffer[0..bytes_read]);
        }
    };
}

fn end_best_effort(response: *Response, status: []const u8) void {
    // The synchronous route ABI has no caller after the handler returns.
    response.end(status, "") catch {};
}

/// Parses one RFC 9110 byte range. Multiple ranges are intentionally rejected.
pub fn parse_range(value: []const u8, size: u64) !?ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=")) return error.InvalidRange;
    if (std.mem.indexOfScalar(u8, value, ',') != null) return error.MultipleRangesUnsupported;
    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    if (size == 0) return error.RangeNotSatisfiable;

    const start_text = std.mem.trim(u8, spec[0..dash], " \t");
    const end_text = std.mem.trim(u8, spec[dash + 1 ..], " \t");
    if (start_text.len == 0) {
        const suffix = std.fmt.parseInt(u64, end_text, 10) catch return error.InvalidRange;
        if (suffix == 0) return error.RangeNotSatisfiable;
        return .{ .start = size - @min(size, suffix), .end = size - 1 };
    }

    const start = std.fmt.parseInt(u64, start_text, 10) catch return error.InvalidRange;
    if (start >= size) return error.RangeNotSatisfiable;
    const end = if (end_text.len == 0)
        size - 1
    else
        std.fmt.parseInt(u64, end_text, 10) catch return error.InvalidRange;
    if (end < start) return error.RangeNotSatisfiable;
    return .{ .start = start, .end = @min(end, size - 1) };
}

/// Maps common web extensions without allocating.
pub fn mime_type(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(extension, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".xml")) return "application/xml";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(extension, ".zip")) return "application/zip";
    return "application/octet-stream";
}

fn normalize_path(input: []const u8, buffer: []u8) ![]const u8 {
    if (input.len > buffer.len) return error.InvalidStaticPath;
    var output_length: usize = 0;
    var input_index: usize = 0;
    while (input_index < input.len) {
        var byte = input[input_index];
        if (byte == '%') {
            if (input_index + 2 >= input.len) return error.InvalidStaticPath;
            const high = hex(input[input_index + 1]) orelse return error.InvalidStaticPath;
            const low = hex(input[input_index + 2]) orelse return error.InvalidStaticPath;
            byte = high << 4 | low;
            input_index += 3;
        } else {
            input_index += 1;
        }
        if (byte == 0 or byte == '\\') return error.InvalidStaticPath;
        buffer[output_length] = byte;
        output_length += 1;
    }

    var segments = std.mem.splitScalar(u8, buffer[0..output_length], '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidStaticPath;
        }
    }
    return std.mem.trimStart(u8, buffer[0..output_length], "/");
}

fn format_etag(buffer: []u8, size: u64, mtime_ns: i96) ![]const u8 {
    return std.fmt.bufPrint(buffer, "\"{x}-{x}\"", .{ size, @as(u96, @bitCast(mtime_ns)) });
}

fn format_http_date(buffer: []u8, mtime_ns: i96) ![]const u8 {
    if (mtime_ns < 0) return error.InvalidTimestamp;
    const seconds: u64 = @intCast(@divTrunc(mtime_ns, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(
        buffer,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekdays[epoch_day.day % 7],
            month_day.day_index + 1,
            months[@intFromEnum(month_day.month) - 1],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn not_modified(request: *const Request, etag: []const u8, modified: []const u8) bool {
    if (etag.len != 0) {
        if (request.get_unique_header("if-none-match")) |candidate| {
            if (std.mem.eql(u8, std.mem.trim(u8, candidate, " \t"), etag)) return true;
        }
    }
    if (modified.len == 0) return false;
    const candidate = request.get_unique_header("if-modified-since") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, candidate, " \t"), modified);
}

fn format_headers(
    buffer: []u8,
    path: []const u8,
    etag: []const u8,
    modified: []const u8,
    max_age: u32,
    size: u64,
    range: ?ByteRange,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("Content-Type: {s}\r\nAccept-Ranges: bytes\r\n", .{mime_type(path)});
    if (etag.len != 0) try writer.print("ETag: {s}\r\n", .{etag});
    if (modified.len != 0) try writer.print("Last-Modified: {s}\r\n", .{modified});
    if (max_age != 0) try writer.print("Cache-Control: public, max-age={d}\r\n", .{max_age});
    if (range) |selected| {
        try writer.print(
            "Content-Range: bytes {d}-{d}/{d}\r\n",
            .{ selected.start, selected.end, size },
        );
    }
    return writer.buffered();
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
