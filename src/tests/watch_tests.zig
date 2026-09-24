//! Unit and integration tests for the development-log file watcher.

const std = @import("std");
const support = @import("test_support");
const dev_log = support.dev_log;
const file_watch = support.file_watch;
const config = support.config;
const core_loop = support.loop;

const testing = std.testing;

fn event_with_mask(mask: u32) file_watch.Event {
    return .{ .wd = 1, .mask = mask, .name = "saved.zig" };
}

test "ignore_directory skips build and vcs directories" {
    try testing.expect(file_watch.ignore_directory(".git"));
    try testing.expect(file_watch.ignore_directory(".zig-cache"));
    try testing.expect(file_watch.ignore_directory("zig-out"));
    try testing.expect(file_watch.ignore_directory("zig-pkg"));
    try testing.expect(file_watch.ignore_directory("node_modules"));
    try testing.expect(!file_watch.ignore_directory("src"));
    try testing.expect(!file_watch.ignore_directory(".github"));
}

test "next_event decodes a record and stops at the end" {
    if (file_watch.realtime) {
        const in = std.os.linux.IN;
        const header_bytes = @sizeOf(std.os.linux.inotify_event);
        const name_bytes = std.mem.alignForward(usize, "saved.zig".len + 1, 4);
        const header = std.os.linux.inotify_event{
            .wd = 7,
            .mask = in.CLOSE_WRITE,
            .cookie = 0,
            .len = @intCast(name_bytes),
        };
        var buffer: [128]u8 align(@alignOf(std.os.linux.inotify_event)) = @splat(0);
        @memcpy(buffer[0..header_bytes], std.mem.asBytes(&header));
        @memcpy(buffer[header_bytes..][0.."saved.zig".len], "saved.zig");
        const used = header_bytes + name_bytes;

        var offset: usize = 0;
        const event = file_watch.next_event(buffer[0..used], &offset) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i32, 7), event.wd);
        try testing.expectEqual(in.CLOSE_WRITE, event.mask);
        try testing.expectEqualStrings("saved.zig", event.name);
        try testing.expectEqual(used, offset);
        try testing.expect(file_watch.next_event(buffer[0..used], &offset) == null);
    }
}

test "event masks map to reported change kinds" {
    if (file_watch.realtime) {
        const in = std.os.linux.IN;
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, null),
            event_with_mask(in.MODIFY).change(),
        );
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, .modified),
            event_with_mask(in.CLOSE_WRITE).change(),
        );
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, .created),
            event_with_mask(in.MOVED_TO).change(),
        );
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, .deleted),
            event_with_mask(in.DELETE).change(),
        );
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, .deleted),
            event_with_mask(in.MOVED_FROM).change(),
        );
        try testing.expectEqual(
            @as(?dev_log.FileChangeKind, null),
            event_with_mask(in.CLOSE_WRITE | in.ISDIR).change(),
        );
    }
}

test "watch paths require the development log" {
    const without_log = config.ServerConfig{ .watch_paths = &.{"src"} };
    try testing.expectError(error.WatchRequiresDevLog, without_log.validate());
}

test "watch paths validate shape" {
    const valid = config.ServerConfig{
        .enable_dev_log = true,
        .watch_paths = &.{"src"},
    };
    try valid.validate();

    const empty = [_][]const u8{""};
    const with_empty = config.ServerConfig{
        .enable_dev_log = true,
        .watch_paths = &empty,
    };
    try testing.expectError(error.InvalidWatchConfiguration, with_empty.validate());

    const too_many = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    const over_capacity = config.ServerConfig{
        .enable_dev_log = true,
        .watch_paths = &too_many,
    };
    try testing.expectError(error.InvalidWatchConfiguration, over_capacity.validate());
}

test "watcher reports a saved file to the dev log sink" {
    if (file_watch.realtime) {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(
            &path_buffer,
            ".zig-cache/tmp/{s}",
            .{tmp.sub_path},
        );

        const log_file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
        const previous_sink = dev_log.thread_sink().*;
        dev_log.thread_sink().* = .{};
        dev_log.thread_sink().enable(testing.io, log_file);

        var loop = try core_loop.init();
        var watch = file_watch.Watcher{};
        try watch.start(testing.io, loop.get_xev_loop(), &.{dir_path});
        defer {
            watch.stop(loop.get_xev_loop());
            loop.get_xev_loop().run(.until_done) catch {};
            watch.deinit();
            dev_log.thread_sink().* = previous_sink;
            core_loop.deinit(&loop);
        }

        // The watch is armed before the file exists, so the kernel queues the
        // close-for-write event and the loop processes it on the first run.
        const saved = try tmp.dir.createFile(testing.io, "saved.zig", .{});
        saved.close(testing.io);
        try loop.get_xev_loop().run(.once);

        log_file.close(testing.io);
        const contents = try tmp.dir.readFileAlloc(
            testing.io,
            "dev_log.txt",
            testing.allocator,
            .limited(dev_log.capacity),
        );
        defer testing.allocator.free(contents);
        try testing.expect(std.mem.find(u8, contents, "saved.zig") != null);
        try testing.expect(std.mem.find(u8, contents, "modified") != null);
    }
}

test "scan watcher reports created, modified, and deleted files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache{s}tmp{s}{s}",
        .{ std.fs.path.sep_str, std.fs.path.sep_str, tmp.sub_path },
    );

    // The file must exist before the first scan so the change is a
    // modification rather than a creation.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "edited.zig", .data = "one\n" });

    const log_file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    const previous_sink = dev_log.thread_sink().*;
    dev_log.thread_sink().* = .{};
    dev_log.thread_sink().enable(testing.io, log_file);

    var loop = try core_loop.init();
    var watch = file_watch.ScanWatcher{};
    try watch.start(testing.io, loop.get_xev_loop(), &.{dir_path});
    defer {
        watch.stop(loop.get_xev_loop());
        loop.get_xev_loop().run(.until_done) catch {};
        watch.deinit();
        dev_log.thread_sink().* = previous_sink;
        core_loop.deinit(&loop);
    }

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "edited.zig", .data = "one\ntwo\n" });
    const created = try tmp.dir.createFile(testing.io, "created.zig", .{});
    created.close(testing.io);
    watch.scan_once();

    try tmp.dir.deleteFile(testing.io, "created.zig");
    watch.scan_once();

    log_file.close(testing.io);
    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);
    var expected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sep = std.fs.path.sep_str;
    try testing.expect(std.mem.find(u8, contents, try std.fmt.bufPrint(
        &expected_buffer,
        "{s}{s:<8}{s} {s}{s}edited.zig",
        .{ dev_log.Ansi.yellow, "modified", dev_log.Ansi.reset, dir_path, sep },
    )) != null);
    try testing.expect(std.mem.find(u8, contents, try std.fmt.bufPrint(
        &expected_buffer,
        "{s}{s:<8}{s} {s}{s}created.zig",
        .{ dev_log.Ansi.green, "created", dev_log.Ansi.reset, dir_path, sep },
    )) != null);
    try testing.expect(std.mem.find(u8, contents, try std.fmt.bufPrint(
        &expected_buffer,
        "{s}{s:<8}{s} {s}{s}created.zig",
        .{ dev_log.Ansi.red, "deleted", dev_log.Ansi.reset, dir_path, sep },
    )) != null);
}
