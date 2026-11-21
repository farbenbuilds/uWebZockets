const std = @import("std");
const arena = @import("sql_httparena");
const uz = @import("test_support").public_api;

test "sql arena: query defaults and signed clamp match current profile" {
    try std.testing.expectEqual(arena.Range{ .minimum = 10, .maximum = 50, .limit = 50 }, arena.query_range(.{}));
    const cases = [_][]const u8{ "min=1&max=200&limit=7", "min=invalid&max=2147483648&limit=-2", "limit=999", "limit=0" };
    const expected = [_]arena.Range{
        .{ .minimum = 1, .maximum = 200, .limit = 7 },
        .{ .minimum = 10, .maximum = 50, .limit = 1 },
        .{ .minimum = 10, .maximum = 50, .limit = 50 },
        .{ .minimum = 10, .maximum = 50, .limit = 1 },
    };
    for (cases, expected) |query, want| try std.testing.expectEqual(want, arena.query_range(try uz.query.QueryParams.parse(query)));
}

test "sql arena: TLS identity and standard pool workers preserve profile policy" {
    try std.testing.expectEqualStrings("::1", arena.tls_server_name("[::1]"));
    try std.testing.expectEqualStrings("localhost", arena.tls_server_name("localhost"));
    try std.testing.expectEqualStrings("127.0.0.1", arena.tls_server_name("127.0.0.1"));
    const config = arena.Configuration{ .sql = .{ .user = "test", .database = "test" }, .max_workers = 32 };
    try std.testing.expectEqual(@as(usize, 32), try arena.worker_count(config, null));
    try std.testing.expectEqual(@as(usize, 1), try arena.worker_count(config, "1"));
    try std.testing.expectError(error.InvalidWorkerCount, arena.worker_count(config, "0"));
    try std.testing.expectError(error.InvalidWorkerCount, arena.worker_count(config, "33"));
}

test "sql arena: GET fixture retains admission within a bounded startup slab" {
    try std.testing.expectEqual(@as(usize, 1024), arena.http_config.max_connections);
    try std.testing.expectEqual(@as(usize, 64 * 1024), arena.http_config.write_queue_size);
    try std.testing.expect((try arena.http_config.slab_bytes()) <= 256 * 1024 * 1024);
}

const Fixture = struct {
    columns: [9]uz.sql.types.Column = .{
        .{ .name = "id", .oid = 23, .format = .binary },
        .{ .name = "name", .oid = 25, .format = .binary },
        .{ .name = "category", .oid = 25, .format = .binary },
        .{ .name = "price", .oid = 23, .format = .binary },
        .{ .name = "quantity", .oid = 23, .format = .binary },
        .{ .name = "active", .oid = 16, .format = .binary },
        .{ .name = "tags", .oid = 3802, .format = .binary },
        .{ .name = "rating_score", .oid = 23, .format = .binary },
        .{ .name = "rating_count", .oid = 23, .format = .binary },
    },
    fields: [9]uz.sql.types.Field = undefined,
    data: [4096]u8 = undefined,
    length: usize = 0,

    fn row(self: *Fixture, tags: []const u8) void {
        const values = [_][]const u8{ "\x00\x00\x00\x2a", "quoted \"name\"", "\xe7\x8c\xab", "\x00\x00\x00\x1e", "\x00\x00\x00\x05", "\x01", tags, "\x00\x00\x00\x29", "\x00\x00\x00\x7f" };
        self.length = 7;
        self.data[0] = 'D';
        std.mem.writeInt(u16, self.data[5..7], 9, .big);
        for (values) |value| {
            std.mem.writeInt(i32, self.data[self.length..][0..4], @intCast(value.len), .big);
            self.length += 4;
            @memcpy(self.data[self.length..][0..value.len], value);
            self.length += value.len;
        }
        std.mem.writeInt(u32, self.data[1..5], @intCast(self.length - 1), .big);
    }

    fn rows(self: *Fixture) uz.sql.Rows {
        return .{ .data = self.data[0..self.length], .columns = &self.columns, .fields = &self.fields };
    }
};

test "sql arena: renderer preserves JSON tags booleans integers and escaping" {
    var fixture = Fixture{};
    fixture.row("\x01[\"new\", \"quote\\\"tag\", \"\\u732b\"]");
    var output: [2048]u8 = undefined;
    const body = try arena.render(&output, fixture.rows(), 50);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), object.get("count").?.integer);
    const item = object.get("items").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 42), item.get("id").?.integer);
    try std.testing.expectEqualStrings("quoted \"name\"", item.get("name").?.string);
    try std.testing.expectEqualStrings("\xe7\x8c\xab", item.get("category").?.string);
    try std.testing.expect(item.get("active").?.bool);
    try std.testing.expectEqual(@as(i64, 30), item.get("price").?.integer);
    try std.testing.expectEqual(@as(i64, 5), item.get("quantity").?.integer);
    try std.testing.expectEqual(@as(i64, 41), item.get("rating").?.object.get("score").?.integer);
    try std.testing.expectEqualStrings("quote\"tag", item.get("tags").?.array.items[1].string);
    try std.testing.expectEqualStrings("\xe7\x8c\xab", item.get("tags").?.array.items[2].string);
}

