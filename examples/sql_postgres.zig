//! Apply examples/sql/world.sql before starting this HttpArena-compatible server.
const std = @import("std");
const uz = @import("uWebZockets");
pub const configuration = @import("sql_config.zig");
const log = std.log.scoped(.sql_example);
const capacity = 128;
const max_count = 500;
const query_chunk_capacity = uz.sql.runtime_types.max_batch_statements;
const update_chunk_capacity = query_chunk_capacity / 2;
const output_bytes = max_count * 48 + 2;
const App = uz.ConfiguredAppWithTimeout(capacity, 1024, 64 * 1024, 120_000);

const Operation = enum { single, queries, updates };

/// UPDATE value and ID borrow slot-owned storage until the chunk reaches Sync.
pub const UpdateParameters = [2]uz.sql.Param;

/// Scalar copies survive reordering and response-slab reuse.
const WorldValue = struct { id: i32, number: i32 };

const Slot = struct {
    owner: *Context = undefined,
    index: usize = 0,
    token: uz.AsyncResponse = undefined,
    request: uz.sql.Query = undefined,
    params: [1]uz.sql.Param = undefined,
    chunk_params: [query_chunk_capacity]uz.sql.Param = undefined,
    chunk_statements: [query_chunk_capacity]uz.sql.BoundStatement = undefined,
    update_params: [update_chunk_capacity]UpdateParameters = undefined,
    update_order: [update_chunk_capacity]usize = undefined,
    output: [output_bytes]u8 = undefined,
    output_len: usize = 0,
    remaining: usize = 0,
    chunk_count: usize = 0,
    operation: Operation = .single,
    active: bool = false,
};

