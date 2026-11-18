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

/// Planned inputs remain independent of execution order and returned values.
const UpdateChunk = struct {
    rows: Chunk = .{},
    params: [batch_capacity / 2]sql.Param = undefined,
    updates: [batch_capacity / 2]example.UpdateParameters = undefined,
    order: [batch_capacity / 2]usize = undefined,
    statements: [batch_capacity]sql.BoundStatement = undefined,

    fn prepare(self: *UpdateChunk, ids: []const i32) ![]const sql.BoundStatement {
        for (ids, 0..) |id, index| {
            self.params[index] = .{ .value = .{ .int4 = id } };
            self.updates[index] = .{
                .{ .value = .{ .int4 = @intCast(100 + index) } },
                .{ .value = .{ .int4 = id } },
            };
        }
        return example.prepare_update_chunk(self.params[0..ids.len], self.updates[0..ids.len], &self.order, &self.statements);
    }

    fn results(self: *UpdateChunk, count: usize, first_ordinal: usize) void {
        for (self.order[0..count], 0..) |original, index| {
            const id = self.params[original].value.int4;
            const number: i32 = @intCast(1000 + first_ordinal + original);
            self.updates[original][0].value = .{ .int4 = number };
            self.rows.set(index * 2, id, @intCast(50 + original));
            self.rows.set(index * 2 + 1, id, number);
        }
    }
};

test "sql postgres: update pairs use stable ID lock order and preserve bound storage" {
    var chunk: UpdateChunk = .{};
    const operations = try chunk.prepare(&.{ 4, 2, 4, 1, 2, 1, 3, 3 });
    try std.testing.expectEqual(batch_capacity, operations.len);
    try std.testing.expectEqualSlices(usize, &.{ 3, 5, 1, 4, 6, 7, 0, 2 }, &chunk.order);
    for (chunk.order, 0..) |original, index| {
        const select = operations[index * 2];
        const update = operations[index * 2 + 1];
        try std.testing.expectEqualStrings("SELECT id, randomnumber FROM World WHERE id=$1", select.statement.sql);
        try std.testing.expectEqualStrings("UPDATE World SET randomnumber=$1 WHERE id=$2 RETURNING id,randomnumber", update.statement.sql);
        try std.testing.expectEqual(@as(usize, 1), select.params.len);
        try std.testing.expectEqual(@as(usize, 2), update.params.len);
        try std.testing.expectEqual(chunk.params[original].value.int4, select.params[0].value.int4);
        try std.testing.expectEqual(chunk.params[original].value.int4, update.params[1].value.int4);
        try std.testing.expectEqual(@as(i32, @intCast(100 + original)), update.params[0].value.int4);
        try std.testing.expect(select.params.ptr == chunk.params[original..][0..1].ptr);
        try std.testing.expect(update.params.ptr == chunk.updates[original][0..].ptr);
    }
    var ascending: UpdateChunk = .{};
    var descending: UpdateChunk = .{};
    const first = try ascending.prepare(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const second = try descending.prepare(&.{ 8, 7, 6, 5, 4, 3, 2, 1 });
    for (0..batch_capacity / 2) |index| {
        try std.testing.expectEqual(first[index * 2].params[0].value.int4, second[index * 2].params[0].value.int4);
        try std.testing.expectEqual(first[index * 2 + 1].params[1].value.int4, second[index * 2 + 1].params[1].value.int4);
    }
    _ = try chunk.prepare(&.{ 7, 1, 6, 2, 5, 3, 4 });
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 5, 6, 4, 2, 0 }, chunk.order[0..7]);
    _ = try chunk.prepare(&.{ 3, 1, 4, 2 });
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 0, 2 }, chunk.order[0..4]);
    const short_first = try ascending.prepare(&.{ 1, 2, 3, 4 });
    const short_second = try descending.prepare(&.{ 4, 3, 2, 1 });
    for (0..4) |index| {
        try std.testing.expectEqual(short_first[index * 2 + 1].params[1].value.int4, short_second[index * 2 + 1].params[1].value.int4);
    }
}

