//! Real-time filesystem watching for the development log.
//!
//! Linux uses the native inotify backend: an inotify descriptor is read
//! through the event loop, so saves surface immediately while an idle server
//! stays blocked instead of polling. Every other supported target uses the
//! portable scan backend: a loop timer walks the roots and diffs modification
//! time and size, which needs no OS bindings or helper threads at the cost of
//! latency equal to the scan interval.
//!
//! Both backends share the same contract: bounded state, no allocation on the
//! event path, cancellation through the loop, and a drained guarantee before
//! release.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const core_loop = @import("../core/loop.zig");
const dev_log = @import("dev_log.zig");

const log = std.log.scoped(.watch);

/// Reports whether the native real-time inotify backend is compiled in.
pub const realtime = builtin.os.tag == .linux;

/// Largest number of roots accepted by one application.
pub const max_roots = 8;
/// Largest number of directories watched at once.
pub const max_directories = 64;
/// Largest stored directory path, including its terminator.
pub const max_path_bytes = 4096;
/// Largest directory depth walked below a root.
pub const max_depth = 16;
/// One loop read drains at most this many event bytes.
pub const read_bytes = 4096;
/// Interval between portable scans in milliseconds.
pub const scan_interval_ms: u64 = 500;

/// Failures raised while arming the watcher.
pub const Error = error{
    WatchAlreadyStarted,
    WatchStartFailed,
    TooManyDirectories,
    PathTooLong,
};

/// One decoded inotify record.
pub const Event = struct {
    /// Watch descriptor the kernel assigned to the directory.
    wd: i32,
    /// Raw inotify mask.
    mask: u32,
    /// Entry name inside the watched directory, empty for the directory itself.
    name: []const u8,

    /// Maps a mask to a reported development-log change, or null when the
    /// event only exists to maintain the watch set.
    pub fn change(self: Event) ?dev_log.FileChangeKind {
        if (self.mask & std.os.linux.IN.ISDIR != 0) return null;
        if (self.mask & std.os.linux.IN.CLOSE_WRITE != 0) return .modified;
        if (self.mask & std.os.linux.IN.MOVED_TO != 0) return .created;
        if (self.mask & (std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM) != 0) return .deleted;
        return null;
    }
};

/// Reports whether `name` names a directory the watcher never descends into.
pub fn ignore_directory(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".git",
        ".zig-cache",
        "zig-out",
        "zig-pkg",
        "node_modules",
        ".cache",
    };
    for (ignored) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Decodes the next inotify record in `buffer` and advances `offset` past it.
///
/// Returns null once the buffer is consumed or holds a truncated record.
pub fn next_event(buffer: []const u8, offset: *usize) ?Event {
    const header_bytes = @sizeOf(std.os.linux.inotify_event);
    if (offset.* + header_bytes > buffer.len) return null;
    const header = std.mem.bytesToValue(
        std.os.linux.inotify_event,
        buffer[offset.*..][0..header_bytes],
    );
    const name_start = offset.* + header_bytes;
    const name_end = name_start + header.len;
    if (name_end > buffer.len) return null;
    offset.* = name_end;
    return .{
        .wd = header.wd,
        .mask = header.mask,
        .name = std.mem.sliceTo(buffer[name_start..name_end], 0),
    };
}

/// Platform watcher selected at compile time.
pub const Watcher = if (realtime) LinuxWatcher else ScanWatcher;

