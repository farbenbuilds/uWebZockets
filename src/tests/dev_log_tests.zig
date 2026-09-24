//! Unit tests for the allocation-free terminal development log.

const std = @import("std");
const support = @import("test_support");
const dev_log = support.dev_log;
const metrics = support.metrics;
const terminal = support.terminal;

const testing = std.testing;

test "render writes a Vite-style colored request line" {
    var buffer: [dev_log.max_line_bytes]u8 = undefined;
    const line = try dev_log.render(&buffer, .{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_out,
        .event = .{ .http_request = .{ .method = "GET", .path = "/hello", .status = 200 } },
    });
    try testing.expectEqualStrings(
        "\x1b[2m00:00:00\x1b[0m | \x1b[36m[GET]\x1b[0m /hello : " ++
            "\x1b[32m200\x1b[0m\x1b[0m\n",
        line,
    );
}

test "render colors a rejected request by status class" {
    var buffer: [dev_log.max_line_bytes]u8 = undefined;
    const line = try dev_log.render(&buffer, .{
        .timestamp_ms = 3_661_000,
        .level = .info,
        .direction = .data_out,
        .event = .{ .http_request = .{ .method = "POST", .path = "/missing", .status = 404 } },
    });
    try testing.expectEqualStrings(
        "\x1b[2m01:01:01\x1b[0m | \x1b[36m[POST]\x1b[0m /missing : " ++
            "\x1b[33m404\x1b[0m\x1b[0m\n",
        line,
    );
}

test "render uses the comptime metric name" {
    var buffer: [dev_log.max_line_bytes]u8 = undefined;
    const line = try dev_log.render(&buffer, .{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_in,
        .event = .{ .metric = .{ .slot = .http_requests, .value = 7 } },
    });
    try testing.expectEqualStrings(
        "\x1b[2m00:00:00.000\x1b[0m \x1b[1m\x1b[32mIN \x1b[0m " ++
            "\x1b[35mmetric\x1b[0m \x1b[32muwz_http_requests_total\x1b[0m 7\x1b[0m\n",
        line,
    );
}

test "disabled sink records nothing and flushes nothing" {
    var sink = dev_log.Sink{};
    sink.record(.{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_in,
        .event = .{ .connection_opened = .{ .index = 1 } },
    });
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(@as(u64, 0), sink.dropped);
    try testing.expectEqual(@as(usize, 0), sink.flush().written);
}

test "sink writes every record to the bound file immediately" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);

    sink.record(.{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_in,
        .event = .{ .connection_opened = .{ .index = 3 } },
    });
    try testing.expectEqual(@as(usize, 0), sink.len);

    const first = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "\n"));
    try testing.expect(std.mem.find(u8, first, "#3 accepted") != null);

    sink.record(.{
        .timestamp_ms = 1,
        .level = .info,
        .direction = .data_in,
        .event = .{ .ws_message = .{ .payload_len = 5, .is_text = true } },
    });
    try testing.expectEqual(@as(usize, 0), sink.len);

    const second = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(second);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, second, "\n"));
    try testing.expect(std.mem.find(u8, second, "#3 accepted") != null);
    try testing.expect(std.mem.find(u8, second, "text\x1b[0m \x1b[2m5B") != null);
    file.close(testing.io);
}

test "oversized records are dropped instead of corrupting the log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);
    defer file.close(testing.io);

    const oversized = "x" ** (dev_log.capacity + 1);
    sink.record(.{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_in,
        .event = .{ .http_request = .{ .method = "GET", .path = oversized, .status = 200 } },
    });
    try testing.expectEqual(@as(u64, 1), sink.dropped);
    try testing.expectEqual(@as(usize, 0), sink.len);
}

test "a burst of records is written without dropping any record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);

    const path = "a" ** 120;
    var index: usize = 0;
    while (index < 100) : (index += 1) {
        sink.record(.{
            .timestamp_ms = @intCast(index),
            .level = .info,
            .direction = .data_in,
            .event = .{ .http_request = .{ .method = "GET", .path = path, .status = 200 } },
        });
    }
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(@as(u64, 0), sink.dropped);
    try testing.expect(sink.written > 0);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity * 8),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, contents, "\n"));
}