test "sql postgres: update chunks retain every pair duplicate and original output position" {
    for ([_]usize{ 1, 7, 8, 9, 20, 500 }) |count| {
        var chunk: UpdateChunk = .{};
        var output: [500 * 48 + 2]u8 = undefined;
        output[0] = '[';
        var length: usize = 1;
        var completed: usize = 0;
        var statements: usize = 0;
        var ids: [batch_capacity / 2]i32 = undefined;
        while (completed < count) {
            const take: usize = @min(count - completed, batch_capacity / 2);
            for (ids[0..take], 0..) |*id, index| id.* = @intCast((completed + index) % 5 + 1);
            statements += (try chunk.prepare(ids[0..take])).len;
            chunk.results(take, completed);
            length = try example.append_update_chunk(&output, length, chunk.params[0..take], chunk.updates[0..take], chunk.order[0..take], chunk.rows.results[0 .. take * 2]);
            @memset(std.mem.asBytes(&chunk.rows.data), 0xa5);
            completed += take;
        }
        try std.testing.expectEqual(count * 2, statements);
        output[length] = ']';
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output[0 .. length + 1], .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        try std.testing.expectEqual(count, items.len);
        for (items, 0..) |item, index| {
            try std.testing.expectEqual(@as(usize, 2), item.object.count());
            try std.testing.expectEqual(@as(i64, @intCast(index % 5 + 1)), item.object.get("id").?.integer);
            try std.testing.expectEqual(@as(i64, @intCast(index + 1000)), item.object.get("randomNumber").?.integer);
        }
    }
}

test "sql postgres: update preparation rejects mismatched parameters and bounded storage" {
    var chunk: UpdateChunk = .{};
    _ = try chunk.prepare(&.{ 2, 1 });
    try std.testing.expectError(error.InvalidResult, example.prepare_update_chunk(&.{}, &.{}, &chunk.order, &chunk.statements));
    try std.testing.expectError(error.InvalidResult, example.prepare_update_chunk(chunk.params[0..2], chunk.updates[0..1], &chunk.order, &chunk.statements));
    try std.testing.expectError(error.BufferTooSmall, example.prepare_update_chunk(chunk.params[0..2], chunk.updates[0..2], chunk.order[0..1], &chunk.statements));
    try std.testing.expectError(error.BufferTooSmall, example.prepare_update_chunk(chunk.params[0..2], chunk.updates[0..2], &chunk.order, chunk.statements[0..3]));
    chunk.updates[1][1].value = .{ .int4 = 3 };
    try std.testing.expectError(error.InvalidResult, example.prepare_update_chunk(chunk.params[0..2], chunk.updates[0..2], &chunk.order, &chunk.statements));
    chunk.updates[1][1].value = .{ .int4 = 1 };
    chunk.updates[1][0].value = .{ .bool = true };
    try std.testing.expectError(error.TypeMismatch, example.prepare_update_chunk(chunk.params[0..2], chunk.updates[0..2], &chunk.order, &chunk.statements));
}

test "sql postgres: update chunks reject missing extra and wrongly associated results" {
    var chunk: UpdateChunk = .{};
    _ = try chunk.prepare(&.{ 2, 1 });
    chunk.results(2, 0);
    var output: [256]u8 = undefined;
    output[0] = '[';
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..3]));
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..1], chunk.updates[0..1], chunk.order[0..1], chunk.rows.results[0..4]));
    chunk.rows.results[0].rows.data = &.{};
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.results(2, 0);
    chunk.rows.results[1].rows.data = &.{};
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.results(2, 0);
    chunk.rows.set(0, 999, 51);
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.results(2, 0);
    chunk.rows.set(1, 999, 1001);
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.results(2, 0);
    chunk.rows.set(1, chunk.params[chunk.order[0]].value.int4, 9999);
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.results(2, 0);
    @memcpy(chunk.rows.data[1][23..46], chunk.rows.data[1][0..23]);
    chunk.rows.results[1].rows.data = &chunk.rows.data[1];
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
}

