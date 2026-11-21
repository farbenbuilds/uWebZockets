const std = @import("std");
const sql = @import("test_support").sql;

const AcquireResult = struct {
    calls: usize = 0,
    outcome: ?sql.pool.AcquireOutcome = null,

    fn complete(context: *anyopaque, outcome: sql.pool.AcquireOutcome) void {
        const self: *AcquireResult = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.outcome = outcome;
    }
};

test "sql pool: bounded exhaustion and stale worker-local leases" {
    var pool = try sql.pool.Pool.init(7, 8, 2);
    var leases: [8]sql.pool.Lease = undefined;
    for (&leases, 0..) |*lease, index| {
        try pool.mark_ready(index);
        lease.* = try pool.acquire();
    }
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    var other_worker = leases[0];
    other_worker.worker_index = 8;
    try std.testing.expectError(error.WrongWorker, pool.release(other_worker, true));
    try pool.release(leases[0], true);
    try std.testing.expectError(error.StaleLease, pool.release(leases[0], true));
    const new_lease = try pool.acquire();
    try std.testing.expect(new_lease.generation != leases[0].generation);
    try std.testing.expectEqual(@as(usize, 8), pool.stats().active);
}

test "sql pool: acquire wait queue and deadlines are bounded" {
    var pool = try sql.pool.Pool.init(0, 8, 2);
    var first: AcquireResult = .{};
    var second: AcquireResult = .{};
    var third: AcquireResult = .{};
    const wait = try pool.wait(50, &first, AcquireResult.complete);
    _ = try pool.wait(100, &second, AcquireResult.complete);
    try std.testing.expectError(error.PoolExhausted, pool.wait(100, &third, AcquireResult.complete));
    try std.testing.expectEqual(@as(usize, 2), pool.stats().waiting);
    pool.dispatch(50);
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(error.DeadlineExceeded, first.outcome.?.failure);
    try std.testing.expectError(error.StaleWait, pool.cancel_wait(wait));
    try pool.mark_ready(0);
    pool.dispatch(51);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().waiting);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().active);
}

test "sql pool: failed connections use bounded staggered reconnect delay" {
    var pool = try sql.pool.Pool.init(0, 8, 2);
    try pool.mark_ready(0);
    const lease = try pool.acquire();
    try pool.release(lease, false);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().failed);
    const first = try pool.reconnect_delay(0, 25, 1000);
    const second = try pool.reconnect_delay(0, 25, 1000);
    try std.testing.expect(second > first);
    for (0..100) |_| try std.testing.expect((try pool.reconnect_delay(0, 25, 1000)) <= 1000);
}

const fixture = @import("sql_test_support.zig");
const QueryCapture = fixture.QueryCapture;
const LiveDb = fixture.LiveDb;
const request = fixture.request;

test "sql PostgreSQL: SCRAM startup, binary typed rows, bound injection, prepared cache" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    var capture: QueryCapture = .{};
    const parameters = [_]sql.Param{.{ .value = .{ .int4 = 42 } }};
    var query = request("SELECT $1::int4", &capture);
    query.statement.name = "typed_number";
    query.params = &parameters;
    // Startup already owns every Zig allocation used by query admission and execution.
    const allocator = live.db.allocator;
    live.db.allocator = std.testing.failing_allocator;
    defer live.db.allocator = allocator;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(i64, 42), capture.integer);
    try std.testing.expectEqual(@as(usize, 1), capture.rows);

    capture = .{};
    query.deadline_ms = 0;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);

    const injection = "'; DROP TABLE accounts; --";
    const text_parameters = [_]sql.Param{.{ .value = .{ .text = injection } }};
    capture = .{};
    query = request("SELECT $1::text", &capture);
    query.params = &text_parameters;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqualStrings(injection, capture.text[0..capture.text_len]);
}

