const std = @import("std");
const support = @import("test_support");
const sql = support.sql;
const fixture = @import("sql_test_support.zig");

const migrations = [_]sql.migrate.Migration{sql.migrate.embedded(1, "startup_world", "CREATE TABLE public.uwz_startup_world(id INTEGER PRIMARY KEY); INSERT INTO public.uwz_startup_world VALUES(42); SELECT pg_sleep(0.02);")};

test "sql migration service: startup bounds are validated without allocation" {
    var db: sql.Db = undefined;
    try std.testing.expectError(error.InvalidConfiguration, sql.MigrationService.init(&db, &migrations, .{ .timeout_ms = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, sql.MigrationService.init(&db, &migrations, .{ .name = "" }));
    var service = try sql.MigrationService.init(&db, &migrations, .{});
    try std.testing.expectEqualStrings("sql_migrations", service.hooks().name);
    try std.testing.expect(service.hooks().ready.?(service.hooks().context) != null);
    service.hooks().deinit.?(service.hooks().context);
}

const App = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
const lifecycle = support.public_api.modules;

/// Stops the App only after observing the migration barrier on the owning loop.
const StartupProbe = struct {
    app: *App,
    service: *sql.MigrationService,
    scheduler: ?*support.timer.Scheduler = null,
    poll: support.timer_wheel.TimerNode = .{},
    deadline_ms: u64 = 0,
    stop_during_apply: bool = false,
    bound_before_start: bool = false,
    observed_pending: bool = false,
    observed_running: bool = false,
    observed_apply: bool = false,
    observed_ready: bool = false,
    requested_stop: bool = false,
    timed_out: bool = false,
    stopped: bool = false,
    deinitialized: bool = false,

    fn hooks(self: *StartupProbe) lifecycle.ServiceHooks {
        return .{ .name = "migration_probe", .context = self, .start = start, .stop = stop, .deinit = deinit };
    }

    fn start(context: *anyopaque, worker: *const lifecycle.WorkerContext) lifecycle.ServiceError!void {
        const self: *StartupProbe = @ptrCast(@alignCast(context));
        self.scheduler = @ptrCast(@alignCast(worker.scheduler orelse return error.InvalidConfiguration));
        self.bound_before_start = self.app.listener_count != 0;
        self.observed_pending = self.app.service_readiness() != null;
        self.deadline_ms = self.scheduler.?.current_time_ms() + 5000;
        self.scheduler.?.schedule_after(&self.poll, 1, tick, self);
    }

    fn tick(context: *anyopaque) void {
        const self: *StartupProbe = @ptrCast(@alignCast(context));
        if (self.scheduler.?.current_time_ms() >= self.deadline_ms) {
            self.timed_out = true;
            self.app.request_shutdown();
            return;
        }
        if (self.service.state == .running) self.observed_running = true;
        if (self.service.runner.phase == .apply) self.observed_apply = true;
        if (self.stop_during_apply and self.service.runner.phase == .apply) {
            self.requested_stop = true;
            self.app.request_shutdown();
            return;
        }
        if (self.service.state == .ready) {
            self.observed_ready = self.app.service_readiness() == null;
            self.app.request_shutdown();
            return;
        }
        self.observed_pending = self.observed_pending and self.app.service_readiness() != null;
        self.scheduler.?.schedule_after(&self.poll, 1, tick, self);
    }

    fn stop(context: *anyopaque, _: *const lifecycle.WorkerContext) void {
        const self: *StartupProbe = @ptrCast(@alignCast(context));
        if (self.scheduler) |scheduler| _ = scheduler.cancel(&self.poll);
        self.stopped = true;
    }

    fn deinit(context: *anyopaque) void {
        const self: *StartupProbe = @ptrCast(@alignCast(context));
        std.debug.assert(self.poll.owner == null);
        self.deinitialized = true;
    }
};

/// Starts the apply-phase budget after authenticating the unchanged SQL pool.
fn start_ready_sql(context: *anyopaque, worker: *const lifecycle.WorkerContext) lifecycle.ServiceError!void {
    const owner: *sql.Sql = @ptrCast(@alignCast(context));
    const hooks = owner.hooks();
    try hooks.start(context, worker);
    const loop: *support.loop.Loop = @ptrCast(@alignCast(worker.loop));
    const scheduler: *support.timer.Scheduler = @ptrCast(@alignCast(worker.scheduler orelse return error.InvalidConfiguration));
    const deadline = scheduler.current_time_ms() +| owner.db.config.connect_timeout_ms;
    while (!owner.db.ready()) {
        if (hooks.failed.?(context)) |failure| return failure;
        if (scheduler.current_time_ms() >= deadline) return error.DeadlineExceeded;
        loop.xev_loop.run(.once) catch return error.Unexpected;
    }
}

/// Owns integration credentials across the App's borrowed Db configuration.
const Credentials = struct {
    password: []u8,
    port: u16,

    fn init() !Credentials {
        const password = try fixture.required_env("UWZ_SQL_TEST_PASSWORD");
        errdefer std.testing.allocator.free(password);
        const port_text = try fixture.env("UWZ_SQL_TEST_PORT");
        defer if (port_text) |text| std.testing.allocator.free(text);
        return .{ .password = password, .port = try std.fmt.parseInt(u16, port_text orelse "55432", 10) };
    }

    fn deinit(self: *Credentials) void {
        std.crypto.secureZero(u8, self.password);
        std.testing.allocator.free(self.password);
    }

    fn config(self: *const Credentials) sql.Config {
        return .{
            .user = "uwz_test",
            .database = "uwz_test",
            .password = self.password,
            .port = self.port,
            .allow_plaintext = true,
            .limits = .{ .max_message_bytes = 64 * 1024, .max_response_bytes = 64 * 1024 },
        };
    }
};

fn reset_database() !void {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("DROP TABLE IF EXISTS public.uwz_schema_migrations; DROP TABLE IF EXISTS public.uwz_startup_world", &capture);
    query.mode = .migration;
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
}

fn committed_value() !i64 {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    var capture: fixture.QueryCapture = .{};
    var query = fixture.request("SELECT id::int8 FROM public.uwz_startup_world", &capture);
    try live.db.query(&query);
    try live.wait(&capture);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), capture.failure);
    return capture.integer;
}