test "sql postgres: update result validation rejects bad permutations types and output space" {
    var chunk: UpdateChunk = .{};
    _ = try chunk.prepare(&.{ 2, 1 });
    chunk.results(2, 0);
    var output: [256]u8 = undefined;
    output[0] = '[';
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], &.{ 0, 0 }, chunk.rows.results[0..4]));
    try std.testing.expectError(error.InvalidResult, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], &.{ 1, 2 }, chunk.rows.results[0..4]));
    var bad_update_columns = chunk.rows.columns;
    bad_update_columns[1].oid = 17;
    chunk.rows.results[1].rows.columns = &bad_update_columns;
    try std.testing.expectError(error.TypeMismatch, example.append_update_chunk(&output, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
    chunk.rows.results[1].rows.columns = &chunk.rows.columns;
    var short = [_]u8{'['};
    try std.testing.expectError(error.BufferTooSmall, example.append_update_chunk(&short, 1, chunk.params[0..2], chunk.updates[0..2], chunk.order[0..2], chunk.rows.results[0..4]));
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
    updates: bool = false,
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
            const original = if (self.updates) slot.update_order[index / 2] else index;
            if (id != slot.chunk_params[original].value.int4) return error.InvalidValue;
            if (number != self.expected_number(original, index)) return error.InvalidValue;
            if (try rows.next() != null) return error.InvalidMessage;
            self.rows += 1;
        }
    }

    fn expected_number(self: *const CancelCapture, original: usize, result_index: usize) i32 {
        const slot = &self.context.slots[self.slot_index];
        const id = slot.chunk_params[original].value.int4;
        if (!self.updates) return @mod(id * 17, 10000) + 1;
        if (result_index % 2 == 1) return slot.update_params[original][0].value.int4;
        var number = @mod(id * 17, 10000) + 1;
        for (slot.update_order[0 .. result_index / 2]) |previous| {
            if (slot.chunk_params[previous].value.int4 == id) number = slot.update_params[previous][0].value.int4;
        }
        return number;
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
    try check_cancelled_chunk(false);
}

test "sql postgres: update token cancellation preserves the successful first chunk only" {
    try check_cancelled_chunk(true);
}

fn check_cancelled_chunk(updates: bool) !void {
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
    }, if (updates) 644 else 19);
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
        errdefer {
            // Keep callback storage alive until an incomplete seed request drains.
            context.sql.db.stop();
            scheduler.stop(&loop);
            loop.xev_loop.run(.until_done) catch @panic("seed fixture did not drain");
        }
        try context.sql.db.query_on(lease, &request);
        const deadline = scheduler.current_time_ms() + 5000;
        while (capture.calls == 0) {
            if (scheduler.current_time_ms() >= deadline) return error.TestQueryTimeout;
            try loop.xev_loop.run(.once);
        }
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
        try context.sql.db.release(lease);
    }
    var capture: CancelCapture = .{ .context = context, .updates = updates };
    context.sql.db.diagnostics = .{ .trace_context = &capture, .trace = CancelCapture.trace };
    var state: support.http_response.AsyncResponseState = .{};
    const token = state.arm(.{ .context = &capture, .complete_fn = CancelCapture.complete, .wake_fn = CancelCapture.wake });
    var request: support.Request = .{ .method = "GET", .path = if (updates) "/updates" else "/queries", .query = "count=500" };
    const free_before = context.free_count;
    example.Context.handler(context, &request, token);
    try std.testing.expectEqual(free_before - 1, context.free_count);
    capture.slot_index = context.free_indices[context.free_count];
    const slot = &context.slots[capture.slot_index];
    capture.connection_index = slot.request.lease.?.index;
    const deadline = slot.request.deadline_ms;
    try std.testing.expectEqual(batch_capacity, slot.request.batch.len);
    if (updates) try std.testing.expectEqual(slot.chunk_params[2].value.int4, slot.chunk_params[7].value.int4);
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
    if (updates) try check_persisted_chunk(context, &loop, &scheduler, capture.slot_index, capture.connection_index);
}

/// Reads the same backend's TEMP World without relying on pool reuse order.
fn check_persisted_chunk(context: *example.Context, loop: *support.loop.Loop, scheduler: *support.timer.Scheduler, slot_index: usize, connection_index: usize) !void {
    var leases: [8]sql.Lease = undefined;
    var selected: ?sql.Lease = null;
    for (&leases) |*lease| {
        lease.* = try context.sql.db.acquire();
        if (lease.index == connection_index) selected = lease.*;
    }
    const slot = &context.slots[slot_index];
    const target = selected orelse return error.TestMissingLease;
    for (slot.chunk_params[0..slot.chunk_count], 0..) |param, index| {
        const id = param.value.int4;
        var last = index;
        for (index + 1..slot.chunk_count) |next| {
            if (slot.chunk_params[next].value.int4 == id) last = next;
        }
        var capture: sql_fixture.QueryCapture = .{};
        var request = sql_fixture.request("SELECT randomnumber FROM World WHERE id=$1", &capture);
        request.statement.name = "persisted_update";
        request.params = slot.chunk_params[index..][0..1];
        errdefer {
            // Request and capture must remain alive while failure cleanup delivers callbacks.
            context.sql.db.stop();
            scheduler.stop(loop);
            loop.xev_loop.run(.until_done) catch @panic("persistence fixture did not drain");
        }
        try context.sql.db.query_on(target, &request);
        const deadline = scheduler.current_time_ms() + 5000;
        while (capture.calls == 0) {
            if (scheduler.current_time_ms() >= deadline) return error.TestQueryTimeout;
            try loop.xev_loop.run(.once);
        }
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
        try std.testing.expectEqual(@as(usize, 1), capture.rows);
        try std.testing.expectEqual(@as(i64, slot.update_params[last][0].value.int4), capture.integer);
    }
    for (leases) |lease| try context.sql.db.release(lease);
    try std.testing.expectEqual(@as(usize, 0), context.sql.db.pool.stats().active);
}

