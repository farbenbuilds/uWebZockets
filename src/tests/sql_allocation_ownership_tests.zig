const std = @import("std");
const support = @import("test_support");
const sql = support.sql;
const fixture = @import("sql_test_support.zig");
const example = @import("sql_postgres");

/// Records attempts before denial, including errors consumed by the caller.
const Attempts = struct { alloc: usize = 0, resize: usize = 0, remap: usize = 0, free: usize = 0 };

/// Successful parent ownership must match address, length and alignment at free.
const Allocation = struct {
    address: usize = 0,
    length: usize = 0,
    alignment: std.mem.Alignment = .@"1",
    freed: bool = false,
};

/// Only the allocator supplied to Db is observed; alternate and C allocators are excluded.
const SuppliedAllocator = struct {
    parent: std.mem.Allocator = std.testing.allocator,
    total: Attempts = .{},
    window: Attempts = .{},
    allocations: [8]Allocation = [_]Allocation{.{}} ** 8,
    count: usize = 0,
    armed: bool = false,

    const vtable: std.mem.Allocator.VTable = .{ .alloc = allocate, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *SuppliedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn arm(self: *SuppliedAllocator) void {
        self.window = .{};
        self.armed = true;
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *SuppliedAllocator = @ptrCast(@alignCast(context));
        self.total.alloc += 1;
        if (self.armed) {
            self.window.alloc += 1;
            return null;
        }
        const memory = self.parent.rawAlloc(length, alignment, address) orelse return null;
        std.debug.assert(self.count < self.allocations.len);
        self.allocations[self.count] = .{ .address = @intFromPtr(memory), .length = length, .alignment = alignment };
        self.count += 1;
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *SuppliedAllocator = @ptrCast(@alignCast(context));
        self.total.resize += 1;
        if (self.armed) {
            self.window.resize += 1;
            return false;
        }
        const index = self.record(memory, alignment);
        if (!self.parent.rawResize(memory, alignment, length, address)) return false;
        self.allocations[index].length = length;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        const self: *SuppliedAllocator = @ptrCast(@alignCast(context));
        self.total.remap += 1;
        if (self.armed) {
            self.window.remap += 1;
            return null;
        }
        const index = self.record(memory, alignment);
        const mapped = self.parent.rawRemap(memory, alignment, length, address) orelse return null;
        self.allocations[index].address = @intFromPtr(mapped);
        self.allocations[index].length = length;
        return mapped;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *SuppliedAllocator = @ptrCast(@alignCast(context));
        self.total.free += 1;
        if (self.armed) self.window.free += 1;
        self.allocations[self.record(memory, alignment)].freed = true;
        self.parent.rawFree(memory, alignment, address);
    }

    fn record(self: *const SuppliedAllocator, memory: []u8, alignment: std.mem.Alignment) usize {
        for (self.allocations[0..self.count], 0..) |allocation, index| {
            if (allocation.freed or allocation.address != @intFromPtr(memory.ptr)) continue;
            std.debug.assert(allocation.length == memory.len and allocation.alignment == alignment);
            return index;
        }
        @panic("allocator operation did not match live supplied ownership");
    }
};

test "sql allocation ownership: armed counters detect swallowed denied attempts and frees" {
    var supplied: SuppliedAllocator = .{};
    const allocator = supplied.allocator();
    const memory = try allocator.alloc(u8, 32);
    defer if (!supplied.allocations[0].freed) allocator.free(memory);
    supplied.arm();
    swallow_denial(allocator);
    try std.testing.expect(!allocator.rawResize(memory, .@"1", 64, @returnAddress()));
    try std.testing.expectEqual(@as(?[*]u8, null), allocator.rawRemap(memory, .@"1", 64, @returnAddress()));
    try std.testing.expectEqual(Attempts{ .alloc = 1, .resize = 1, .remap = 1 }, supplied.window);
    allocator.free(memory);
    try std.testing.expectEqual(@as(usize, 1), supplied.window.free);
    try std.testing.expectEqual(@as(usize, 1), supplied.count);
    try std.testing.expect(supplied.allocations[0].freed);
}

fn swallow_denial(allocator: std.mem.Allocator) void {
    // This positive control intentionally consumes OOM; the counter must still see it.
    const memory = allocator.alloc(u8, 8) catch return;
    allocator.free(memory);
}

test "sql allocation ownership: startup owns exactly three allocations with matching frees" {
    var supplied: SuppliedAllocator = .{};
    {
        var db = try sql.Db.init(supplied.allocator(), test_config("", 5432));
        defer db.deinit();
        try expect_startup(&supplied, &db);
    }
    try expect_released(&supplied);
}

fn test_config(password: []const u8, port: u16) sql.Config {
    return .{
        .user = "uwz_test",
        .database = "uwz_test",
        .password = password,
        .port = port,
        .allow_plaintext = true,
        .wait_capacity = 2,
        .limits = .{ .max_message_bytes = 64 * 1024, .max_response_bytes = 128 * 1024, .max_rows = 512 },
    };
}

fn expect_startup(supplied: *const SuppliedAllocator, db: *const sql.Db) !void {
    try std.testing.expectEqual(Attempts{ .alloc = 3 }, supplied.total);
    try std.testing.expectEqual(@as(usize, 3), supplied.count);
    try std.testing.expectEqual(@intFromPtr(db.connections.ptr), supplied.allocations[0].address);
    try std.testing.expectEqual(@intFromPtr(db.cancel_connections.ptr), supplied.allocations[1].address);
    try std.testing.expectEqual(@intFromPtr(db.slabs.ptr), supplied.allocations[2].address);
    try std.testing.expectEqual(db.connections.len * @sizeOf(sql.connection.Connection), supplied.allocations[0].length);
    try std.testing.expectEqual(db.cancel_connections.len * @sizeOf(sql.connection.Connection), supplied.allocations[1].length);
    try std.testing.expectEqual(db.slabs.len, supplied.allocations[2].length);
}

fn expect_released(supplied: *const SuppliedAllocator) !void {
    try std.testing.expectEqual(@as(usize, 3), supplied.count);
    try std.testing.expectEqual(@as(usize, 3), supplied.total.free);
    for (supplied.allocations[0..supplied.count]) |allocation| try std.testing.expect(allocation.freed);
}

/// Addresses and byte capacities exclude mutable query contents and socket handles.
const BufferGeometry = struct { address: usize, bytes: usize };
const ConnectionGeometry = struct {
    record: usize,
    receive: BufferGeometry,
    response: BufferGeometry,
    transmit: BufferGeometry,
    fixed: [11]BufferGeometry,
};
const DbGeometry = struct {
    main_records: BufferGeometry,
    auxiliary_records: BufferGeometry,
    slab: BufferGeometry,
    pool_slots: BufferGeometry,
    pool_waiters: BufferGeometry,
    main: [8]ConnectionGeometry,
    auxiliary: [8]ConnectionGeometry,
};

fn buffer_geometry(bytes: []const u8) BufferGeometry {
    return .{ .address = @intFromPtr(bytes.ptr), .bytes = bytes.len };
}

fn connection_geometry(connection: *const sql.connection.Connection) ConnectionGeometry {
    return .{
        .record = @intFromPtr(connection),
        .receive = buffer_geometry(connection.receive),
        .response = buffer_geometry(connection.response),
        .transmit = buffer_geometry(connection.transmit),
        .fixed = .{
            buffer_geometry(std.mem.asBytes(&connection.columns)),
            buffer_geometry(std.mem.asBytes(&connection.fields)),
            buffer_geometry(&connection.column_names),
            buffer_geometry(std.mem.asBytes(&connection.result_sets)),
            buffer_geometry(std.mem.asBytes(&connection.result_tags)),
            buffer_geometry(std.mem.asBytes(&connection.cache)),
            buffer_geometry(std.mem.asBytes(&connection.cache_reserved)),
            buffer_geometry(std.mem.asBytes(&connection.parsed_cache)),
            buffer_geometry(&connection.read_buffer),
            buffer_geometry(&connection.command_tag),
            buffer_geometry(&connection.auth_output),
        },
    };
}

fn db_geometry(db: *const sql.Db) DbGeometry {
    std.debug.assert(db.connections.len == 8 and db.cancel_connections.len == 8);
    var geometry: DbGeometry = .{
        .main_records = buffer_geometry(std.mem.sliceAsBytes(db.connections)),
        .auxiliary_records = buffer_geometry(std.mem.sliceAsBytes(db.cancel_connections)),
        .slab = buffer_geometry(db.slabs),
        .pool_slots = buffer_geometry(std.mem.asBytes(&db.pool.slots)),
        .pool_waiters = buffer_geometry(std.mem.asBytes(&db.pool.waiters)),
        .main = undefined,
        .auxiliary = undefined,
    };
    for (db.connections, db.cancel_connections, 0..) |*connection, *auxiliary, index| {
        geometry.main[index] = connection_geometry(connection);
        geometry.auxiliary[index] = connection_geometry(auxiliary);
    }
    return geometry;
}

fn expect_window(supplied: *const SuppliedAllocator, db: *const sql.Db, before: *const DbGeometry) !void {
    try std.testing.expectEqual(Attempts{}, supplied.window);
    try std.testing.expectEqualDeep(before.*, db_geometry(db));
}

const FixtureInputs = struct { password: []u8, port: u16 };

fn fixture_inputs() !FixtureInputs {
    const password = try fixture.required_env("UWZ_SQL_TEST_PASSWORD");
    errdefer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    const port = try fixture.env("UWZ_SQL_TEST_PORT");
    defer if (port) |text| std.testing.allocator.free(text);
    return .{ .password = password, .port = try std.fmt.parseInt(u16, port orelse "55432", 10) };
}

fn init_live(allocator: std.mem.Allocator, config: sql.Config) !fixture.LiveDb {
    var loop = try support.loop.init();
    errdefer support.loop.deinit(&loop);
    var scheduler = try support.timer.Scheduler.init(std.testing.io);
    errdefer scheduler.deinit();
    return .{ .db = try sql.Db.init(allocator, config), .loop = loop, .scheduler = scheduler };
}

fn drain(live: *fixture.LiveDb) void {
    live.db.stop();
    live.scheduler.stop(&live.loop);
    live.loop.xev_loop.run(.until_done) catch @panic("allocation ownership callbacks did not drain");
}

/// A pending request cannot outlive its caller's query/capture on any error path.
fn run_query(live: *fixture.LiveDb, lease: ?sql.Lease, query: *sql.Query, capture: *const fixture.QueryCapture) !void {
    errdefer if (query.state != .idle) drain(live);
    if (lease) |pinned| try live.db.query_on(pinned, query) else try live.db.query(query);
    try live.wait(capture);
}

test "sql allocation ownership: plaintext query queue cancellation and reconnect reuse startup storage" {
    const inputs = try fixture_inputs();
    defer {
        std.crypto.secureZero(u8, inputs.password);
        std.testing.allocator.free(inputs.password);
    }
    var supplied: SuppliedAllocator = .{};
    var live = try init_live(supplied.allocator(), test_config(inputs.password, inputs.port));
    defer expect_released(&supplied) catch @panic("Db allocations did not match their frees");
    defer live.deinit();
    try live.start();
    try expect_startup(&supplied, &live.db);
    const before = db_geometry(&live.db);
    supplied.arm();
    try check_named_and_kept(&live);
    try expect_window(&supplied, &live.db, &before);
    try check_middle_error(&live);
    try expect_window(&supplied, &live.db, &before);
    try check_waiting_requests(&live);
    try expect_window(&supplied, &live.db, &before);
    try check_running_cancel(&live, false);
    try expect_window(&supplied, &live.db, &before);
    try check_running_cancel(&live, true);
    try expect_window(&supplied, &live.db, &before);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().active);
    drain(&live);
    try std.testing.expect(live.db.drained());
    try expect_window(&supplied, &live.db, &before);
    supplied.armed = false;
}