test "sql PostgreSQL: transaction failure recovers through savepoint and commit" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    const lease = try live.db.acquire();
    var tx = try sql.Tx.init(&live.db, lease);
    var capture: QueryCapture = .{};
    var query = request("", &capture);
    try tx.begin(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    capture = .{};
    query = request("CREATE TEMP TABLE uwz_tx_test (id INTEGER)", &capture);
    try tx.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    capture = .{};
    query = request("INSERT INTO uwz_tx_test VALUES (1)", &capture);
    try tx.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    capture = .{};
    query = request("", &capture);
    const savepoint = try tx.savepoint(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    capture = .{};
    query = request("SELECT absent_column FROM uwz_tx_test", &capture);
    try tx.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.ServerError), capture.failure);
    capture = .{};
    query = request("", &capture);
    try tx.rollback_to(&query, savepoint);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    capture = .{};
    query = request("SELECT count(*) FROM uwz_tx_test", &capture);
    try tx.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(i64, 1), capture.integer);
    capture = .{};
    query = request("", &capture);
    const stale_batch = [_]sql.runtime_types.BoundStatement{.{ .statement = .{ .name = "", .sql = "SELECT 999::int4" } }};
    query.batch = &stale_batch;
    query.mode = .migration;
    try tx.commit(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().active);
}

test "sql pool: leases cannot cross independent pools on the same worker" {
    var first = try sql.pool.Pool.init(7, 8, 2);
    var second = try sql.pool.Pool.init(7, 8, 2);
    try first.mark_ready(0);
    try second.mark_ready(0);
    const first_lease = try first.acquire();
    const second_lease = try second.acquire();
    try std.testing.expectEqual(first_lease.generation, second_lease.generation);
    try std.testing.expectError(error.WrongPool, second.release(first_lease, true));
    var first_wait: AcquireResult = .{};
    var second_wait: AcquireResult = .{};
    const first_handle = try first.wait(100, &first_wait, AcquireResult.complete);
    const second_handle = try second.wait(100, &second_wait, AcquireResult.complete);
    try std.testing.expectError(error.WrongPool, second.cancel_wait(first_handle));
    try second.cancel_wait(second_handle);
    try first.cancel_wait(first_handle);
    try second.release(second_lease, true);
    try first.release(first_lease, true);
}

test "sql PostgreSQL: deadline quarantines a connection before pool reuse" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    var capture: QueryCapture = .{};
    var query = request("SELECT pg_sleep(1)", &capture);
    query.deadline_ms = live.scheduler.current_time_ms() + 20;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.QueryTimeout), capture.failure);
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().active);
    try std.testing.expect(live.db.pool.stats().failed >= 1);
}

/// Reads each independent result schema before any connection slab is reused.
const BatchCapture = struct {
    calls: usize = 0,
    failure: ?sql.RuntimeError = null,
    count: usize = 0,
    sum: i64 = 0,
    text_matches: bool = false,

    fn complete(context: *anyopaque, outcome: sql.QueryOutcome) void {
        const self: *BatchCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        switch (outcome) {
            .failure => |err| self.failure = err,
            .success => |result| {
                self.count = result.results.len;
                for (result.results) |set| {
                    var rows = set.rows;
                    const row = (rows.next() catch |err| {
                        self.failure = err;
                        return;
                    }) orelse return;
                    const value = row.value(0) catch |err| {
                        self.failure = err;
                        return;
                    };
                    switch (value) {
                        .int4 => |number| self.sum += number,
                        .int8 => |number| self.sum += number,
                        .text => |text| self.text_matches = std.mem.eql(u8, text, "bound batch"),
                        else => self.failure = error.TypeMismatch,
                    }
                }
            },
        }
    }
};

