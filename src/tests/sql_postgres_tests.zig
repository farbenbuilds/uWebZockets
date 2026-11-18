const std = @import("std");
const example = @import("sql_postgres");
const support = @import("test_support");
const sql = support.sql;
const sql_fixture = @import("sql_test_support.zig");
const batch_capacity = sql.runtime_types.max_batch_statements;

/// Each result retains independent wire bytes while sharing iteration scratch.
const Chunk = struct {
    columns: [2]sql.types.Column = .{
        .{ .name = "id", .oid = 23, .format = .binary },
        .{ .name = "randomnumber", .oid = 23, .format = .binary },
    },
    fields: [2]sql.types.Field = undefined,
    data: [batch_capacity][46]u8 = undefined,
    params: [batch_capacity]sql.Param = undefined,
    results: [batch_capacity]sql.ResultSet = undefined,

    fn set(self: *Chunk, index: usize, id: i32, number: i32) void {
        const bytes = &self.data[index];
        bytes[0] = 'D';
        std.mem.writeInt(u32, bytes[1..5], 22, .big);
        std.mem.writeInt(u16, bytes[5..7], 2, .big);
        std.mem.writeInt(i32, bytes[7..11], 4, .big);
        std.mem.writeInt(i32, bytes[11..15], id, .big);
        std.mem.writeInt(i32, bytes[15..19], 4, .big);
        std.mem.writeInt(i32, bytes[19..23], number, .big);
        self.params[index] = .{ .value = .{ .int4 = id } };
        self.results[index] = .{
            .rows = .{ .data = bytes[0..23], .columns = &self.columns, .fields = &self.fields },
            .command_tag = "SELECT 1",
        };
    }
};

test "sql postgres: bounded query chunks preserve counts duplicates and scalar order" {
    const counts = [_]usize{ 1, 15, 16, 17, 20, 500 };
    for (counts) |count| {
        var chunk: Chunk = .{};
        var output: [500 * 48 + 2]u8 = undefined;
        output[0] = '[';
        var length: usize = 1;
        var completed: usize = 0;
        while (completed < count) {
            const take = @min(count - completed, batch_capacity);
            for (0..take) |index| {
                const ordinal = completed + index;
                chunk.set(index, @intCast(ordinal % 3 + 1), @intCast(ordinal + 1000));
            }
            length = try example.append_query_chunk(&output, length, chunk.params[0..take], chunk.results[0..take]);
            @memset(std.mem.asBytes(&chunk.data), 0xa5);
            completed += take;
        }
        output[length] = ']';
        length += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output[0..length], .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        try std.testing.expectEqual(count, items.len);
        for (items, 0..) |item, index| {
            try std.testing.expectEqual(@as(usize, 2), item.object.count());
            try std.testing.expectEqual(@as(i64, @intCast(index % 3 + 1)), item.object.get("id").?.integer);
            try std.testing.expectEqual(@as(i64, @intCast(index + 1000)), item.object.get("randomNumber").?.integer);
        }
    }
}

test "sql postgres: query chunks reject missing extra and oversized result sets" {
    var chunk: Chunk = .{};
    chunk.set(0, 7, 19);
    chunk.set(1, 9, 21);
    var output: [256]u8 = undefined;
    output[0] = '[';
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, chunk.params[0..1], &.{}));
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..2]));
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, &.{}, &.{}));
    const too_many_params = [_]sql.Param{.{ .value = .{ .int4 = 1 } }} ** (batch_capacity + 1);
    var too_many_results: [batch_capacity + 1]sql.ResultSet = undefined;
    @memset(&too_many_results, chunk.results[0]);
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, &too_many_params, &too_many_results));
}

test "sql postgres: every bound query requires exactly one matching row" {
    var chunk: Chunk = .{};
    chunk.set(0, 7, 19);
    chunk.set(1, 9, 21);
    var output: [256]u8 = undefined;
    output[0] = '[';
    chunk.results[1].rows.data = &.{};
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, chunk.params[0..2], chunk.results[0..2]));
    chunk.set(1, 9, 21);
    @memcpy(chunk.data[1][23..46], chunk.data[1][0..23]);
    chunk.results[1].rows.data = &chunk.data[1];
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, chunk.params[0..2], chunk.results[0..2]));
    chunk.set(1, 9, 21);
    chunk.params[1].value = .{ .int4 = 8 };
    try std.testing.expectError(error.InvalidResult, example.append_query_chunk(&output, 1, chunk.params[0..2], chunk.results[0..2]));
}

