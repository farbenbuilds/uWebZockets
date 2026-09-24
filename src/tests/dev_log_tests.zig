//! Unit tests for the allocation-free terminal development log.

const std = @import("std");
const support = @import("test_support");
const dev_log = support.dev_log;
const metrics = support.metrics;

const testing = std.testing;

test "render writes a colored data-in request line" {
    var buffer: [dev_log.max_line_bytes]u8 = undefined;
    const line = try dev_log.render(&buffer, .{
        .timestamp_ms = 0,
        .level = .info,
        .direction = .data_in,
        .event = .{ .http_request = .{ .method = "GET", .path = "/hello" } },
    });
    try testing.expectEqualStrings(
        "\x1b[2m00:00:00.000\x1b[0m \x1b[1m\x1b[32mIN \x1b[0m " ++
            "\x1b[36mhttp  \x1b[0m \x1b[1mGET\x1b[0m /hello\x1b[0m\n",
        line,
    );
}

test "render writes a colored data-out response line" {
    var buffer: [dev_log.max_line_bytes]u8 = undefined;
    const line = try dev_log.render(&buffer, .{
        .timestamp_ms = 3_661_000,
        .level = .info,
        .direction = .data_out,
        .event = .{ .http_response = .{ .status = 204, .bytes = 12 } },
    });
    try testing.expectEqualStrings(
        "\x1b[2m01:01:01.000\x1b[0m \x1b[1m\x1b[34mOUT\x1b[0m " ++
            "\x1b[36mhttp  \x1b[0m \x1b[32m204\x1b[0m \x1b[2m12B\x1b[0m\x1b[0m\n",
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

test "sink batches records and flushes them to the bound file" {
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
    sink.record(.{
        .timestamp_ms = 1,
        .level = .info,
        .direction = .data_in,
        .event = .{ .ws_message = .{ .payload_len = 5, .is_text = true } },
    });

    const outcome = sink.flush();
    try testing.expect(!outcome.failed);
    try testing.expect(outcome.written > 0);
    try testing.expectEqual(@as(usize, 0), sink.len);
    file.close(testing.io);

    const contents = try tmp.dir.readFileAlloc(
        testing.io,
        "dev_log.txt",
        testing.allocator,
        .limited(dev_log.capacity),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
    try testing.expect(std.mem.find(u8, contents, "#3 accepted") != null);
    try testing.expect(std.mem.find(u8, contents, "text\x1b[0m \x1b[2m5B") != null);
}

test "oversized records are dropped instead of corrupting the batch" {
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
        .event = .{ .http_request = .{ .method = "GET", .path = oversized } },
    });
    try testing.expectEqual(@as(u64, 1), sink.dropped);
    try testing.expectEqual(@as(usize, 0), sink.len);
}

test "a full batch flushes without dropping any record" {
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
            .event = .{ .http_request = .{ .method = "GET", .path = path } },
        });
    }
    const outcome = sink.flush();
    try testing.expect(!outcome.failed);
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
    const outcome = sink.flush();
    try testing.expect(!outcome.failed);
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