test "sql PostgreSQL: parameterized mixed-schema pipeline shares one Sync" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    const number = [_]sql.Param{.{ .value = .{ .int4 = 12 } }};
    const text = [_]sql.Param{.{ .value = .{ .text = "bound batch" } }};
    const operations = [_]sql.runtime_types.BoundStatement{
        .{ .statement = .{ .name = "batch_int", .sql = "SELECT $1::int4" }, .params = &number },
        .{ .statement = .{ .name = "batch_text", .sql = "SELECT $1::text" }, .params = &text },
        .{ .statement = .{ .name = "batch_bigint", .sql = "SELECT 30::int8" } },
    };
    var capture: BatchCapture = .{};
    var query: sql.Query = .{ .statement = .{ .name = "", .sql = "" }, .batch = &operations, .context = &capture, .callback = BatchCapture.complete };
    try live.db.query(&query);
    const deadline = live.scheduler.current_time_ms() + 5000;
    while (capture.calls == 0) {
        if (live.scheduler.current_time_ms() >= deadline) return error.QueryCompletionTimeout;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqual(@as(i64, 42), capture.sum);
    try std.testing.expect(capture.text_matches);
}

test "sql PostgreSQL: middle pipeline error drains Sync before reuse" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    const operations = [_]sql.runtime_types.BoundStatement{
        .{ .statement = .{ .name = "", .sql = "SELECT 1::int4" } },
        .{ .statement = .{ .name = "", .sql = "SELECT no_such_pipeline_column" } },
        .{ .statement = .{ .name = "", .sql = "SELECT 3::int8" } },
    };
    var capture: QueryCapture = .{};
    var query = request("", &capture);
    query.batch = &operations;
    const lease = try live.db.acquire();
    try live.db.query_on(lease, &query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.ServerError), capture.failure);
    try std.testing.expectEqual(@as(u8, 'I'), live.db.connections[lease.index].transaction_status);
    capture = .{};
    query = request("SELECT 42::int4", &capture);
    try live.db.query_on(lease, &query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(i64, 42), capture.integer);
    try live.db.release(lease);
}

fn tls_ca() ![:0]u8 {
    return fixture.required_env_z("UWZ_SQL_TEST_CA_PATH");
}

test "sql PostgreSQL TLS: trusted chain and peer identity authenticate successfully" {
    const ca = try tls_ca();
    defer std.testing.allocator.free(ca);
    var live = try LiveDb.init_with_tls(.{ .ca_path = ca, .server_name = "localhost" });
    defer live.deinit();
    try live.start();
    var capture: QueryCapture = .{};
    var query = request("SELECT 42::int4", &capture);
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(i64, 42), capture.integer);
}

fn expect_tls_rejected(policy: sql.TlsConfig) !void {
    var live = try LiveDb.init_with_tls(policy);
    defer live.deinit();
    live.scheduler.start(&live.loop);
    try live.db.start(&live.loop, &live.scheduler, std.testing.io, 3);
    const deadline = live.scheduler.current_time_ms() + 5000;
    while (live.db.pool.stats().failed == 0) {
        if (live.scheduler.current_time_ms() >= deadline) return error.ExpectedTlsFailure;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expect(!live.db.ready());
    try std.testing.expectEqual(@as(usize, 0), live.db.pool.stats().idle);
    var verified_failure = false;
    for (live.db.connections) |*connection| {
        if (connection.phase == .dormant and connection.failure == error.CertificateVerificationFailed) verified_failure = true;
    }
    try std.testing.expect(verified_failure);
}

test "sql PostgreSQL TLS: certificate hostname mismatch fails closed" {
    const ca = try tls_ca();
    defer std.testing.allocator.free(ca);
    try expect_tls_rejected(.{ .ca_path = ca, .server_name = "wrong.sql.invalid" });
}

test "sql PostgreSQL TLS: untrusted certificate authority fails closed" {
    const trusted_ca = try tls_ca();
    defer std.testing.allocator.free(trusted_ca);
    const ca = try fixture.required_env_z("UWZ_SQL_TEST_UNTRUSTED_CA_PATH");
    defer std.testing.allocator.free(ca);
    try expect_tls_rejected(.{ .ca_path = ca, .server_name = "localhost" });
}

test "sql PostgreSQL: acquire deadline and shutdown complete each request once" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    var leases: [8]sql.Lease = undefined;
    for (&leases) |*lease| lease.* = try live.db.acquire();
    var capture: QueryCapture = .{};
    var query = request("SELECT 1::int4", &capture);
    query.deadline_ms = live.scheduler.current_time_ms() + 20;
    try live.db.query(&query);
    try std.testing.expectEqual(sql.runtime_types.QueryState.waiting, query.state);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.AcquireTimeout), capture.failure);
    for (leases) |lease| try live.db.release(lease);
    capture = .{};
    query = request("SELECT pg_sleep(1)", &capture);
    try live.db.query(&query);
    live.db.stop();
    live.scheduler.stop(&live.loop);
    try live.loop.xev_loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(?sql.RuntimeError, error.Canceled), capture.failure);
    try std.testing.expect(live.db.drained());
}