pub const Context = struct {
    sql: uz.sql.Sql,
    random: std.Random.DefaultPrng,
    slots: [capacity]Slot = undefined,
    free_indices: [capacity]usize = undefined,
    free_count: usize = capacity,

    pub fn init(self: *Context, allocator: std.mem.Allocator, config: uz.sql.Config, seed: u64) !void {
        self.* = .{ .sql = try uz.sql.Sql.init(allocator, config), .random = std.Random.DefaultPrng.init(seed) };
        for (&self.slots, 0..) |*slot, index| {
            slot.* = .{ .owner = self, .index = index };
            self.free_indices[index] = index;
        }
    }

    pub fn handler(context: *anyopaque, request: *uz.Request, token: uz.AsyncResponse) void {
        const self: *Context = @ptrCast(@alignCast(context));
        if (!self.sql.db.ready() or self.free_count == 0) {
            complete(token, "503 Service Unavailable", "{\"error\":\"SQL capacity unavailable\"}");
            return;
        }
        self.free_count -= 1;
        const slot = &self.slots[self.free_indices[self.free_count]];
        slot.active = true;
        slot.token = token;
        slot.operation = if (std.mem.eql(u8, request.path, "/db")) .single else if (std.mem.eql(u8, request.path, "/queries")) .queries else .updates;
        slot.remaining = if (slot.operation == .single) 1 else parse_count(request.query);
        slot.output_len = 0;
        if (slot.operation != .single) {
            slot.output[0] = '[';
            slot.output_len = 1;
        }
        slot.request = .{
            .statement = .{ .name = "world_select", .sql = "SELECT id, randomnumber FROM World WHERE id=$1", .param_oids = &.{23} },
            .deadline_ms = self.sql.db.scheduler.?.current_time_ms() +| 10_000,
            .context = slot,
            .callback = on_query,
        };
        (switch (slot.operation) {
            .single => start_select(slot),
            .queries => start_queries(slot),
            .updates => start_updates(slot),
        }) catch fail(slot);
    }

    fn start_select(slot: *Slot) uz.sql.RuntimeError!void {
        slot.params[0] = .{ .value = .{ .int4 = slot.owner.random.random().intRangeAtMost(i32, 1, 10000) } };
        slot.request.statement = .{ .name = "world_select", .sql = "SELECT id, randomnumber FROM World WHERE id=$1", .param_oids = &.{23} };
        slot.request.params = slot.params[0..1];
        try slot.owner.sql.db.query(&slot.request);
    }

    fn start_queries(slot: *Slot) uz.sql.RuntimeError!void {
        slot.chunk_count = @min(slot.remaining, query_chunk_capacity);
        for (0..slot.chunk_count) |index| {
            slot.chunk_params[index] = .{ .value = .{ .int4 = slot.owner.random.random().intRangeAtMost(i32, 1, 10000) } };
            slot.chunk_statements[index] = .{
                .statement = .{ .name = "world_select", .sql = "SELECT id, randomnumber FROM World WHERE id=$1", .param_oids = &.{23} },
                .params = slot.chunk_params[index..][0..1],
            };
        }
        slot.request.params = &.{};
        slot.request.batch = &.{};
        if (slot.chunk_count == 1) {
            slot.request.params = slot.chunk_params[0..1];
        } else slot.request.batch = slot.chunk_statements[0..slot.chunk_count];
        try slot.owner.sql.db.query(&slot.request);
    }

    fn start_updates(slot: *Slot) uz.sql.RuntimeError!void {
        slot.chunk_count = @min(slot.remaining, update_chunk_capacity);
        for (0..slot.chunk_count) |index| {
            const id = slot.owner.random.random().intRangeAtMost(i32, 1, 10000);
            const number = slot.owner.random.random().intRangeAtMost(i32, 1, 10000);
            slot.chunk_params[index] = .{ .value = .{ .int4 = id } };
            slot.update_params[index] = .{
                .{ .value = .{ .int4 = number } },
                .{ .value = .{ .int4 = id } },
            };
        }
        slot.request.params = &.{};
        // Slot bounds and generated parameter types are fixed by this example.
        slot.request.batch = prepare_update_chunk(slot.chunk_params[0..slot.chunk_count], slot.update_params[0..slot.chunk_count], &slot.update_order, &slot.chunk_statements) catch return error.InvalidConfiguration;
        try slot.owner.sql.db.query(&slot.request);
    }

    fn on_query(context: *anyopaque, outcome: uz.sql.QueryOutcome) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        if (!slot.token.is_pending()) {
            release(slot);
            return;
        }
        const result = switch (outcome) {
            .success => |result| result,
            .failure => {
                fail(slot);
                return;
            },
        };
        if (slot.operation == .queries) {
            on_query_chunk(slot, result);
            return;
        }
        if (slot.operation == .updates) {
            on_update_chunk(slot, result);
            return;
        }
        var rows = result.rows;
        const row = (rows.next() catch {
            fail(slot);
            return;
        }) orelse {
            fail(slot);
            return;
        };
        const id = row.get(i32, 0) catch {
            fail(slot);
            return;
        };
        const number = row.get(i32, 1) catch {
            fail(slot);
            return;
        };
        append_world(slot, id, number) catch {
            fail(slot);
            return;
        };
        slot.remaining -= 1;
        complete(slot.token, "200 OK", slot.output[0..slot.output_len]);
        release(slot);
    }

    fn on_query_chunk(slot: *Slot, result: uz.sql.QueryResult) void {
        slot.output_len = append_query_chunk(slot.output[0..], slot.output_len, slot.chunk_params[0..slot.chunk_count], result.results) catch {
            fail(slot);
            return;
        };
        slot.remaining -= slot.chunk_count;
        if (slot.remaining != 0) {
            start_queries(slot) catch fail(slot);
            return;
        }
        slot.output[slot.output_len] = ']';
        slot.output_len += 1;
        complete(slot.token, "200 OK", slot.output[0..slot.output_len]);
        release(slot);
    }

    fn on_update_chunk(slot: *Slot, result: uz.sql.QueryResult) void {
        slot.output_len = append_update_chunk(&slot.output, slot.output_len, slot.chunk_params[0..slot.chunk_count], slot.update_params[0..slot.chunk_count], slot.update_order[0..slot.chunk_count], result.results) catch {
            fail(slot);
            return;
        };
        slot.remaining -= slot.chunk_count;
        if (slot.remaining != 0) {
            start_updates(slot) catch fail(slot);
            return;
        }
        slot.output[slot.output_len] = ']';
        slot.output_len += 1;
        complete(slot.token, "200 OK", slot.output[0..slot.output_len]);
        release(slot);
    }

    fn append_world(slot: *Slot, id: i32, number: i32) !void {
        const separator = if (slot.output_len > 1 and slot.operation != .single) "," else "";
        const text = try std.fmt.bufPrint(slot.output[slot.output_len..], "{s}{{\"id\":{d},\"randomNumber\":{d}}}", .{ separator, id, number });
        slot.output_len += text.len;
    }

    fn fail(slot: *Slot) void {
        complete(slot.token, "503 Service Unavailable", "{\"error\":\"SQL operation failed\"}");
        release(slot);
    }

    fn release(slot: *Slot) void {
        std.debug.assert(slot.active);
        slot.active = false;
        const owner = slot.owner;
        owner.free_indices[owner.free_count] = slot.index;
        owner.free_count += 1;
    }
};