test "record_metrics renders every registry slot exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);

    var registry = metrics.Registry{};
    registry.add(.http_requests, 3);
    registry.add(.ws_messages, 9);
    sink.record_metrics(0, .data_out, &registry);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);

    const slot_fields = @typeInfo(metrics.Slot).@"enum".fields;
    try testing.expectEqual(@as(usize, slot_fields.len), std.mem.count(u8, contents, "\n"));
    inline for (slot_fields) |field| {
        const slot: metrics.Slot = @enumFromInt(field.value);
        try testing.expect(std.mem.find(u8, contents, metrics.metric_name(slot)) != null);
    }
    try testing.expect(std.mem.find(u8, contents, "uwz_http_requests_total\x1b[0m 3") != null);
    try testing.expect(std.mem.find(u8, contents, "uwz_ws_messages_total\x1b[0m 9") != null);
}

test "thread_sink returns one stable sink per thread" {
    try testing.expectEqual(dev_log.thread_sink(), dev_log.thread_sink());
}

test "now_ms converts the wall clock into milliseconds" {
    try testing.expect(dev_log.now_ms(testing.io) > 0);
}

test "banner matches the startup wordmark exactly" {
    const expected =
        \\██╗   ██╗██╗    ██╗███████╗██████╗ ███████╗ ██████╗  ██████╗██╗  ██╗███████╗████████╗███████╗
        \\██║   ██║██║    ██║██╔════╝██╔══██╗╚══███╔╝██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝██╔════╝
        \\██║   ██║██║ █╗ ██║█████╗  ██████╔╝  ███╔╝ ██║   ██║██║     █████╔╝ █████╗     ██║   ███████╗
        \\██║   ██║██║███╗██║██╔══╝  ██╔══██╗ ███╔╝  ██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   ╚════██║
        \\╚██████╔╝╚███╔███╔╝███████╗██████╔╝███████╗╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   ███████║
        \\██╔════╝  ╚══╝╚══╝ ╚══════╝╚═════╝ ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝
        \\██║                                                                                          
        \\╚═╝                                                                                          
    ;
    try testing.expectEqualStrings(expected, dev_log.banner);
}

test "banner width constants match the wordmark lines" {
    var lines = std.mem.splitScalar(u8, dev_log.banner, '\n');
    while (lines.next()) |line| {
        try testing.expectEqual(dev_log.banner_columns, try std.unicode.utf8CountCodepoints(line));
    }
    try testing.expectEqual(
        dev_log.wordmark_columns,
        try std.unicode.utf8CountCodepoints(dev_log.wordmark),
    );
}

test "banner_for_columns picks the widest wordmark that fits" {
    try testing.expectEqualStrings(dev_log.banner, dev_log.banner_for_columns(null));
    try testing.expectEqualStrings(dev_log.banner, dev_log.banner_for_columns(dev_log.banner_columns));
    try testing.expectEqualStrings(
        dev_log.wordmark,
        dev_log.banner_for_columns(dev_log.banner_columns - 1),
    );
    try testing.expectEqualStrings(
        dev_log.wordmark,
        dev_log.banner_for_columns(dev_log.wordmark_columns),
    );
    try testing.expectEqualStrings("", dev_log.banner_for_columns(dev_log.wordmark_columns - 1));
}

test "record_banner writes the full wordmark and a padding line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);
    sink.record_banner(null);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(dev_log.banner ++ "\n\n", contents);
}

test "record_banner writes the one-line wordmark on a narrow terminal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);
    sink.record_banner(dev_log.wordmark_columns);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(dev_log.wordmark ++ "\n\n", contents);
}

test "record_banner writes once per sink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "dev_log.txt", .{});
    var sink = dev_log.Sink{};
    sink.enable(testing.io, file);
    sink.record_banner(null);
    sink.record_banner(null);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(dev_log.banner ++ "\n\n", contents);
}

test "terminal columns are unknown for a regular file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "out.txt", .{});
    defer file.close(testing.io);
    try testing.expectEqual(@as(?usize, null), terminal.columns(file));
}

test "disabled sink writes no banner" {
    var sink = dev_log.Sink{};
    sink.record_banner(null);
    try testing.expect(!sink.banner_written);
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(@as(u64, 0), sink.dropped);
}