fn check_startup_allocation(allocator: std.mem.Allocator) !void {
    var db = try sql.Db.init(allocator, .{
        .user = "uwz_test",
        .database = "uwz_test",
        .allow_plaintext = true,
        .limits = .{ .max_message_bytes = 1024, .max_response_bytes = 1024 },
        .write_bytes = 1024,
    });
    defer db.deinit();
    try std.testing.expect(db.drained());
}

test "sql startup: every allocation failure releases previously owned storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_startup_allocation, .{});
    try std.testing.expectError(error.TlsRequired, sql.Db.init(std.testing.allocator, .{ .user = "uwz_test", .database = "uwz_test" }));
}

test "sql PostgreSQL: Unicode SASLprep matches server password normalization" {
    const password = try fixture.required_env("UWZ_SQL_TEST_UNICODE_PASSWORD");
    defer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    var live = try LiveDb.init_credentials("uwz_unicode", password, null);
    defer live.deinit();
    try live.start();
    var capture: QueryCapture = .{};
    var query = request("SELECT 42::int4", &capture);
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(i64, 42), capture.integer);
}

fn expect_app_startup_failure(config: sql.Config, expected: @import("test_support").public_api.modules.ServiceError) !void {
    const App = @import("test_support").app.configured_app_with_timeout(1, 1024, 4096, 0);
    var owner = try sql.Sql.init(std.testing.allocator, config);
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var app = try App.init(std.testing.io);
    defer app.deinit();
    try app.provide(owner.hooks());
    transferred = true;
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(expected, app.run());
    const failure = app.service_failure().?;
    try std.testing.expectEqualStrings("sql", failure.name);
    try std.testing.expectEqual(expected, failure.err);
    try std.testing.expect(owner.db.drained());
    try std.testing.expect(app.service_readiness() != null);
}

fn service_failure_config(password: []const u8) !sql.Config {
    const port_text = try fixture.env("UWZ_SQL_TEST_PORT");
    defer if (port_text) |text| std.testing.allocator.free(text);
    return .{
        .user = "uwz_test",
        .database = "uwz_test",
        .password = password,
        .port = try std.fmt.parseInt(u16, port_text orelse "55432", 10),
        .allow_plaintext = true,
        .limits = .{ .max_message_bytes = 64 * 1024, .max_response_bytes = 64 * 1024 },
    };
}

test "sql service: wrong PostgreSQL password fails App startup and drains sockets" {
    const password = try fixture.required_env("UWZ_SQL_TEST_PASSWORD");
    defer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    var config = try service_failure_config(password);
    if (config.password.len == 0) return error.InvalidTestCredentials;
    config.password = config.password[1..];
    try expect_app_startup_failure(config, error.AuthenticationFailed);
}

test "sql service: untrusted PostgreSQL CA fails App startup and drains sockets" {
    const password = try fixture.required_env("UWZ_SQL_TEST_PASSWORD");
    defer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    var config = try service_failure_config(password);
    const ca = try fixture.required_env_z("UWZ_SQL_TEST_UNTRUSTED_CA_PATH");
    defer std.testing.allocator.free(ca);
    config.tls = .{ .ca_path = ca, .server_name = "localhost" };
    try expect_app_startup_failure(config, error.TlsFailed);
}