/// Keeps independently typed fields while later results overwrite shared row scratch.
const KeptCapture = struct {
    calls: usize = 0,
    failure: ?sql.RuntimeError = null,
    fields: [2]sql.types.Field = undefined,
    bytes: [128]u8 = undefined,
    kept: ?sql.Row = null,
    results: usize = 0,
    second: i64 = 0,

    fn complete(context: *anyopaque, outcome: sql.QueryOutcome) void {
        const self: *KeptCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        const result = switch (outcome) {
            .failure => |failure| {
                self.failure = failure;
                return;
            },
            .success => |result| result,
        };
        self.capture(result) catch |err| {
            self.failure = err;
        };
    }

    fn capture(self: *KeptCapture, result: sql.QueryResult) sql.RuntimeError!void {
        self.results = result.results.len;
        if (self.results != 2) return error.InvalidMessage;
        var first = result.results[0].rows;
        const row = (try first.next()) orelse return error.InvalidMessage;
        self.kept = try row.keep(&self.fields, &self.bytes);
        if (try first.next() != null) return error.InvalidMessage;
        var second = result.results[1].rows;
        const next = (try second.next()) orelse return error.InvalidMessage;
        self.second = try next.get(i64, 0);
        if (try second.next() != null) return error.InvalidMessage;
    }
};