/// Builds at most eight SELECT/UPDATE pairs in stable row-lock order.
pub fn prepare_update_chunk(params: []const uz.sql.Param, updates: []const UpdateParameters, order: []usize, statements: []uz.sql.BoundStatement) QueryChunkError![]const uz.sql.BoundStatement {
    if (params.len == 0 or params.len > update_chunk_capacity or updates.len != params.len) return error.InvalidResult;
    if (order.len < params.len or statements.len < params.len * 2) return error.BufferTooSmall;
    for (params, updates, 0..) |param, update, index| {
        const id = switch (param.value) {
            .int4 => |value| value,
            else => return error.TypeMismatch,
        };
        if (update[0].value != .int4 or update[1].value != .int4) return error.TypeMismatch;
        if (update[1].value.int4 != id) return error.InvalidResult;
        order[index] = index;
    }
    var index: usize = 1;
    while (index < params.len) : (index += 1) {
        const original = order[index];
        var cursor = index;
        while (cursor > 0 and params[order[cursor - 1]].value.int4 > params[original].value.int4) : (cursor -= 1) {
            order[cursor] = order[cursor - 1];
        }
        order[cursor] = original;
    }
    for (order[0..params.len], 0..) |original, position| {
        statements[position * 2] = .{
            .statement = .{ .name = "world_select", .sql = "SELECT id, randomnumber FROM World WHERE id=$1", .param_oids = &.{23} },
            .params = params[original..][0..1],
        };
        statements[position * 2 + 1] = .{
            .statement = .{ .name = "world_update", .sql = "UPDATE World SET randomnumber=$1 WHERE id=$2 RETURNING id,randomnumber", .param_oids = &.{ 23, 23 } },
            .params = &updates[original],
        };
    }
    return statements[0 .. params.len * 2];
}

/// Copies actual UPDATE results into original request order before rendering.
pub fn append_update_chunk(output: []u8, output_len: usize, params: []const uz.sql.Param, updates: []const UpdateParameters, order: []const usize, results: []const uz.sql.ResultSet) QueryChunkError!usize {
    if (params.len == 0 or params.len > update_chunk_capacity) return error.InvalidResult;
    if (updates.len != params.len or order.len != params.len or results.len != params.len * 2) return error.InvalidResult;
    if (output_len >= output.len) return error.BufferTooSmall;
    if (output_len == 0 or output[0] != '[') return error.InvalidResult;
    var values: [update_chunk_capacity]WorldValue = undefined;
    var seen: u16 = 0;
    for (order, 0..) |original, index| {
        if (original >= params.len) return error.InvalidResult;
        const bit = @as(u16, 1) << @as(u4, @intCast(original));
        if (seen & bit != 0) return error.InvalidResult;
        seen |= bit;
        const id = switch (params[original].value) {
            .int4 => |value| value,
            else => return error.TypeMismatch,
        };
        const number = switch (updates[original][0].value) {
            .int4 => |value| value,
            else => return error.TypeMismatch,
        };
        if (updates[original][1].value != .int4) return error.TypeMismatch;
        if (updates[original][1].value.int4 != id) return error.InvalidResult;
        _ = try read_world(results[index * 2].rows, id);
        values[original] = try read_world(results[index * 2 + 1].rows, id);
        if (values[original].number != number) return error.InvalidResult;
    }
    var length = output_len;
    for (values[0..params.len]) |value| {
        const separator = if (length > 1) "," else "";
        const text = std.fmt.bufPrint(output[length .. output.len - 1], "{s}{{\"id\":{d},\"randomNumber\":{d}}}", .{ separator, value.id, value.number }) catch return error.BufferTooSmall;
        length += text.len;
    }
    return length;
}