fn run_successful_startup(credentials: *const Credentials) !void {
    var owner = try sql.Sql.init(std.testing.allocator, credentials.config());
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var service = try sql.MigrationService.init(&owner.db, &migrations, .{});
    var app = try App.init(std.testing.io);
    defer app.deinit();
    var probe = StartupProbe{ .app = &app, .service = &service };
    try app.provide(owner.hooks());
    transferred = true;
    try app.provide(service.hooks());
    try app.provide(probe.hooks());
    try app.listen("127.0.0.1", 0);
    try std.testing.expect(app.service_readiness() != null);
    try app.run();
    try std.testing.expect(probe.bound_before_start);
    try std.testing.expect(probe.observed_pending);
    try std.testing.expect(probe.observed_running);
    try std.testing.expect(probe.observed_ready);
    try std.testing.expect(!probe.timed_out);
    try std.testing.expect(probe.stopped);
    try std.testing.expectEqual(@as(usize, 1), service.applied);
    try std.testing.expect(service.failure == null);
    try std.testing.expectEqual(sql.migrate_pg.Phase.idle, service.runner.phase);
    try std.testing.expect(service.poll.owner == null);
    try std.testing.expect(owner.db.drained());
    app.deinit();
    try std.testing.expect(probe.deinitialized);
}

test "sql migration service: App readiness waits for committed live PostgreSQL migrations" {
    var credentials = try Credentials.init();
    defer credentials.deinit();
    try reset_database();
    try run_successful_startup(&credentials);
    try std.testing.expectEqual(@as(i64, 42), try committed_value());
}

test "sql migration service: checksum failure retains owned names and original error" {
    var credentials = try Credentials.init();
    defer credentials.deinit();
    try reset_database();
    try run_successful_startup(&credentials);
    var owner = try sql.Sql.init(std.testing.allocator, credentials.config());
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var migration_name = "startup_world".*;
    var service_name = "schema_check".*;
    var changed = sql.migrate.embedded(1, "startup_world", "CREATE TABLE public.uwz_startup_world(changed INTEGER);");
    changed.name = &migration_name;
    var service = try sql.MigrationService.init(&owner.db, &.{changed}, .{ .name = &service_name });
    var app = try App.init(std.testing.io);
    defer app.deinit();
    try app.provide(owner.hooks());
    transferred = true;
    try app.provide(service.hooks());
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(error.MigrationFailed, app.run());
    @memset(&migration_name, 'x');
    @memset(&service_name, 'x');
    try std.testing.expectEqualStrings("schema_check", app.service_failure().?.name);
    try std.testing.expectEqual(error.ChecksumMismatch, service.failure.?.err);
    try std.testing.expectEqualStrings("startup_world", service.failure.?.name[0..service.failure.?.name_len]);
    try std.testing.expect(owner.db.drained());
    app.deinit();
    try std.testing.expectEqualStrings("startup_world", service.failure.?.name[0..service.failure.?.name_len]);
    try std.testing.expectEqual(@as(i64, 42), try committed_value());
}