fn check_named_and_kept(live: *fixture.LiveDb) !void {
    errdefer drain(live);
    const lease = try live.db.acquire();
    const parameters = [_]sql.Param{.{ .value = .{ .int4 = 42 } }};
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("SELECT $1::int4", &capture);
    query.statement.name = "allocation_number";
    query.params = &parameters;
    try run_query(live, lease, &query, &capture);
    try expect_scalar(&capture, 42);
    try std.testing.expectEqual(@as(usize, 1), live.db.connections[lease.index].parse_count);
    capture = .{};
    query.deadline_ms = 0;
    try run_query(live, lease, &query, &capture);
    try expect_scalar(&capture, 42);
    try std.testing.expectEqual(@as(usize, 0), live.db.connections[lease.index].parse_count);
    const operations = [_]sql.BoundStatement{
        .{ .statement = .{ .name = "allocation_kept", .sql = "SELECT 7::int4,'caller retained'::text" } },
        .{ .statement = .{ .name = "allocation_big", .sql = "SELECT 1234567890123::int8" } },
    };
    var kept: KeptCapture = .{};
    query = .{ .statement = .{ .name = "", .sql = "" }, .batch = &operations, .context = &kept, .callback = KeptCapture.complete };
    try live.db.query_on(lease, &query);
    const deadline = live.scheduler.current_time_ms() + 5000;
    while (kept.calls == 0) {
        if (live.scheduler.current_time_ms() >= deadline) return error.QueryCompletionTimeout;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), kept.failure);
    try std.testing.expectEqual(@as(usize, 1), kept.calls);
    try std.testing.expectEqual(@as(usize, 2), kept.results);
    try std.testing.expectEqual(@as(i64, 1234567890123), kept.second);
    for (0..2) |_| {
        capture = .{};
        query = fixture.request("SELECT 'replacement overwrites earlier response bytes'::text", &capture);
        try run_query(live, lease, &query, &capture);
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expectEqual(@as(usize, 1), capture.rows);
        try std.testing.expectEqualStrings("replacement overwrites earlier response bytes", capture.text[0..capture.text_len]);
        try std.testing.expectEqual(@as(usize, 1), live.db.connections[lease.index].parse_count);
    }
    const row = kept.kept orelse return error.MissingRetainedRow;
    try std.testing.expect(row.fields.ptr == kept.fields[0..].ptr);
    try std.testing.expectEqual(@as(i32, 7), try row.get(i32, 0));
    try std.testing.expectEqualStrings("caller retained", try row.get([]const u8, 1));
    try live.db.release(lease);
}