test "sql postgres: query chunk values retain exact SQL scalar types and widths" {
    var chunk: Chunk = .{};
    chunk.set(0, 7, 19);
    var output: [256]u8 = undefined;
    output[0] = '[';
    chunk.columns[1].oid = 25;
    try std.testing.expectError(error.TypeMismatch, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..1]));
    chunk.columns[1].oid = 23;
    std.mem.writeInt(i32, chunk.data[0][15..19], -1, .big);
    std.mem.writeInt(u32, chunk.data[0][1..5], 18, .big);
    chunk.results[0].rows.data = chunk.data[0][0..19];
    try std.testing.expectError(error.NullValue, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..1]));
    chunk.set(0, 7, 19);
    std.mem.writeInt(i32, chunk.data[0][15..19], 3, .big);
    std.mem.writeInt(u32, chunk.data[0][1..5], 21, .big);
    chunk.results[0].rows.data = chunk.data[0][0..22];
    try std.testing.expectError(error.InvalidValue, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..1]));
    chunk.set(0, 7, 19);
    chunk.params[0].value = .{ .bool = true };
    try std.testing.expectError(error.TypeMismatch, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..1]));
}

test "sql postgres: query chunks reject malformed wire data and reserve array closure" {
    var chunk: Chunk = .{};
    chunk.set(0, 7, 19);
    var output: [256]u8 = undefined;
    output[0] = '[';
    chunk.results[0].rows.data = chunk.data[0][0..22];
    try std.testing.expectError(error.TruncatedMessage, example.append_query_chunk(&output, 1, chunk.params[0..1], chunk.results[0..1]));
    chunk.set(0, 7, 19);
    var short = [_]u8{'['};
    try std.testing.expectError(error.BufferTooSmall, example.append_query_chunk(&short, 1, chunk.params[0..1], chunk.results[0..1]));
    const expected = "[{\"id\":7,\"randomNumber\":19}]";
    var exact: [expected.len]u8 = undefined;
    exact[0] = '[';
    const length = try example.append_query_chunk(&exact, 1, chunk.params[0..1], chunk.results[0..1]);
    try std.testing.expectEqual(exact.len - 1, length);
    exact[length] = ']';
    try std.testing.expectEqualStrings(expected, &exact);
    try std.testing.expectError(error.BufferTooSmall, example.append_query_chunk(exact[0 .. exact.len - 1], 1, chunk.params[0..1], chunk.results[0..1]));
}

/// Copies scalars in the synchronous end trace, before the owning query callback.
const CancelCapture = struct {
    context: *example.Context,
    slot_index: usize = 0,
    connection_index: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    completes: usize = 0,
    wakes: usize = 0,
    results: usize = 0,
    rows: usize = 0,
    failure: ?sql.RuntimeError = null,

    fn trace(context: *anyopaque, event: sql.TraceEvent) void {
        const self: *CancelCapture = @ptrCast(@alignCast(context));
        if (event.phase == .begin) {
            self.begins += 1;
            return;
        }
        self.ends += 1;
        self.failure = event.failure;
        if (self.failure != null) return;
        self.validate() catch |err| {
            self.failure = err;
        };
    }

    fn validate(self: *CancelCapture) sql.RuntimeError!void {
        const connection = &self.context.sql.db.connections[self.connection_index];
        const slot = &self.context.slots[self.slot_index];
        self.results = connection.result_count;
        if (self.results != batch_capacity) return error.InvalidMessage;
        for (connection.result_sets[0..self.results], 0..) |result, index| {
            var rows = result.rows;
            const row = (try rows.next()) orelse return error.InvalidMessage;
            const id = try row.get(i32, 0);
            const number = try row.get(i32, 1);
            if (id != slot.chunk_params[index].value.int4) return error.InvalidValue;
            if (number != @mod(id * 17, 10000) + 1) return error.InvalidValue;
            if (try rows.next() != null) return error.InvalidMessage;
            self.rows += 1;
        }
    }

    fn complete(context: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
        const self: *CancelCapture = @ptrCast(@alignCast(context));
        self.completes += 1;
    }

    fn wake(context: *anyopaque) void {
        const self: *CancelCapture = @ptrCast(@alignCast(context));
        self.wakes += 1;
    }
};