test "sql service: silent PostgreSQL peer fails the bounded App startup budget" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var peer = try address.listen(std.testing.io, .{});
    defer peer.deinit(std.testing.io);
    try expect_app_startup_failure(.{
        .user = "startup_probe",
        .database = "startup_probe",
        .port = peer.socket.address.getPort(),
        .allow_plaintext = true,
        .connect_timeout_ms = 20,
        .limits = .{ .max_message_bytes = 1024, .max_response_bytes = 1024 },
    }, error.DeadlineExceeded);
}

test "sql PostgreSQL: CJK compatibility password normalization matches server" {
    const password = try fixture.required_env("UWZ_SQL_TEST_CJK_PASSWORD");
    defer {
        std.crypto.secureZero(u8, password);
        std.testing.allocator.free(password);
    }
    var live = try LiveDb.init_credentials("uwz_unicode_cjk", password, null);
    defer live.deinit();
    try live.start();
    var capture: QueryCapture = .{};
    var query = request("SELECT 42::int4", &capture);
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    try std.testing.expectEqual(@as(i64, 42), capture.integer);
}

fn verify_cancel_request(policy: ?sql.TlsConfig, deadline_cancel: bool) !void {
    var live = try LiveDb.init_with_tls(policy);
    defer live.deinit();
    try live.start();
    var sleeper: QueryCapture = .{};
    var sleep_query = request("SELECT pg_sleep(5)", &sleeper);
    sleep_query.deadline_ms = live.scheduler.current_time_ms() + (if (deadline_cancel) @as(u64, 1000) else 10_000);
    try live.db.query(&sleep_query);
    const index = sleep_query.lease.?.index;
    const pid = live.db.connections[index].backend_pid;
    const parameters = [_]sql.Param{.{ .value = .{ .int4 = @intCast(pid) } }};
    const observed_deadline = live.scheduler.current_time_ms() + 500;
    while (true) {
        var observation: QueryCapture = .{};
        var observer = request("SELECT count(*) FROM pg_stat_activity WHERE pid=$1 AND wait_event='PgSleep'", &observation);
        observer.params = &parameters;
        try live.db.query(&observer);
        try live.wait(&observation);
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), observation.failure);
        if (observation.integer == 1) break;
        if (live.scheduler.current_time_ms() >= observed_deadline) return error.SleepNotObserved;
    }
    const canceled_at = live.scheduler.current_time_ms();
    if (!deadline_cancel) try live.db.cancel(&sleep_query);
    try live.wait(&sleeper);
    try std.testing.expectEqual(@as(?sql.RuntimeError, if (deadline_cancel) error.QueryTimeout else error.Canceled), sleeper.failure);
    const cancel_deadline = live.scheduler.current_time_ms() + 2000;
    while (live.db.cancel_connections[index].phase != .dormant) {
        if (live.scheduler.current_time_ms() >= cancel_deadline) return error.CancelSocketDidNotDrain;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expect(live.db.cancel_requests >= 1);
    try std.testing.expectEqual(@as(u64, 0), live.db.cancel_failures);
    while (true) {
        var observation: QueryCapture = .{};
        var observer = request("SELECT count(*) FROM pg_stat_activity WHERE pid=$1 AND wait_event='PgSleep'", &observation);
        observer.params = &parameters;
        try live.db.query(&observer);
        try live.wait(&observation);
        try std.testing.expectEqual(@as(?sql.RuntimeError, null), observation.failure);
        if (observation.integer == 0) break;
        if (live.scheduler.current_time_ms() >= cancel_deadline) return error.BackendWasNotCanceled;
    }
    try std.testing.expect(live.scheduler.current_time_ms() - canceled_at < 4000);
}

test "sql PostgreSQL: CancelRequest stops a running backend before socket reuse" {
    try verify_cancel_request(null, false);
}

test "sql PostgreSQL TLS: query deadline sends a verified TLS CancelRequest" {
    const ca = try tls_ca();
    defer std.testing.allocator.free(ca);
    try verify_cancel_request(.{ .ca_path = ca, .server_name = "localhost" }, true);
}