fn expect_scalar(capture: *const fixture.QueryCapture, value: i64) !void {
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(usize, 1), capture.rows);
    try std.testing.expectEqual(value, capture.integer);
}

fn check_middle_error(live: *fixture.LiveDb) !void {
    errdefer drain(live);
    const lease = try live.db.acquire();
    const operations = [_]sql.BoundStatement{
        .{ .statement = .{ .name = "", .sql = "SELECT 1::int4" } },
        .{ .statement = .{ .name = "", .sql = "SELECT absent_allocation_column" } },
        .{ .statement = .{ .name = "", .sql = "SELECT 3::int4" } },
    };
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("", &capture);
    query.batch = &operations;
    try run_query(live, lease, &query, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.ServerError), capture.failure);
    try std.testing.expectEqual(@as(u8, 'I'), live.db.connections[lease.index].transaction_status);
    capture = .{};
    query = fixture.request("SELECT 42::int4", &capture);
    try run_query(live, lease, &query, &capture);
    try expect_scalar(&capture, 42);
    try live.db.release(lease);
}

fn check_waiting_requests(live: *fixture.LiveDb) !void {
    var captures: [3]fixture.QueryCapture = .{ .{}, .{}, .{} };
    var queries: [3]sql.Query = undefined;
    for (&queries, &captures) |*query, *capture| query.* = fixture.request("SELECT 1::int4", capture);
    errdefer drain(live);
    var leases: [8]sql.Lease = undefined;
    for (&leases) |*lease| lease.* = try live.db.acquire();
    queries[0].deadline_ms = live.scheduler.current_time_ms() + 2000;
    queries[1].deadline_ms = live.scheduler.current_time_ms() + 50;
    try live.db.query(&queries[0]);
    try live.db.query(&queries[1]);
    try std.testing.expectEqual(@as(usize, 2), live.db.pool.stats().waiting);
    try std.testing.expectError(error.PoolExhausted, live.db.query(&queries[2]));
    try std.testing.expectEqual(@as(usize, 0), captures[2].calls);
    try live.db.cancel(&queries[0]);
    try std.testing.expectEqual(@as(usize, 1), captures[0].calls);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.Canceled), captures[0].failure);
    try live.wait(&captures[1]);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.AcquireTimeout), captures[1].failure);
    try std.testing.expectEqual(@as(usize, 1), captures[1].calls);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().waiting);
    for (leases) |lease| try live.db.release(lease);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().active);
}