/// Callback-owned JSON proves real result validation before the response slab changes.
const LockChunkCapture = struct {
    chunk: *UpdateChunk,
    count: usize,
    calls: usize = 0,
    results: usize = 0,
    failure: ?anyerror = null,
    output: [512]u8 = undefined,
    output_len: usize = 0,

    fn complete(context: *anyopaque, outcome: sql.QueryOutcome) void {
        const self: *LockChunkCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        const result = switch (outcome) {
            .failure => |failure| {
                self.failure = failure;
                return;
            },
            .success => |result| result,
        };
        self.results = result.results.len;
        self.output[0] = '[';
        self.output_len = example.append_update_chunk(&self.output, 1, self.chunk.params[0..self.count], self.chunk.updates[0..self.count], self.chunk.order[0..self.count], result.results) catch |err| {
            self.failure = err;
            return;
        };
        self.output[self.output_len] = ']';
        self.output_len += 1;
    }
};

test "sql postgres: opposing update chunks contend in stable full and short lock order" {
    var live = try sql_fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    const control = try live.db.acquire();
    const first = try live.db.acquire();
    const second = try live.db.acquire();
    const control_pid = live.db.connections[control.index].backend_pid;
    const first_pid = live.db.connections[first.index].backend_pid;
    const second_pid = live.db.connections[second.index].backend_pid;
    var text: [4096]u8 = undefined;
    const setup = try std.fmt.bufPrint(
        &text,
        "CREATE SCHEMA uwz_update_lock_{d}; " ++
            "CREATE TABLE uwz_update_lock_{d}.world (id INTEGER PRIMARY KEY, randomnumber INTEGER NOT NULL); " ++
            "INSERT INTO uwz_update_lock_{d}.world SELECT id,id*17 FROM generate_series(1,4) id; " ++
            "CREATE TABLE uwz_update_lock_{d}.audit (ordinal BIGSERIAL, id INTEGER, number INTEGER, transaction_id BIGINT); " ++
            "CREATE FUNCTION uwz_update_lock_{d}.after_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN " ++
            "PERFORM pg_advisory_xact_lock({d},42); " ++
            "INSERT INTO uwz_update_lock_{d}.audit(id,number,transaction_id) VALUES(NEW.id,NEW.randomnumber,txid_current()); " ++
            "RETURN NEW; END $$; " ++
            "CREATE TRIGGER wait_first_update AFTER UPDATE ON uwz_update_lock_{d}.world " ++
            "FOR EACH ROW EXECUTE FUNCTION uwz_update_lock_{d}.after_update()",
        .{ control_pid, control_pid, control_pid, control_pid, control_pid, control_pid, control_pid, control_pid, control_pid },
    );
    _ = try run_lock_control(&live, control, setup);
    var cleanup_attempted = false;
    defer if (!cleanup_attempted) {
        // Preserve the first test error and identify any objects a failed fixture cannot clean.
        cleanup_lock_schema(&live, control, control_pid) catch |err| {
            std.log.err("owned schema uwz_update_lock_{d} cleanup failed: {s}", .{ control_pid, @errorName(err) });
        };
    };
    const search_path = try std.fmt.bufPrint(&text, "SET search_path TO uwz_update_lock_{d},pg_catalog", .{control_pid});
    _ = try run_lock_control(&live, first, search_path);
    _ = try run_lock_control(&live, second, search_path);
    try check_opposing_lock_chunks(&live, control, first, second, control_pid, first_pid, second_pid, 4);
    _ = try run_lock_control(&live, control, try std.fmt.bufPrint(&text, "TRUNCATE uwz_update_lock_{d}.audit", .{control_pid}));
    try check_opposing_lock_chunks(&live, control, first, second, control_pid, first_pid, second_pid, 8);
    cleanup_attempted = true;
    try cleanup_lock_schema(&live, control, control_pid);
    try live.db.release(second);
    try live.db.release(first);
    try live.db.release(control);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().active);
}