/// Portable scan backend used on targets without a native watcher.
///
/// The loop timer calls `scan_once` every `scan_interval_ms`; each scan walks
/// the roots, compares modification time and size against the previous
/// snapshot, reports created, modified, and deleted files, and compacts its
/// path arena so renames cannot exhaust it. The table is bounded, so very
/// large trees are tracked partially with a single warning.
pub const ScanWatcher = struct {
    const Self = @This();

    /// Largest number of files tracked between scans.
    pub const max_files = 256;
    /// Bytes reserved for tracked paths.
    pub const max_tracked_bytes = 16384;

    const Entry = struct {
        /// Last seen modification time in nanoseconds since the Unix epoch.
        mtime_ns: i64 = 0,
        size: u64 = 0,
        path_offset: u32 = 0,
        path_len: u32 = 0,
        seen: bool = false,
    };

    io: std.Io = undefined,
    loop: ?*xev.Loop = null,
    roots: []const []const u8 = &.{},
    timer: xev.Timer = undefined,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    active: bool = false,
    cancel_active: bool = false,
    stopping: bool = false,
    started: bool = false,
    table_warned: bool = false,
    path_bytes: usize = 0,
    entry_count: usize = 0,
    entries: [max_files]Entry = .{Entry{}} ** max_files,
    path_storage: [max_tracked_bytes]u8 = undefined,

    /// Snapshots the roots and arms the recurring scan timer.
    pub fn start(self: *Self, io: std.Io, loop: *xev.Loop, roots: []const []const u8) Error!void {
        if (self.started) return error.WatchAlreadyStarted;
        self.io = io;
        self.loop = loop;
        self.roots = roots;
        self.timer = xev.Timer.init() catch return error.WatchStartFailed;
        self.started = true;
        // Prime the snapshot so startup does not report every existing file.
        self.scan(false);
        self.arm();
    }

    /// Runs one reporting scan immediately; the timer calls this on its own.
    pub fn scan_once(self: *Self) void {
        self.scan(true);
    }

    /// Cancels the scan timer; idempotent and asynchronous.
    pub fn stop(self: *Self, loop: *xev.Loop) void {
        if (!self.started or self.stopping) return;
        self.stopping = true;
        if (!self.active or self.cancel_active) return;
        self.cancel_active = true;
        core_loop.cancel(
            loop,
            &self.completion,
            &self.cancel_completion,
            Self,
            self,
            on_cancel,
        );
    }

    /// Reports whether the scan timer can no longer reference this watcher.
    pub fn is_drained(self: *const Self) bool {
        if (!self.started) return true;
        return !self.active and !self.cancel_active;
    }

    /// Releases the timer; invalidates the watcher.
    ///
    /// Callers must first `stop`, drive the loop, and observe `is_drained`.
    pub fn deinit(self: *Self) void {
        if (self.started) {
            std.debug.assert(self.is_drained());
            self.timer.deinit();
        }
        self.* = undefined;
    }

    fn arm(self: *Self) void {
        const loop = self.loop orelse return;
        self.timer.run(loop, &self.completion, scan_interval_ms, Self, self, on_tick);
        self.active = true;
    }

    fn on_tick(
        user_data: ?*Self,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: anyerror!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.active = false;
        _ = result catch |err| {
            if (err == error.Canceled) return .disarm;
            log.warn("watch scan failed: {}", .{err});
            return .disarm;
        };
        self.scan(true);
        if (self.stopping) return .disarm;
        // Schedule a fresh relative timeout instead of reusing an expired one.
        self.timer.run(loop, completion, scan_interval_ms, Self, self, on_tick);
        self.active = true;
        return .disarm;
    }

    fn on_cancel(
        user_data: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("watch scan cancel failed: {}", .{err});
        };
        self.cancel_active = false;
        self.active = false;
        return .disarm;
    }

    fn scan(self: *Self, announce: bool) void {
        for (self.entries[0..self.entry_count]) |*entry| entry.seen = false;
        for (self.roots) |root| self.walk(root, 0, announce);
        self.reap(announce);
    }

    fn walk(self: *Self, path: []const u8, depth: usize, announce: bool) void {
        if (depth > max_depth) return;
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch return) |entry| {
            if (entry.kind == .directory and ignore_directory(entry.name)) continue;
            var child_buffer: [max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrint(
                &child_buffer,
                "{s}{s}{s}",
                .{ path, std.fs.path.sep_str, entry.name },
            ) catch continue;
            switch (entry.kind) {
                .directory => self.walk(child, depth + 1, announce),
                else => self.observe(dir, entry.name, child, announce),
            }
        }
    }

    fn observe(
        self: *Self,
        dir: std.Io.Dir,
        name: []const u8,
        path: []const u8,
        announce: bool,
    ) void {
        const stat = dir.statFile(self.io, name, .{}) catch return;
        const mtime_ns: i64 = @intCast(stat.mtime.nanoseconds);
        if (self.find(path)) |index| {
            const entry = &self.entries[index];
            entry.seen = true;
            if (entry.mtime_ns == mtime_ns and entry.size == stat.size) return;
            entry.mtime_ns = mtime_ns;
            entry.size = stat.size;
            if (announce) self.report(path, .modified);
            return;
        }
        if (announce) self.report(path, .created);
        self.add(path, mtime_ns, stat.size);
    }

    fn add(self: *Self, path: []const u8, mtime_ns: i64, size: u64) void {
        if (path.len > max_tracked_bytes or self.entry_count >= max_files) {
            self.warn_table_full();
            return;
        }
        if (self.path_bytes + path.len > max_tracked_bytes) {
            self.compact();
            if (self.path_bytes + path.len > max_tracked_bytes) {
                self.warn_table_full();
                return;
            }
        }
        const offset = self.path_bytes;
        @memcpy(self.path_storage[offset..][0..path.len], path);
        self.path_bytes += path.len;
        self.entries[self.entry_count] = .{
            .mtime_ns = mtime_ns,
            .size = size,
            .path_offset = @intCast(offset),
            .path_len = @intCast(path.len),
            .seen = true,
        };
        self.entry_count += 1;
    }

    fn reap(self: *Self, announce: bool) void {
        var index: usize = 0;
        while (index < self.entry_count) {
            if (self.entries[index].seen) {
                index += 1;
                continue;
            }
            if (announce) {
                const entry = self.entries[index];
                self.report(
                    self.path_storage[entry.path_offset..][0..entry.path_len],
                    .deleted,
                );
            }
            self.entry_count -= 1;
            self.entries[index] = self.entries[self.entry_count];
        }
    }

    fn find(self: *const Self, path: []const u8) ?usize {
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            const known = self.path_storage[entry.path_offset..][0..entry.path_len];
            if (std.mem.eql(u8, known, path)) return index;
        }
        return null;
    }

    /// Moves live paths to the front, reclaiming space freed by deletions.
    fn compact(self: *Self) void {
        var write: usize = 0;
        for (self.entries[0..self.entry_count]) |*entry| {
            const path = self.path_storage[entry.path_offset..][0..entry.path_len];
            std.mem.copyForwards(u8, self.path_storage[write..][0..entry.path_len], path);
            entry.path_offset = @intCast(write);
            write += entry.path_len;
        }
        self.path_bytes = write;
    }

    fn report(self: *Self, path: []const u8, kind: dev_log.FileChangeKind) void {
        dev_log.thread_sink().record(.{
            .timestamp_ms = dev_log.now_ms(self.io),
            .level = .info,
            .direction = .data_in,
            .event = .{ .file_changed = .{ .path = path, .kind = kind } },
        });
    }

    fn warn_table_full(self: *Self) void {
        if (self.table_warned) return;
        self.table_warned = true;
        log.warn("file watch table full; some files are not tracked", .{});
    }
};