fn check_running_cancel(live: *fixture.LiveDb, timeout: bool) !void {
    var sleeper: fixture.QueryCapture = .{};
    var query = fixture.request("SELECT 1 FROM pg_sleep(5)", &sleeper);
    errdefer drain(live);
    query.deadline_ms = live.scheduler.current_time_ms() + (if (timeout) @as(u64, 1500) else 10_000);
    const cancel_before = live.db.cancel_requests;
    const reconnect_before = live.db.pool.stats().reconnects;
    try live.db.query(&query);
    const index = query.lease.?.index;
    const backend_pid = live.db.connections[index].backend_pid;
    const control = try live.db.acquire();
    const parameters = [_]sql.Param{.{ .value = .{ .int4 = @intCast(backend_pid) } }};
    var observation: fixture.QueryCapture = .{};
    var observer = fixture.request("SELECT count(*) FROM pg_stat_activity WHERE pid=$1 AND wait_event='PgSleep'", &observation);
    observer.params = &parameters;
    const observed_deadline = live.scheduler.current_time_ms() + 1000;
    while (true) {
        observation = .{};
        observer.deadline_ms = 0;
        try run_query(live, control, &observer, &observation);
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), observation.failure);
        if (observation.integer == 1) {
            try expect_scalar(&observation, 1);
            break;
        }
        if (live.scheduler.current_time_ms() >= observed_deadline) return error.SleepNotObserved;
    }
    if (!timeout) try live.db.cancel(&query);
    try live.wait(&sleeper);
    try std.testing.expectEqual(@as(usize, 1), sleeper.calls);
    try std.testing.expectEqual(@as(?sql.RuntimeError, if (timeout) error.QueryTimeout else error.Canceled), sleeper.failure);
    const reconnect_deadline = live.scheduler.current_time_ms() + 5000;
    while (!live.db.ready() or live.db.cancel_connections[index].phase != .dormant) {
        if (live.scheduler.current_time_ms() >= reconnect_deadline) return error.ReconnectDidNotDrain;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(cancel_before + 1, live.db.cancel_requests);
    try std.testing.expectEqual(@as(u64, 0), live.db.cancel_failures);
    try std.testing.expect(live.db.cancel_connections[index].cancel_sent);
    try std.testing.expectEqual(@as(usize, 16), live.db.cancel_connections[index].transmit_len);
    try std.testing.expect(live.db.connections[index].backend_pid != backend_pid);
    try std.testing.expect(live.db.pool.stats().reconnects > reconnect_before);
    observation = .{};
    observer.deadline_ms = 0;
    try run_query(live, control, &observer, &observation);
    try expect_scalar(&observation, 0);
    try live.db.release(control);
    try check_reconnected_query(live, index);
    try std.testing.expectEqual(@as(usize, 1), sleeper.calls);
}