/// A continuation tries to monopolize a just-released connection.
const ReentrantAcquirer = struct {
    pool: *sql.pool.Pool,
    calls: usize = 0,
    bypassed_waiter: bool = false,

    fn complete(context: *anyopaque, outcome: sql.pool.AcquireOutcome) void {
        const self: *ReentrantAcquirer = @ptrCast(@alignCast(context));
        self.calls += 1;
        const lease = outcome.lease;
        self.pool.release(lease, true) catch @panic("test lease release failed");
        const bypass = self.pool.acquire() catch return;
        self.bypassed_waiter = true;
        self.pool.release(bypass, true) catch @panic("test bypass lease release failed");
    }
};

test "sql pool: callback continuations cannot bypass earlier FIFO waiters" {
    var pool = try sql.pool.Pool.init(0, 8, 2);
    for (0..8) |index| try pool.mark_ready(index);
    var leases: [8]sql.pool.Lease = undefined;
    for (&leases) |*lease| lease.* = try pool.acquire();
    var continuation = ReentrantAcquirer{ .pool = &pool };
    var older: AcquireResult = .{};
    _ = try pool.wait(100, &continuation, ReentrantAcquirer.complete);
    _ = try pool.wait(100, &older, AcquireResult.complete);
    try pool.release(leases[0], true);
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    pool.dispatch(1);
    try std.testing.expectEqual(@as(usize, 1), continuation.calls);
    try std.testing.expect(!continuation.bypassed_waiter);
    try std.testing.expectEqual(@as(usize, 1), older.calls);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().waiting);
}

const FairnessSlot = struct {
    owner: *FairnessProbe,
    index: usize,
    query: sql.Query,
    completed: usize = 0,

    fn complete(context: *anyopaque, outcome: sql.QueryOutcome) void {
        const self: *FairnessSlot = @ptrCast(@alignCast(context));
        const owner = self.owner;
        owner.callbacks += 1;
        if (outcome == .failure) {
            if (owner.failure == null) owner.failure = outcome.failure;
            owner.finished += 1;
            return;
        }
        self.completed += 1;
        if (self.index >= 8 and self.completed == 1) {
            if (owner.callbacks > 64) owner.starved = true;
            owner.max_initial_wait_ms = @max(owner.max_initial_wait_ms, owner.db.scheduler.?.current_time_ms() - owner.started_ms);
        }
        if (self.completed == 64) {
            owner.finished += 1;
            return;
        }
        self.query.deadline_ms = 0;
        owner.db.query(&self.query) catch |err| {
            if (owner.failure == null) owner.failure = err;
            owner.finished += 1;
        };
    }
};

/// Sixteen callback chains compete for eight sockets without starving the queued half.
const FairnessProbe = struct {
    db: *sql.Db,
    slots: [16]FairnessSlot = undefined,
    started_ms: u64 = 0,
    callbacks: usize = 0,
    finished: usize = 0,
    max_initial_wait_ms: u64 = 0,
    starved: bool = false,
    failure: ?sql.RuntimeError = null,
};

test "sql PostgreSQL: sixteen callback chains fairly share eight sockets" {
    var live = try LiveDb.init();
    defer live.deinit();
    try live.start();
    var probe = FairnessProbe{ .db = &live.db, .started_ms = live.scheduler.current_time_ms() };
    for (&probe.slots, 0..) |*slot, index| {
        slot.* = .{
            .owner = &probe,
            .index = index,
            .query = .{ .statement = .{ .name = "fairness_probe", .sql = "SELECT 1::int4 FROM pg_sleep(0.002)" }, .context = slot, .callback = FairnessSlot.complete },
        };
        try live.db.query(&slot.query);
    }
    const deadline = probe.started_ms + 5000;
    while (probe.finished < probe.slots.len) {
        if (live.scheduler.current_time_ms() >= deadline) return error.FairnessCompletionTimeout;
        try live.loop.xev_loop.run(.once);
    }
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), probe.failure);
    try std.testing.expect(!probe.starved);
    try std.testing.expect(probe.max_initial_wait_ms < 2500);
    for (probe.slots) |slot| try std.testing.expectEqual(@as(usize, 64), slot.completed);
}