/// One directory accepted by inotify, with its path in the shared arena.
const Directory = struct {
    wd: i32 = -1,
    path_offset: usize = 0,
    path_len: usize = 0,
};

/// Linux inotify watcher driven by one event-loop read completion.
const LinuxWatcher = struct {
    const Self = @This();

    const watch_mask = std.os.linux.IN.CLOSE_WRITE |
        std.os.linux.IN.MOVED_TO |
        std.os.linux.IN.MOVED_FROM |
        std.os.linux.IN.DELETE |
        std.os.linux.IN.CREATE |
        std.os.linux.IN.DELETE_SELF |
        std.os.linux.IN.MOVE_SELF |
        std.os.linux.IN.ONLYDIR;

    io: std.Io = undefined,
    loop: ?*xev.Loop = null,
    fd: std.posix.fd_t = -1,
    file: xev.File = undefined,
    read_completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    read_active: bool = false,
    read_cancel_active: bool = false,
    started: bool = false,
    stopping: bool = false,
    directory_count: usize = 0,
    path_bytes: usize = 0,
    directories: [max_directories]Directory = .{Directory{}} ** max_directories,
    path_storage: [max_path_bytes]u8 = undefined,
    buffer: [read_bytes]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined,

    /// Opens inotify, watches every root recursively, and arms the loop read.
    ///
    /// Roots that cannot be opened are skipped with a warning; only an
    /// inotify failure aborts startup. `loop` and every recorded path must
    /// stay stable until `is_drained` reports true.
    pub fn start(
        self: *Self,
        io: std.Io,
        loop: *xev.Loop,
        roots: []const []const u8,
    ) Error!void {
        if (self.started) return error.WatchAlreadyStarted;
        const result = std.os.linux.inotify_init1(
            std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK,
        );
        switch (std.os.linux.errno(result)) {
            .SUCCESS => {},
            else => return error.WatchStartFailed,
        }
        self.fd = @intCast(result);
        errdefer self.close_fd();

        self.io = io;
        self.loop = loop;
        for (roots) |root| {
            self.add_root(root, 0) catch |err| {
                log.warn("cannot watch {s}: {}", .{ root, err });
            };
        }
        self.started = true;
        self.read_active = true;
        self.file = xev.File.initFd(self.fd);
        self.file.read(
            loop,
            &self.read_completion,
            .{ .slice = &self.buffer },
            Self,
            self,
            on_read,
        );
    }

    /// Requests cancellation of the loop read; idempotent and asynchronous.
    pub fn stop(self: *Self, loop: *xev.Loop) void {
        if (!self.started or self.stopping) return;
        self.stopping = true;
        if (!self.read_active or self.read_cancel_active) return;
        self.read_cancel_active = true;
        core_loop.cancel(
            loop,
            &self.read_completion,
            &self.cancel_completion,
            Self,
            self,
            on_read_cancel,
        );
    }

    /// Reports whether no completion can still reference this watcher.
    pub fn is_drained(self: *const Self) bool {
        if (!self.started) return true;
        return !self.read_active and !self.read_cancel_active;
    }

    /// Closes the inotify descriptor; invalidates the watcher.
    ///
    /// Callers must first `stop`, drive the loop, and observe `is_drained`.
    pub fn deinit(self: *Self) void {
        if (self.started) std.debug.assert(self.is_drained());
        self.close_fd();
        self.* = undefined;
    }

    fn close_fd(self: *Self) void {
        if (self.fd < 0) return;
        _ = std.posix.system.close(self.fd);
        self.fd = -1;
    }

    /// Watches `path` and every unignored directory below it.
    fn add_root(self: *Self, path: []const u8, depth: usize) Error!void {
        if (depth > max_depth) return error.PathTooLong;
        const stored = try self.store_path(path);
        try self.watch_directory(stored);

        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| {
            log.warn("cannot open {s}: {}", .{ path, err });
            return;
        };
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch |err| {
            log.warn("cannot list {s}: {}", .{ path, err });
            return;
        }) |entry| {
            if (entry.kind != .directory) continue;
            if (ignore_directory(entry.name)) continue;
            var child_buffer: [max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrint(
                &child_buffer,
                "{s}/{s}",
                .{ path, entry.name },
            ) catch continue;
            self.add_root(child, depth + 1) catch |err| {
                log.warn("cannot watch {s}: {}", .{ child, err });
            };
        }
    }

    /// Copies `path` into the arena with a terminator and returns it.
    fn store_path(self: *Self, path: []const u8) Error![:0]const u8 {
        const needed = path.len + 1;
        if (needed > max_path_bytes) return error.PathTooLong;
        if (self.path_bytes + needed > max_path_bytes) return error.PathTooLong;
        const offset = self.path_bytes;
        @memcpy(self.path_storage[offset..][0..path.len], path);
        self.path_storage[offset + path.len] = 0;
        self.path_bytes = offset + needed;
        return self.path_storage[offset..][0..path.len :0];
    }

    /// Adds one directory to the inotify set and records its watch descriptor.
    fn watch_directory(self: *Self, path: [:0]const u8) Error!void {
        if (self.directory_count >= max_directories) return error.TooManyDirectories;
        const result = std.os.linux.inotify_add_watch(self.fd, path.ptr, watch_mask);
        const wd: i32 = switch (std.os.linux.errno(result)) {
            .SUCCESS => @intCast(result),
            .NOTDIR => return error.WatchStartFailed,
            else => return error.WatchStartFailed,
        };
        if (self.find_directory(wd) != null) return;
        const offset = @intFromPtr(path.ptr) - @intFromPtr(&self.path_storage);
        self.directories[self.directory_count] = .{
            .wd = wd,
            .path_offset = offset,
            .path_len = path.len,
        };
        self.directory_count += 1;
    }

    fn find_directory(self: *const Self, wd: i32) ?usize {
        for (self.directories[0..self.directory_count], 0..) |directory, index| {
            if (directory.wd == wd) return index;
        }
        return null;
    }

    fn directory_path(self: *const Self, wd: i32) ?[]const u8 {
        const index = self.find_directory(wd) orelse return null;
        const directory = self.directories[index];
        return self.path_storage[directory.path_offset..][0..directory.path_len];
    }

    fn forget_directory(self: *Self, wd: i32) void {
        const index = self.find_directory(wd) orelse return;
        self.directory_count -= 1;
        self.directories[index] = self.directories[self.directory_count];
    }

    fn on_read(
        user_data: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.read_active = false;
        const bytes = result catch |err| {
            if (self.stopping or err == error.Canceled) return .disarm;
            log.warn("watch read failed: {}", .{err});
            self.read_active = true;
            return .rearm;
        };
        if (self.stopping) return .disarm;
        if (bytes != 0) self.handle_events(self.buffer[0..bytes]);
        // An event may have requested shutdown while being handled.
        if (self.stopping) return .disarm;
        self.read_active = true;
        return .rearm;
    }

    fn on_read_cancel(
        user_data: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        // `NotFound` means the read completed before the cancel landed; either
        // way no cancel is pending once this callback fires.
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("watch cancel failed: {}", .{err});
        };
        self.read_cancel_active = false;
        self.read_active = false;
        return .disarm;
    }

    fn handle_events(self: *Self, buffer: []const u8) void {
        var offset: usize = 0;
        while (next_event(buffer, &offset)) |event| self.handle_event(event);
    }

    fn handle_event(self: *Self, event: Event) void {
        const in = std.os.linux.IN;
        if (event.mask & in.Q_OVERFLOW != 0) {
            log.warn("file watch queue overflowed; some changes were missed", .{});
            return;
        }
        if (event.mask & in.IGNORED != 0) {
            self.forget_directory(event.wd);
            return;
        }
        if (event.mask & in.ISDIR != 0) {
            if (event.mask & (in.CREATE | in.MOVED_TO) != 0) self.watch_child(event);
            if (event.mask & (in.DELETE | in.MOVED_FROM | in.DELETE_SELF | in.MOVE_SELF) != 0) {
                self.forget_directory(event.wd);
            }
            return;
        }
        const kind = event.change() orelse return;
        const parent = self.directory_path(event.wd) orelse return;
        var display_buffer: [max_path_bytes]u8 = undefined;
        const display = if (event.name.len == 0)
            parent
        else
            std.fmt.bufPrint(&display_buffer, "{s}/{s}", .{ parent, event.name }) catch event.name;
        dev_log.thread_sink().record(.{
            .timestamp_ms = dev_log.now_ms(self.io),
            .level = .info,
            .direction = .data_in,
            .event = .{ .file_changed = .{ .path = display, .kind = kind } },
        });
    }

    fn watch_child(self: *Self, event: Event) void {
        const parent = self.directory_path(event.wd) orelse return;
        var path_buffer: [max_path_bytes]u8 = undefined;
        const child = std.fmt.bufPrint(
            &path_buffer,
            "{s}/{s}",
            .{ parent, event.name },
        ) catch {
            log.warn("watch path too long below {s}", .{parent});
            return;
        };
        const stored = self.store_path(child) catch |err| {
            log.warn("cannot watch {s}: {}", .{ child, err });
            return;
        };
        self.watch_directory(stored) catch |err| {
            log.warn("cannot watch {s}: {}", .{ child, err });
        };
    }
};