/// Every local query and capture stays alive through error-path callback delivery.
fn run_lock_control(live: *sql_fixture.LiveDb, lease: sql.Lease, text: []const u8) !sql_fixture.QueryCapture {
    var capture: sql_fixture.QueryCapture = .{};
    var request = sql_fixture.request(text, &capture);
    request.mode = .migration;
    request.deadline_ms = live.scheduler.current_time_ms() + 5000;
    errdefer {
        if (request.state != .idle) stop_lock_fixture(live);
    }
    try live.db.query_on(lease, &request);
    try live.wait(&capture);
    if (capture.failure) |failure| return failure;
    return capture;
}

fn check_opposing_lock_chunks(live: *sql_fixture.LiveDb, control: sql.Lease, first: sql.Lease, second: sql.Lease, control_pid: u32, first_pid: u32, second_pid: u32, count: usize) !void {
    var chunks: [2]UpdateChunk = .{ .{}, .{} };
    const first_ids: []const i32 = if (count == 4) &.{ 3, 1, 4, 2 } else &.{ 4, 2, 4, 1, 2, 1, 3, 3 };
    const second_ids: []const i32 = if (count == 4) &.{ 2, 4, 1, 3 } else &.{ 3, 3, 1, 2, 1, 4, 2, 4 };
    var captures: [2]LockChunkCapture = .{
        .{ .chunk = &chunks[0], .count = count },
        .{ .chunk = &chunks[1], .count = count },
    };
    var requests: [2]sql.Query = undefined;
    const deadline = live.scheduler.current_time_ms() + 10_000;
    requests[0] = .{ .statement = .{ .name = "", .sql = "" }, .batch = try chunks[0].prepare(first_ids), .deadline_ms = deadline, .context = &captures[0], .callback = LockChunkCapture.complete };
    requests[1] = .{ .statement = .{ .name = "", .sql = "" }, .batch = try chunks[1].prepare(second_ids), .deadline_ms = deadline, .context = &captures[1], .callback = LockChunkCapture.complete };
    for (chunks[1].updates[0..count], 0..) |*params, index| params[0].value = .{ .int4 = @intCast(200 + index) };
    var text: [1024]u8 = undefined;
    _ = try run_lock_control(live, control, try std.fmt.bufPrint(&text, "SELECT 1 FROM pg_advisory_lock({d},42)", .{control_pid}));
    var barrier_held = true;
    // Preserve the first error while keeping every pending callback's storage alive.
    defer {
        if (barrier_held) {
            _ = run_lock_control(live, control, "SELECT 1 FROM pg_advisory_unlock_all()") catch |err| blk: {
                std.log.err("update lock barrier cleanup failed: {s}", .{@errorName(err)});
                stop_lock_fixture(live);
                break :blk sql_fixture.QueryCapture{};
            };
        }
        while (requests[0].state != .idle or requests[1].state != .idle) {
            if (live.scheduler.current_time_ms() >= deadline + 1000) {
                stop_lock_fixture(live);
                break;
            }
            live.loop.xev_loop.run(.once) catch {
                stop_lock_fixture(live);
                break;
            };
        }
    }
    try live.db.query_on(first, &requests[0]);
    try live.db.query_on(second, &requests[1]);
    const wait_deadline = live.scheduler.current_time_ms() + 5000;
    while (true) {
        const waiting = try run_lock_control(live, control, try std.fmt.bufPrint(
            &text,
            "SELECT count(*) FROM pg_stat_activity WHERE pid IN ({d},{d}) AND state='active' AND wait_event_type='Lock'",
            .{ first_pid, second_pid },
        ));
        if (waiting.integer == 2) break;
        if (live.scheduler.current_time_ms() >= wait_deadline) return error.TestLockWaitTimeout;
    }
    const advisory = try run_lock_control(live, control, try std.fmt.bufPrint(
        &text,
        "SELECT count(*) FROM pg_stat_activity WHERE pid IN ({d},{d}) AND wait_event='advisory'",
        .{ first_pid, second_pid },
    ));
    try std.testing.expectEqual(@as(i64, 1), advisory.integer);
    try std.testing.expectEqual(@as(usize, 0), captures[0].calls + captures[1].calls);
    _ = try run_lock_control(live, control, "SELECT 1 FROM pg_advisory_unlock_all()");
    barrier_held = false;
    while (captures[0].calls == 0 or captures[1].calls == 0) {
        if (live.scheduler.current_time_ms() >= deadline) return error.TestQueryTimeout;
        try live.loop.xev_loop.run(.once);
    }
    for (&captures, &requests) |*capture, *request| {
        try std.testing.expectEqual(@as(?anyerror, null), capture.failure);
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expectEqual(count * 2, capture.results);
        try std.testing.expectEqual(deadline, request.deadline_ms);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.output[0..capture.output_len], .{});
        defer parsed.deinit();
        try std.testing.expectEqual(count, parsed.value.array.items.len);
        for (parsed.value.array.items, 0..) |item, original| {
            try std.testing.expectEqual(@as(i64, capture.chunk.params[original].value.int4), item.object.get("id").?.integer);
            try std.testing.expectEqual(@as(i64, capture.chunk.updates[original][0].value.int4), item.object.get("randomNumber").?.integer);
        }
    }
    const writes = try run_lock_control(live, control, try std.fmt.bufPrint(&text, "SELECT count(*) FROM uwz_update_lock_{d}.audit", .{control_pid}));
    try std.testing.expectEqual(@as(i64, @intCast(count * 2)), writes.integer);
    const transactions = try run_lock_control(live, control, try std.fmt.bufPrint(&text, "SELECT count(DISTINCT transaction_id) FROM uwz_update_lock_{d}.audit", .{control_pid}));
    try std.testing.expectEqual(@as(i64, 2), transactions.integer);
    const inversions = try run_lock_control(live, control, try std.fmt.bufPrint(
        &text,
        "SELECT count(*) FROM (SELECT id,lag(id) OVER (PARTITION BY transaction_id ORDER BY ordinal) AS previous FROM uwz_update_lock_{d}.audit) ordered WHERE id<previous",
        .{control_pid},
    ));
    try std.testing.expectEqual(@as(i64, 0), inversions.integer);
    const mismatches = try run_lock_control(live, control, try std.fmt.bufPrint(
        &text,
        "SELECT count(*) FROM uwz_update_lock_{d}.world w JOIN " ++
            "(SELECT DISTINCT ON(id) id,number FROM uwz_update_lock_{d}.audit ORDER BY id,ordinal DESC) last_write USING(id) " ++
            "WHERE w.randomnumber<>last_write.number",
        .{ control_pid, control_pid },
    ));
    try std.testing.expectEqual(@as(i64, 0), mismatches.integer);
}