fn check_reconnected_query(live: *fixture.LiveDb, index: usize) !void {
    errdefer drain(live);
    var leases: [8]sql.Lease = undefined;
    var target: ?sql.Lease = null;
    for (&leases) |*lease| {
        lease.* = try live.db.acquire();
        if (lease.index == index) target = lease.*;
    }
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("SELECT 42::int4", &capture);
    try run_query(live, target orelse return error.MissingReconnectedLease, &query, &capture);
    try expect_scalar(&capture, 42);
    for (leases) |lease| try live.db.release(lease);
}

/// Copies both actual typed scalars while each Db callback still owns its slab.
const WorldValue = struct { id: i32, number: i32 };
const WorldTrace = struct {
    db: *sql.Db,
    values: [1000]WorldValue = undefined,
    count: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    connection_index: usize = 0,
    failure: ?sql.RuntimeError = null,

    fn trace(context: *anyopaque, event: sql.TraceEvent) void {
        const self: *WorldTrace = @ptrCast(@alignCast(context));
        if (event.phase == .begin) {
            self.begins += 1;
            self.find_connection() catch |err| {
                self.failure = err;
            };
            return;
        }
        self.ends += 1;
        if (event.failure) |failure| {
            self.failure = failure;
            return;
        }
        self.copy_rows() catch |err| {
            self.failure = err;
        };
    }

    fn find_connection(self: *WorldTrace) sql.RuntimeError!void {
        var found = false;
        for (self.db.assigned[0..self.db.connections.len], 0..) |query, index| {
            if (query == null) continue;
            if (found) return error.InvalidMessage;
            self.connection_index = index;
            found = true;
        }
        if (!found) return error.InvalidMessage;
    }

    fn copy_rows(self: *WorldTrace) sql.RuntimeError!void {
        const connection = &self.db.connections[self.connection_index];
        for (connection.result_sets[0..connection.result_count]) |set| {
            if (self.count == self.values.len) return error.ResponseTooLarge;
            var rows = set.rows;
            const row = (try rows.next()) orelse return error.InvalidMessage;
            if (row.fields.len != 2) return error.InvalidMessage;
            self.values[self.count] = .{ .id = try row.get(i32, 0), .number = try row.get(i32, 1) };
            self.count += 1;
            if (try rows.next() != null) return error.InvalidMessage;
        }
    }
};

/// Completion copies the entire maximum-count body into caller-owned storage.
const WorldResponse = struct {
    status: [64]u8 = undefined,
    status_len: usize = 0,
    body: [500 * 48 + 2]u8 = undefined,
    body_len: usize = 0,
    completes: usize = 0,
    wakes: usize = 0,

    fn complete(context: *anyopaque, status: []const u8, _: []const u8, body: []const u8) anyerror!void {
        const self: *WorldResponse = @ptrCast(@alignCast(context));
        self.completes += 1;
        if (status.len > self.status.len or body.len > self.body.len) return error.BufferTooSmall;
        @memcpy(self.status[0..status.len], status);
        self.status_len = status.len;
        @memcpy(self.body[0..body.len], body);
        self.body_len = body.len;
    }

    fn wake(context: *anyopaque) void {
        const self: *WorldResponse = @ptrCast(@alignCast(context));
        self.wakes += 1;
    }
};