fn read_world(source: uz.sql.Rows, expected_id: i32) QueryChunkError!WorldValue {
    var rows = source;
    const row = (try rows.next()) orelse return error.InvalidResult;
    if (row.fields.len != 2) return error.InvalidResult;
    const value: WorldValue = .{ .id = try row.get(i32, 0), .number = try row.get(i32, 1) };
    if (value.id != expected_id or try rows.next() != null) return error.InvalidResult;
    return value;
}

/// Appends exactly one typed row per bound ID, retaining space for array closure.
pub fn append_query_chunk(output: []u8, output_len: usize, params: []const uz.sql.Param, results: []const uz.sql.ResultSet) QueryChunkError!usize {
    if (params.len == 0 or params.len > query_chunk_capacity or results.len != params.len) return error.InvalidResult;
    if (output_len >= output.len) return error.BufferTooSmall;
    if (output_len == 0 or output[0] != '[') return error.InvalidResult;
    var length = output_len;
    for (params, results) |param, result| {
        const expected_id = switch (param.value) {
            .int4 => |id| id,
            else => return error.TypeMismatch,
        };
        var rows = result.rows;
        const row = (try rows.next()) orelse return error.InvalidResult;
        if (row.fields.len != 2) return error.InvalidResult;
        const id = try row.get(i32, 0);
        const number = try row.get(i32, 1);
        if (id != expected_id or try rows.next() != null) return error.InvalidResult;
        const separator = if (length > 1) "," else "";
        const text = std.fmt.bufPrint(output[length .. output.len - 1], "{s}{{\"id\":{d},\"randomNumber\":{d}}}", .{ separator, id, number }) catch return error.BufferTooSmall;
        length += text.len;
    }
    return length;
}

/// Chunk bounds include row cardinality, wire and scalar validation.
pub const QueryChunkError = uz.sql.SqlError || error{InvalidResult};

fn parse_count(query: []const u8) usize {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], "count")) continue;
        const raw = pair[equals + 1 ..];
        if (raw.len == 0 or raw[0] == '-') return 1;
        var value: usize = 0;
        for (raw) |digit| {
            if (!std.ascii.isDigit(digit)) return 1;
            value = @min(max_count, value * 10 + digit - '0');
        }
        return @max(value, 1);
    }
    return 1;
}

fn complete(token: uz.AsyncResponse, status: []const u8, body: []const u8) void {
    if (!token.is_pending()) return;
    token.complete_with_headers(status, "Content-Type: application/json\r\n", body) catch |err| {
        log.debug("SQL example response failed: {s}", .{@errorName(err)});
    };
}

pub fn main(init: std.process.Init) !void {
    const context = try init.gpa.create(Context);
    defer init.gpa.destroy(context);
    var seed: [8]u8 = undefined;
    try std.Io.randomSecure(init.io, &seed);
    try context.init(init.gpa, try configuration.load(init), std.mem.readInt(u64, &seed, .little));
    var app = App.init(init.io) catch |err| {
        context.sql.db.deinit();
        return err;
    };
    app.provide(context.sql.hooks()) catch |err| {
        app.deinit();
        context.sql.db.deinit();
        return err;
    };
    defer app.deinit();
    _ = try app.get_async_context("/db", context, Context.handler);
    _ = try app.get_async_context("/queries", context, Context.handler);
    _ = try app.get_async_context("/updates", context, Context.handler);
    try app.listen("127.0.0.1", try configuration.http_port(init));
    try app.catch_shutdown_signals();
    try app.run();
}
