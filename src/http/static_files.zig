const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const cache = @import("cache.zig");
const negotiate = @import("negotiate.zig");

/// An opened regular representation owns its descriptor until selection or transfer.
const Representation = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
    encoding: negotiate.Encoding,
};

pub const Options = struct {
    index: ?[]const u8 = "index.html",
    etag: bool = true,
    max_age: u32 = 0,
    precompressed: bool = false,
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
                error.InvalidStaticPath, error.AccessDenied, error.SymLinkLoop => response.end_best_effort("403 Forbidden", ""),
                error.FileNotFound, error.NotDir => response.end_best_effort("404 Not Found", ""),
                error.FileTooLarge => response.end_best_effort("413 Content Too Large", ""),
                // A file head or first window can be refused before any bytes
                // are queued. Treat it as bounded backpressure, not a 500.
                error.WouldBlock => response.end_with_headers_best_effort(
                    "503 Service Unavailable",
                    "Retry-After: 1\r\n",
                    "",
                ),
                else => response.end_best_effort("500 Internal Server Error", ""),
            };
        }

        pub fn serve(self: *Self, request: *const Request, response: *Response) !void {
            const captured = request.get_param("path") orelse "";
            var path = try normalize_path(captured, &self.path_buffer);
            if (path.len == 0) {
                path = self.options.index orelse return error.FileNotFound;
            } else if (path[path.len - 1] == '/') {
                const index = self.options.index orelse return error.FileNotFound;
                // normalize_path trims leading separators, so `path` may be a
                // subslice; rebuild the index path from its real offset instead
                // of assuming it starts at path_buffer[0].
                const offset = @intFromPtr(path.ptr) - @intFromPtr(&self.path_buffer);
                if (offset > self.path_buffer.len or
                    path.len + 1 + index.len > self.path_buffer.len - offset)
                {
                    return error.InvalidStaticPath;
                }
                self.path_buffer[offset + path.len] = '/';
                @memcpy(self.path_buffer[offset + path.len + 1 ..][0..index.len], index);
                path = self.path_buffer[offset .. offset + path.len + 1 + index.len];
            }
            if (path.len == 0 or path[0] == '/') return error.InvalidStaticPath;

            const representation = try self.select_file(path, request) orelse {
                try response.end_with_headers("406 Not Acceptable", "Vary: Accept-Encoding\r\n", "");
                return;
            };
            var file = representation.file;
            var file_owned = true;
            defer if (file_owned) file.close(self.io);
            const stat = representation.stat;
            const coding: ?negotiate.Encoding = if (self.options.precompressed) representation.encoding else null;

            var etag_buffer: [80]u8 = undefined;
            const entity_tag = if (self.options.etag)
                try format_etag(&etag_buffer, stat.size, stat.mtime.nanoseconds, coding)
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
                    coding,
                );
                try response.end_with_headers("304 Not Modified", headers, "");
                return;
            }

            const range = if (request.get_unique_header("range")) |value| rng: {
                // RFC 9110 section 13.1.5: a mismatched If-Range validator
                // ignores the Range field entirely, so 416 is not emitted.
                if (!range_allowed(request, entity_tag, modified)) break :rng null;
                break :rng parse_range(value, stat.size) catch {
                    var content_range_buffer: [80]u8 = undefined;
                    const content_range = try std.fmt.bufPrint(
                        &content_range_buffer,
                        "Content-Range: bytes */{d}\r\n{s}",
                        .{ stat.size, if (coding != null) "Vary: Accept-Encoding\r\n" else "" },
                    );
                    try response.end_with_headers("416 Range Not Satisfiable", content_range, "");
                    return;
                };
            } else null;

            var headers_buffer: [768]u8 = undefined;
            const headers = try format_headers(
                &headers_buffer,
                path,
                entity_tag,
                modified,
                self.options.max_age,
                stat.size,
                range,
                coding,
            );
            const status = if (range != null) "206 Partial Content" else "200 OK";
            const offset: u64 = if (range) |selected| selected.start else 0;
            const length: u64 = if (range) |selected| selected.length() else stat.size;

            // Plaintext keeps its kernel path; framed transports borrow the
            // handler scratch while owning the descriptor independently.
            if (try try_send_file(response, status, headers, file, offset, length)) {
                file_owned = false;
                return;
            }

            response.stream_file(status, headers, .{
                .io = self.io,
                .file = file,
                .buffer = &self.file_buffer,
                .offset = offset,
                .length = length,
            }) catch |err| {
                if (err != error.FileStreamingUnsupported) return err;
                // Legacy targets have no file callback; preserve their bounded
                // small-file behavior without masking transport failures.
                if (stat.size > self.file_buffer.len) return error.FileTooLarge;
                const bytes_read = try file.readPositionalAll(self.io, self.file_buffer[0..@intCast(stat.size)], 0);
                if (bytes_read != @as(usize, @intCast(stat.size))) return error.UnexpectedEndOfFile;
                if (range) |selected| {
                    const start: usize = @intCast(selected.start);
                    const end: usize = @intCast(selected.end + 1);
                    try response.end_with_headers(status, headers, self.file_buffer[start..end]);
                    return;
                }
                try response.end_with_headers(status, headers, self.file_buffer[0..bytes_read]);
                return;
            };
            file_owned = false;
        }

        /// Holds at most three representation descriptors; releases every unselected one.
        fn select_file(self: *Self, path: []const u8, request: *const Request) !?Representation {
            const file = try self.open_no_symlinks(path, false);
            var source_owned = true;
            defer if (source_owned) file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file) return error.FileNotFound;
            const source = Representation{ .file = file, .stat = stat, .encoding = .identity };
            if (!self.options.precompressed) {
                source_owned = false;
                return source;
            }
            var gzip = try self.open_sidecar(path, ".gz", stat.mtime.nanoseconds, .gzip);
            defer if (gzip) |candidate| candidate.file.close(self.io);
            var br = try self.open_sidecar(path, ".br", stat.mtime.nanoseconds, .br);
            defer if (br) |candidate| candidate.file.close(self.io);
            const encoding = negotiate.select_encoding_headers(request.headers(), .{
                .gzip = gzip != null,
                .br = br != null,
            }) orelse return null;
            switch (encoding) {
                .identity => {
                    source_owned = false;
                    return source;
                },
                .gzip => {
                    const selected = gzip.?;
                    gzip = null;
                    return selected;
                },
                .br => {
                    const selected = br.?;
                    br = null;
                    return selected;
                },
            }
        }

        fn open_sidecar(self: *Self, path: []const u8, suffix: *const [3]u8, source_mtime: i96, encoding: negotiate.Encoding) !?Representation {
            var buffer: [1024]u8 = undefined;
            if (path.len > buffer.len - suffix.len) return null;
            @memcpy(buffer[0..path.len], path);
            @memcpy(buffer[path.len..][0..suffix.len], suffix);
            const file = self.open_no_symlinks(buffer[0 .. path.len + suffix.len], true) catch |err| switch (err) {
                // NameTooLong also covers a valid source leaf whose suffix
                // exceeds the filesystem's component limit.
                error.FileNotFound,
                error.NotDir,
                error.IsDir,
                error.SymLinkLoop,
                error.NotRegularFile,
                error.NameTooLong,
                => return null,
                else => return err,
            };
            var owned = true;
            defer if (owned) file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file or stat.mtime.nanoseconds < source_mtime) return null;
            owned = false;
            return .{ .file = file, .stat = stat, .encoding = encoding };
        }

        /// Only an unavailable kernel path permits a different delivery path.
        fn try_send_file(
            response: *Response,
            status: []const u8,
            headers: []const u8,
            file: std.Io.File,
            offset: u64,
            length: u64,
        ) !bool {
            response.send_file(status, headers, file, offset, length) catch |err| switch (err) {
                error.ZeroCopyUnavailable => return false,
                else => return err,
            };
            return true;
        }

        fn regular_leaf(self: *Self, directory: std.Io.Dir, leaf: []const u8) !bool {
            if (comptime builtin.os.tag != .linux) {
                return (try directory.statFile(self.io, leaf, .{ .follow_symlinks = false })).kind == .file;
            }
            // Pinned Zig 0.16 pathname-stat panics on component NameTooLong.
            // Keep metadata-only open until pathname-stat returns that error.
            const metadata = try directory.openFile(self.io, leaf, .{
                .path_only = true,
                .follow_symlinks = false,
                .allow_directory = true,
            });
            defer metadata.close(self.io);
            return (try metadata.stat(self.io)).kind == .file;
        }

        /// Opens a relative path without following symlinks in any component.
        ///
        /// Zig 0.16 ignores `resolve_beneath` on Linux, and `O_NOFOLLOW` only
        /// covers the final component, so each directory level is opened with
        /// `follow_symlinks = false` explicitly.
        fn open_no_symlinks(self: *Self, path: []const u8, regular_candidate: bool) !std.Io.File {
            var current = self.directory;
            var owns_current = false;
            defer if (owns_current) current.close(self.io);

            var components = std.mem.splitScalar(u8, path, '/');
            var component = next_component(&components) orelse return error.InvalidStaticPath;
            while (next_component(&components)) |next| {
                const child = try current.openDir(self.io, component, .{
                    .access_sub_paths = true,
                    .iterate = false,
                    .follow_symlinks = false,
                });
                if (owns_current) current.close(self.io);
                current = child;
                owns_current = true;
                component = next;
            }
            if (regular_candidate) {
                // Asset publishing controls entry types. This rejects stable
                // special files; hostile regular-to-FIFO replacement can still
                // block the supplied Io open and is outside that boundary.
                if (!try self.regular_leaf(current, component)) return error.NotRegularFile;
            }
            return current.openFile(self.io, component, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
        }
    };
}