test "sql allocation ownership: actual World handlers retain startup storage through count500 continuations" {
    const inputs = try fixture_inputs();
    defer {
        std.crypto.secureZero(u8, inputs.password);
        std.testing.allocator.free(inputs.password);
    }
    var supplied: SuppliedAllocator = .{};
    const context = try std.testing.allocator.create(example.Context);
    defer std.testing.allocator.destroy(context);
    try context.init(supplied.allocator(), test_config(inputs.password, inputs.port), 644);
    defer expect_released(&supplied) catch @panic("World Db allocations did not match their frees");
    defer context.sql.db.deinit();
    var loop = try support.loop.init();
    defer support.loop.deinit(&loop);
    var scheduler = try support.timer.Scheduler.init(std.testing.io);
    defer scheduler.deinit();
    scheduler.start(&loop);
    defer drain_world(context, &loop, &scheduler);
    try context.sql.db.start(&loop, &scheduler, std.testing.io, 0);
    const startup_deadline = scheduler.current_time_ms() + 5000;
    while (!context.sql.db.ready()) {
        if (context.sql.db.startup_failure) |failure| return failure;
        if (scheduler.current_time_ms() >= startup_deadline) return error.WorldStartupTimeout;
        try loop.xev_loop.run(.once);
    }
    try seed_world(context, &loop, &scheduler);
    try expect_startup(&supplied, &context.sql.db);
    const before = db_geometry(&context.sql.db);
    var expected_random = std.Random.DefaultPrng.init(644);
    supplied.arm();
    try check_world_handler(context, &loop, &scheduler, &expected_random, "/db", 1);
    try expect_window(&supplied, &context.sql.db, &before);
    for ([_]usize{ 20, 500 }) |count| {
        try check_world_handler(context, &loop, &scheduler, &expected_random, "/queries", count);
        try expect_window(&supplied, &context.sql.db, &before);
    }
    for ([_]usize{ 20, 500 }) |count| {
        try check_world_handler(context, &loop, &scheduler, &expected_random, "/updates", count);
        try expect_window(&supplied, &context.sql.db, &before);
    }
    drain_world(context, &loop, &scheduler);
    try std.testing.expect(context.sql.db.drained());
    try expect_window(&supplied, &context.sql.db, &before);
    supplied.armed = false;
}

fn drain_world(context: *example.Context, loop: *support.loop.Loop, scheduler: *support.timer.Scheduler) void {
    context.sql.db.stop();
    scheduler.stop(loop);
    loop.xev_loop.run(.until_done) catch @panic("World allocation callbacks did not drain");
}

fn seed_world(context: *example.Context, loop: *support.loop.Loop, scheduler: *support.timer.Scheduler) !void {
    var leases: [8]sql.Lease = undefined;
    for (&leases) |*lease| lease.* = try context.sql.db.acquire();
    for (leases) |lease| {
        var capture: fixture.QueryCapture = .{};
        var query = fixture.request(
            "CREATE TEMP TABLE World (id INTEGER PRIMARY KEY, randomnumber INTEGER NOT NULL); " ++
                "INSERT INTO World SELECT id,(id*17)%10000+1 FROM generate_series(1,10000) id",
            &capture,
        );
        query.mode = .migration;
        errdefer drain_world(context, loop, scheduler);
        try context.sql.db.query_on(lease, &query);
        const deadline = scheduler.current_time_ms() + 5000;
        while (capture.calls == 0) {
            if (scheduler.current_time_ms() >= deadline) return error.WorldSeedTimeout;
            try loop.xev_loop.run(.once);
        }
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
        try context.sql.db.release(lease);
    }
}