test "sql arena: renderer rejects malformed or injected JSONB and bounds output" {
    var fixture = Fixture{};
    var output: [2048]u8 = undefined;
    const invalid = [_][]const u8{
        "\x02[]", "\x01{}", "\x01[true]", "\x01[\"x\",]", "\x01[\"x\"]},\"count\":1", "\x01[\"\\x\"]", "\x01[\"unterminated]", "\x01[\"\\uZZZZ\"]", "\x01[\"\xff\"]", "\x01[\"\x01\"]",
    };
    for (invalid) |tags| {
        fixture.row(tags);
        try std.testing.expectError(error.InvalidTags, arena.render(&output, fixture.rows(), 50));
    }
    fixture.row("\x01[]");
    fixture.columns[6].oid = 25;
    try std.testing.expectError(error.InvalidTags, arena.render(&output, fixture.rows(), 50));
    fixture.columns[6].oid = 3802;
    try std.testing.expectError(error.InvalidResult, arena.render(&output, fixture.rows(), 0));
    try std.testing.expectError(error.WriteFailed, arena.render(output[0..8], fixture.rows(), 50));
    fixture.length = 0;
    try std.testing.expectEqualStrings("{\"items\":[],\"count\":0}", try arena.render(&output, fixture.rows(), 50));
}

const DelayCapture = struct {
    timer_calls: usize = 0,
    completions: usize = 0,
    milliseconds: u64 = 0,
    status: []const u8 = "",
    body: []const u8 = "",

    fn complete(context: *anyopaque, status: []const u8, _: []const u8, body: []const u8) !void {
        const capture: *DelayCapture = @ptrCast(@alignCast(context));
        capture.completions += 1;
        capture.status = status;
        capture.body = body;
    }

    fn wake(_: *anyopaque) void {}

    fn sleep(context: *anyopaque, milliseconds: u64, _: uz.AsyncResponse, status: []const u8, _: []const u8, body: []const u8) void {
        const capture: *DelayCapture = @ptrCast(@alignCast(context));
        capture.timer_calls += 1;
        capture.milliseconds = milliseconds;
        capture.status = status;
        capture.body = body;
    }
};

test "sql arena: healthy overload returns503 while an unavailable DB uses empty fallback" {
    const context = try std.testing.allocator.create(arena.Context);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{ .user = "test", .database = "test", .allow_plaintext = true });
    defer context.sql.db.deinit();
    var request = uz.Request{};
    var state = uz.AsyncResponseState{};
    var capture = DelayCapture{};
    var token = state.arm(.{ .context = &capture, .complete_fn = DelayCapture.complete, .wake_fn = DelayCapture.wake });
    arena.Context.handler(context, &request, token);
    try std.testing.expectEqualStrings("200 OK", capture.status);
    try std.testing.expectEqualStrings("{\"items\":[],\"count\":0}", capture.body);
    try std.testing.expectEqual(@as(u64, 1), context.empty_fallbacks);

    context.sql.db.started = true;
    for (0..context.sql.db.config.connections) |index| try context.sql.db.pool.mark_ready(index);
    context.free_count = 0;
    capture = .{};
    token = state.arm(.{ .context = &capture, .complete_fn = DelayCapture.complete, .wake_fn = DelayCapture.wake });
    arena.Context.handler(context, &request, token);
    try std.testing.expectEqualStrings("503 Service Unavailable", capture.status);
    try std.testing.expectEqual(@as(u64, 1), context.empty_fallbacks);
    try std.testing.expectEqual(@as(u64, 1), context.rejected_responses);
}

test "sql arena: delay reads each path value and retains canonical borrowed digits" {
    const cases = [_][]const u8{ "0", "00037", "19", "-1", "1x", "60001", "" };
    for (cases, 0..) |raw, index| {
        var request = uz.Request{};
        try request.add_param("ms", raw);
        var state = uz.AsyncResponseState{};
        var capture = DelayCapture{};
        const token = state.arm(.{ .context = &capture, .complete_fn = DelayCapture.complete, .wake_fn = DelayCapture.wake, .sleep_complete_fn = DelayCapture.sleep });
        arena.delay(&request, token);
        if (index == 0) {
            try std.testing.expectEqualStrings("0", capture.body);
            try std.testing.expectEqual(@as(usize, 1), capture.completions);
            continue;
        }
        if (index < 3) {
            try std.testing.expectEqual(@as(usize, 1), capture.timer_calls);
            try std.testing.expectEqual(@as(usize, 0), capture.completions);
            try std.testing.expectEqual(if (index == 1) @as(u64, 37) else @as(u64, 19), capture.milliseconds);
            try std.testing.expectEqualStrings(if (index == 1) "37" else "19", capture.body);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), capture.timer_calls);
        try std.testing.expectEqualStrings("400 Bad Request", capture.status);
    }
}