/// Returns the next nonempty path component, or null at the end.
fn next_component(components: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (components.next()) |component| {
        if (component.len != 0) return component;
    }
    return null;
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
    if (std.ascii.eqlIgnoreCase(extension, ".woff2")) return "font/woff2";
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

fn format_etag(buffer: []u8, size: u64, mtime_ns: i96, coding: ?negotiate.Encoding) ![]const u8 {
    if (coding) |encoding| return std.fmt.bufPrint(buffer, "\"{s}-{x}-{x}\"", .{ @tagName(encoding), size, @as(u96, @bitCast(mtime_ns)) });
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

/// Reports whether a conditional GET is satisfied without a body.
///
/// If-None-Match takes precedence over If-Modified-Since per RFC 9110; the
/// existing cache helper handles `*`, comma lists, and weak comparison.
pub fn not_modified(request: *const Request, etag: []const u8, modified: []const u8) bool {
    if (etag.len != 0 and request.has_header("if-none-match")) {
        return cache.is_not_modified(request, etag);
    }
    if (modified.len == 0) return false;
    const candidate = request.get_unique_header("if-modified-since") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, candidate, " \t"), modified);
}

/// Reports whether If-Range permits the requested byte range.
///
/// RFC 9110 section 13.1.5 requires strong entity-tag comparison, so a weak
/// validator never matches; an HTTP-date must equal Last-Modified exactly.
pub fn range_allowed(request: *const Request, etag: []const u8, modified: []const u8) bool {
    const candidate = request.get_unique_header("if-range") orelse return true;
    const trimmed = std.mem.trim(u8, candidate, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, "W/")) return false;
    if (trimmed[0] == '"') {
        return etag.len != 0 and std.mem.eql(u8, trimmed, etag);
    }
    if (modified.len == 0) return false;
    return std.mem.eql(u8, trimmed, modified);
}

fn format_headers(
    buffer: []u8,
    path: []const u8,
    etag: []const u8,
    modified: []const u8,
    max_age: u32,
    size: u64,
    range: ?ByteRange,
    coding: ?negotiate.Encoding,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("Content-Type: {s}\r\nAccept-Ranges: bytes\r\n", .{mime_type(path)});
    if (coding) |encoding| {
        try writer.writeAll("Vary: Accept-Encoding\r\n");
        if (encoding != .identity) try writer.print("Content-Encoding: {s}\r\n", .{@tagName(encoding)});
    }
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