fn stop_lock_fixture(live: *sql_fixture.LiveDb) void {
    live.db.stop();
    live.scheduler.stop(&live.loop);
    live.loop.xev_loop.run(.until_done) catch @panic("lock fixture did not drain");
}

/// Recovery uses a fresh owned connection if an I/O error closed the test Db.
fn cleanup_lock_schema(live: *sql_fixture.LiveDb, control: sql.Lease, schema_pid: u32) !void {
    var text: [1024]u8 = undefined;
    const cleanup = try std.fmt.bufPrint(
        &text,
        "DROP TRIGGER wait_first_update ON uwz_update_lock_{d}.world; " ++
            "DROP FUNCTION uwz_update_lock_{d}.after_update(); " ++
            "DROP TABLE uwz_update_lock_{d}.audit; DROP TABLE uwz_update_lock_{d}.world; " ++
            "DROP SCHEMA uwz_update_lock_{d}",
        .{ schema_pid, schema_pid, schema_pid, schema_pid, schema_pid },
    );
    const valid_lease = blk: {
        live.db.pool.validate(control) catch break :blk false;
        break :blk true;
    };
    if (live.db.ready() and valid_lease) {
        _ = try run_lock_control(live, control, cleanup);
        return;
    }
    var recovery = try sql_fixture.LiveDb.init();
    defer recovery.deinit();
    try recovery.start();
    const lease = try recovery.db.acquire();
    _ = try run_lock_control(&recovery, lease, cleanup);
    try recovery.db.release(lease);
}