test "sql postgres: observed stale token releases a successful chunk without continuation" {
    const password = try sql_fixture.required_env("UWZ_SQL_TEST_PASSWORD");
    defer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    const port_text = try sql_fixture.env("UWZ_SQL_TEST_PORT");
    defer if (port_text) |text| std.testing.allocator.free(text);
    const port = try std.fmt.parseInt(u16, port_text orelse "55432", 10);
    var loop = try support.loop.init();
    defer support.loop.deinit(&loop);
    var scheduler = try support.timer.Scheduler.init(std.testing.io);
    defer scheduler.deinit();
    const context = try std.testing.allocator.create(example.Context);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{
        .user = "uwz_test",
        .database = "uwz_test",
        .password = password,
        .port = port,
        .allow_plaintext = true,
        .connections = 8,
        .limits = .{ .max_rows = 512, .max_message_bytes = 64 * 1024, .max_response_bytes = 128 * 1024 },
    }, 19);
    defer context.sql.db.deinit();
    scheduler.start(&loop);
    defer {
        context.sql.db.stop();
        scheduler.stop(&loop);
        loop.xev_loop.run(.until_done) catch @panic("query cancellation fixture did not drain");
    }
    try context.sql.db.start(&loop, &scheduler, std.testing.io, 0);
    const startup_deadline = scheduler.current_time_ms() + 5000;
    while (!context.sql.db.ready()) {
        if (context.sql.db.startup_failure) |failure| return failure;
        if (scheduler.current_time_ms() >= startup_deadline) return error.TestStartupTimeout;
        try loop.xev_loop.run(.once);
    }
    var leases: [8]sql.Lease = undefined;
    for (&leases) |*lease| lease.* = try context.sql.db.acquire();
    for (leases) |lease| {
        var capture: sql_fixture.QueryCapture = .{};
        var request = sql_fixture.request(
            "CREATE TEMP TABLE World (id INTEGER PRIMARY KEY, randomnumber INTEGER NOT NULL); " ++
                "INSERT INTO World SELECT id, (id*17)%10000+1 FROM generate_series(1,10000) id",
            &capture,
        );
        request.mode = .migration;
        try context.sql.db.query_on(lease, &request);
        const deadline = scheduler.current_time_ms() + 5000;
        while (capture.calls == 0) {
            if (scheduler.current_time_ms() >= deadline) return error.TestQueryTimeout;
            try loop.xev_loop.run(.once);
        }
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
        try context.sql.db.release(lease);
    }
    var capture: CancelCapture = .{ .context = context };
    context.sql.db.diagnostics = .{ .trace_context = &capture, .trace = CancelCapture.trace };
    var state: support.http_response.AsyncResponseState = .{};
    const token = state.arm(.{ .context = &capture, .complete_fn = CancelCapture.complete, .wake_fn = CancelCapture.wake });
    var request: support.Request = .{ .method = "GET", .path = "/queries", .query = "count=500" };
    const free_before = context.free_count;
    example.Context.handler(context, &request, token);
    try std.testing.expectEqual(free_before - 1, context.free_count);
    capture.slot_index = context.free_indices[context.free_count];
    const slot = &context.slots[capture.slot_index];
    capture.connection_index = slot.request.lease.?.index;
    const deadline = slot.request.deadline_ms;
    try std.testing.expectEqual(batch_capacity, slot.request.batch.len);
    try std.testing.expectEqual(@as(usize, 1), capture.begins);
    state.cancel();
    try std.testing.expect(!token.is_pending());
    const wait_deadline = scheduler.current_time_ms() + 5000;
    while (context.free_count != free_before) {
        if (scheduler.current_time_ms() >= wait_deadline) return error.TestQueryTimeout;
        try loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(usize, 1), capture.begins);
    try std.testing.expectEqual(@as(usize, 1), capture.ends);
    try std.testing.expectEqual(batch_capacity, capture.results);
    try std.testing.expectEqual(batch_capacity, capture.rows);
    try std.testing.expectEqual(@as(usize, 0), capture.completes);
    try std.testing.expectEqual(@as(usize, 0), capture.wakes);
    try std.testing.expectEqual(@as(usize, 500), slot.remaining);
    try std.testing.expectEqual(@as(usize, 1), slot.output_len);
    try std.testing.expectEqual(deadline, slot.request.deadline_ms);
    try std.testing.expect(!slot.active);
    try std.testing.expectEqual(@as(usize, 0), context.sql.db.pool.stats().active);
    try std.testing.expectEqual(@as(u64, 0), context.sql.db.cancel_requests);
    context.sql.db.diagnostics = .{};
}