fn check_world_handler(context: *example.Context, loop: *support.loop.Loop, scheduler: *support.timer.Scheduler, random: *std.Random.DefaultPrng, path: []const u8, count: usize) !void {
    const single = std.mem.eql(u8, path, "/db");
    const updates = std.mem.eql(u8, path, "/updates");
    var expected: [500]WorldValue = undefined;
    for (expected[0..count]) |*value| {
        value.id = random.random().intRangeAtMost(i32, 1, 10000);
        value.number = if (updates) random.random().intRangeAtMost(i32, 1, 10000) else @mod(value.id * 17, 10000) + 1;
    }
    var response: WorldResponse = .{};
    var trace: WorldTrace = .{ .db = &context.sql.db };
    var state: support.http_response.AsyncResponseState = .{};
    const token = state.arm(.{ .context = &response, .complete_fn = WorldResponse.complete, .wake_fn = WorldResponse.wake });
    var query_text: [32]u8 = undefined;
    var request: support.Request = .{ .method = "GET", .path = path, .query = try std.fmt.bufPrint(&query_text, "count={d}", .{count}) };
    errdefer drain_world(context, loop, scheduler);
    context.sql.db.diagnostics = .{ .trace_context = &trace, .trace = WorldTrace.trace };
    defer context.sql.db.diagnostics = .{};
    const free_before = context.free_count;
    example.Context.handler(context, &request, token);
    const deadline = scheduler.current_time_ms() + 12_000;
    while (response.completes == 0 or context.free_count != free_before) {
        if (scheduler.current_time_ms() >= deadline) return error.WorldResponseTimeout;
        try loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), trace.failure);
    try std.testing.expectEqual(@as(usize, 1), response.completes);
    try std.testing.expectEqual(@as(usize, 1), response.wakes);
    try std.testing.expect(!token.is_pending());
    try std.testing.expectEqualStrings("200 OK", response.status[0..response.status_len]);
    try std.testing.expectEqual(@as(usize, 0), context.sql.db.pool.stats().active);
    try std.testing.expectEqual(free_before, context.free_count);
    const capacity: usize = if (updates) 8 else 16;
    try std.testing.expectEqual((count + capacity - 1) / capacity, trace.begins);
    try std.testing.expectEqual(trace.begins, trace.ends);
    try std.testing.expectEqual(count * (if (updates) @as(usize, 2) else 1), trace.count);
    try check_world_rows(expected[0..count], trace.values[0..trace.count], updates);
    var output: [500 * 48 + 2]u8 = undefined;
    var length: usize = 0;
    if (!single) {
        output[0] = '[';
        length = 1;
    }
    for (expected[0..count], 0..) |value, index| {
        const text = try std.fmt.bufPrint(output[length..], "{s}{{\"id\":{d},\"randomNumber\":{d}}}", .{ if (index == 0) "" else ",", value.id, value.number });
        length += text.len;
    }
    if (!single) {
        output[length] = ']';
        length += 1;
    }
    try std.testing.expectEqualStrings(output[0..length], response.body[0..response.body_len]);
}

fn check_world_rows(expected: []const WorldValue, actual: []const WorldValue, updates: bool) !void {
    if (!updates) {
        try std.testing.expectEqualDeep(expected, actual);
        return;
    }
    var completed: usize = 0;
    while (completed < expected.len) {
        const count = @min(@as(usize, 8), expected.len - completed);
        const order = expected_lock_order(expected[completed..][0..count]);
        for (order[0..count], 0..) |original, position| {
            const selected = actual[2 * (completed + position)];
            const updated = actual[2 * (completed + position) + 1];
            try std.testing.expectEqual(expected[completed + original].id, selected.id);
            try std.testing.expect(selected.number >= 1 and selected.number <= 10000);
            try std.testing.expectEqual(expected[completed + original], updated);
        }
        completed += count;
    }
}

/// Stable selection supplies an independent oracle for the example's insertion sort.
fn expected_lock_order(values: []const WorldValue) [8]usize {
    var order: [8]usize = undefined;
    var used: u8 = 0;
    for (0..values.len) |position| {
        var winner: ?usize = null;
        for (values, 0..) |value, index| {
            if (used & (@as(u8, 1) << @as(u3, @intCast(index))) != 0) continue;
            if (winner == null or value.id < values[winner.?].id) winner = index;
        }
        const selected = winner orelse @panic("bounded selection has an unused input");
        used |= @as(u8, 1) << @as(u3, @intCast(selected));
        order[position] = selected;
    }
    return order;
}