test "sql migration service: App shutdown cancels a partially started runner before deinit" {
    var credentials = try Credentials.init();
    defer credentials.deinit();
    try reset_database();
    const slow = sql.migrate.embedded(1, "startup_cancel", "CREATE TABLE public.uwz_startup_world(id INTEGER); SELECT pg_sleep(0.5);");
    var owner = try sql.Sql.init(std.testing.allocator, credentials.config());
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var service = try sql.MigrationService.init(&owner.db, &.{slow}, .{});
    var app = try App.init(std.testing.io);
    defer app.deinit();
    var probe = StartupProbe{ .app = &app, .service = &service, .stop_during_apply = true };
    try app.provide(owner.hooks());
    transferred = true;
    try app.provide(service.hooks());
    try app.provide(probe.hooks());
    try app.listen("127.0.0.1", 0);
    try app.run();
    try std.testing.expect(probe.requested_stop);
    try std.testing.expect(!probe.observed_ready);
    try std.testing.expect(!probe.timed_out);
    try std.testing.expect(service.failure != null);
    try std.testing.expectEqual(sql.migrate_pg.Phase.idle, service.runner.phase);
    try std.testing.expect(service.poll.owner == null);
    try std.testing.expect(owner.db.drained());
    app.deinit();
    try std.testing.expect(service.state == .deinitialized);
}

test "sql migration service: same index cannot borrow a different worker loop" {
    var live = try fixture.LiveDb.init();
    defer live.deinit();
    try live.start();
    var service = try sql.MigrationService.init(&live.db, &migrations, .{});
    var other_loop = try support.loop.init();
    defer support.loop.deinit(&other_loop);
    var other_scheduler = try support.timer.Scheduler.init(std.testing.io);
    defer other_scheduler.deinit();
    var marker: u8 = 0;
    const worker = lifecycle.WorkerContext{
        .worker_index = live.db.pool.worker_index,
        .io = std.testing.io,
        .loop = &other_loop,
        .scheduler = &other_scheduler,
        .config = &marker,
    };
    const hooks = service.hooks();
    defer hooks.deinit.?(hooks.context);
    try std.testing.expectError(error.InvalidConfiguration, hooks.start(hooks.context, &worker));
    try std.testing.expect(service.state == .configured);
    try std.testing.expect(service.poll.owner == null);
}

test "sql migration service: waiting for a silent SQL peer has an overall deadline" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var peer = try address.listen(std.testing.io, .{});
    defer peer.deinit(std.testing.io);
    var owner = try sql.Sql.init(std.testing.allocator, .{
        .user = "migration_wait",
        .database = "migration_wait",
        .port = peer.socket.address.getPort(),
        .allow_plaintext = true,
    });
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var service = try sql.MigrationService.init(&owner.db, &migrations, .{ .timeout_ms = 25 });
    var app = try App.init(std.testing.io);
    defer app.deinit();
    try app.provide(owner.hooks());
    transferred = true;
    try app.provide(service.hooks());
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(error.DeadlineExceeded, app.run());
    try std.testing.expectEqualStrings("sql_migrations", app.service_failure().?.name);
    try std.testing.expectEqual(error.QueryTimeout, service.failure.?.err);
    try std.testing.expectEqual(@as(usize, 0), service.failure.?.name_len);
    try std.testing.expect(service.poll.owner == null);
    try std.testing.expect(owner.db.drained());
}

test "sql migration service: applying SQL obeys the overall deadline and drains" {
    var credentials = try Credentials.init();
    defer credentials.deinit();
    try reset_database();
    const slow = sql.migrate.embedded(1, "migration_deadline", "CREATE TABLE public.uwz_startup_world(id INTEGER); SELECT pg_sleep(5);");
    var owner = try sql.Sql.init(std.testing.allocator, credentials.config());
    var transferred = false;
    defer if (!transferred) owner.db.deinit();
    var service = try sql.MigrationService.init(&owner.db, &.{slow}, .{ .timeout_ms = 500 });
    var app = try App.init(std.testing.io);
    defer app.deinit();
    var sql_hooks = owner.hooks();
    sql_hooks.start = start_ready_sql;
    try app.provide(sql_hooks);
    transferred = true;
    try app.provide(service.hooks());
    var probe: StartupProbe = .{ .app = &app, .service = &service };
    try app.provide(probe.hooks());
    try app.listen("127.0.0.1", 0);
    try std.testing.expectError(error.DeadlineExceeded, app.run());
    try std.testing.expectEqual(error.QueryTimeout, service.failure.?.err);
    try std.testing.expectEqualStrings("migration_deadline", service.failure.?.name[0..service.failure.?.name_len]);
    try std.testing.expect(probe.observed_apply);
    try std.testing.expect(!probe.timed_out);
    try std.testing.expectEqual(sql.migrate_pg.Phase.idle, service.runner.phase);
    try std.testing.expect(service.poll.owner == null);
    try std.testing.expect(owner.db.drained());
}
