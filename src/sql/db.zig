//! Single-worker SQL owner: connection admission, deadlines, and maintenance.
const std = @import("std");
const types = @import("types.zig");
const runtime = @import("runtime_types.zig");
const pool_module = @import("pool.zig");
const transport = @import("connection.zig");
const loop_module = @import("../core/loop.zig");
const timer_module = @import("../core/timer.zig");
const wheel = @import("../core/timer_wheel.zig");
const tls = @import("../crypto/tls_client.zig");
const metrics = @import("../observability/metrics.zig");

/// Optional child-span observation excludes SQL text and all parameter values.
pub const TraceEvent = struct { statement_name: []const u8, phase: TracePhase, failure: ?runtime.RuntimeError = null };
/// One asynchronous operation's statement-only trace boundaries.
pub const TracePhase = enum { begin, end };
/// Receives a static/bounded statement name on the owning worker.
pub const TraceCallback = *const fn (context: *anyopaque, event: TraceEvent) void;
/// Borrowed diagnostics sinks are optional and worker-confined.
pub const Diagnostics = struct { metrics: ?*metrics.Registry = null, trace_context: ?*anyopaque = null, trace: ?TraceCallback = null };

/// Startup allocation owns every request-path slab; keep this address stable after start.
pub const Db = struct {
    allocator: std.mem.Allocator,
    config: runtime.Config,
    connections: []transport.Connection,
    cancel_connections: []transport.Connection,
    slabs: []u8,
    pool: pool_module.Pool,
    assigned: [pool_module.max_connections]?*runtime.Query = .{null} ** pool_module.max_connections,
    health_queries: [pool_module.max_connections]runtime.Query = undefined,
    next_health: [pool_module.max_connections]u64 = .{0} ** pool_module.max_connections,
    next_reconnect: [pool_module.max_connections]u64 = .{0} ** pool_module.max_connections,
    maintenance: wheel.TimerNode = .{},
    startup_deadline: wheel.TimerNode = .{},
    startup_failure: ?runtime.RuntimeError = null,
    context: ?tls.ClientContext = null,
    loop: ?*loop_module.Loop = null,
    scheduler: ?*timer_module.Scheduler = null,
    io: std.Io = undefined,
    diagnostics: Diagnostics = .{},
    started: bool = false,
    stopping: bool = false,
    has_been_ready: bool = false,
    cancel_requests: u64 = 0,
    cancel_failures: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: runtime.Config) runtime.RuntimeError!Db {
        try runtime.validate_config(config);
        const connections = allocator.alloc(transport.Connection, config.connections) catch return error.OutOfMemory;
        errdefer allocator.free(connections);
        const cancel_connections = allocator.alloc(transport.Connection, config.connections) catch return error.OutOfMemory;
        errdefer allocator.free(cancel_connections);
        const receive_bytes = std.math.add(usize, config.limits.max_message_bytes, 5) catch return error.InvalidConfiguration;
        const per_connection = std.math.add(usize, receive_bytes, config.limits.max_response_bytes) catch return error.InvalidConfiguration;
        const stride = std.math.add(usize, per_connection, config.write_bytes) catch return error.InvalidConfiguration;
        const query_bytes = std.math.mul(usize, stride, config.connections) catch return error.InvalidConfiguration;
        const cancel_bytes = std.math.mul(usize, 192, config.connections) catch return error.InvalidConfiguration;
        const slab_bytes = std.math.add(usize, query_bytes, cancel_bytes) catch return error.InvalidConfiguration;
        const slabs = allocator.alloc(u8, slab_bytes) catch return error.OutOfMemory;
        errdefer allocator.free(slabs);
        var context: ?tls.ClientContext = null;
        if (config.tls) |policy| context = tls.ClientContext.init(.{ .verify = true, .ca_path = policy.ca_path }) catch return error.TlsFailed;
        for (connections, 0..) |*connection, index| {
            const bytes = slabs[index * stride ..][0..stride];
            connection.* = .{
                .receive = bytes[0..receive_bytes],
                .response = bytes[receive_bytes..][0..config.limits.max_response_bytes],
                .transmit = bytes[per_connection..][0..config.write_bytes],
            };
            const cancel_slab = slabs[query_bytes + index * 192 ..][0..192];
            cancel_connections[index] = .{ .receive = cancel_slab[0..64], .transmit = cancel_slab[64..] };
        }
        return .{ .allocator = allocator, .config = config, .connections = connections, .cancel_connections = cancel_connections, .slabs = slabs, .pool = try pool_module.Pool.init(0, config.connections, config.wait_capacity), .context = context };
    }

    /// Runs after listeners bind, on the worker that owns `loop` and `scheduler`.
    pub fn start(self: *Db, loop: *loop_module.Loop, scheduler: *timer_module.Scheduler, io: std.Io, worker_index: usize) runtime.RuntimeError!void {
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        self.stopping = false;
        self.startup_failure = null;
        self.has_been_ready = false;
        self.loop = loop;
        self.scheduler = scheduler;
        self.io = io;
        self.pool = try pool_module.Pool.init(worker_index, self.config.connections, self.config.wait_capacity);
        errdefer self.stop();
        const now = scheduler.current_time_ms();
        scheduler.schedule_after(&self.startup_deadline, self.config.connect_timeout_ms, on_startup_timeout, self);
        for (self.connections, 0..) |_, index| {
            self.health_queries[index] = .{ .statement = .{ .name = "", .sql = "SELECT 1" }, .context = self, .callback = on_health };
            self.next_health[index] = now +| self.config.health_interval_ms;
            try self.start_connection(index);
        }
        self.schedule_maintenance(now +| 1);
        self.sample_metrics();
    }

    /// Returns a bounded lease immediately; use `query` for deadline-bound waiting.
    pub fn acquire(self: *Db) runtime.RuntimeError!pool_module.Lease {
        if (!self.started or self.stopping) return error.NotReady;
        const lease = try self.pool.acquire();
        self.sample_metrics();
        return lease;
    }

    /// Queues one caller-owned request; this function allocates nothing.
    pub fn query(self: *Db, request: *runtime.Query) runtime.RuntimeError!void {
        try self.prepare_request(request, true);
        const lease = self.pool.acquire() catch |err| {
            if (err != error.PoolExhausted) return err;
            const now = self.scheduler.?.current_time_ms();
            const acquire_deadline = @min(request.deadline_ms, now +| self.config.acquire_timeout_ms);
            request.waiter = try self.pool.wait(acquire_deadline, request, on_acquired);
            request.state = .waiting;
            request.owner_context = self;
            self.scheduler.?.schedule(&request.timer, acquire_deadline, on_timeout, request);
            self.schedule_maintenance(now +| 1);
            self.sample_metrics();
            return;
        };
        self.assign(lease, request) catch |err| {
            try self.pool.release(lease, true);
            return err;
        };
    }

    /// Executes on a pinned transaction/migration lease without releasing it.
    pub fn query_on(self: *Db, lease: pool_module.Lease, request: *runtime.Query) runtime.RuntimeError!void {
        try self.pool.validate(lease);
        if (self.assigned[lease.index] != null) return error.ConnectionBusy;
        try self.prepare_request(request, false);
        try self.assign(lease, request);
    }

    /// Returns only a fully synchronized, transaction-idle connection to admission.
    pub fn release(self: *Db, lease: pool_module.Lease) runtime.RuntimeError!void {
        try self.pool.validate(lease);
        if (self.assigned[lease.index] != null) return error.ConnectionBusy;
        const connection = &self.connections[lease.index];
        if (connection.phase != .ready or connection.transaction_status != 'I') {
            try self.discard(lease);
            return error.InvalidTransaction;
        }
        try self.pool.release(lease, true);
        self.pool.dispatch(self.scheduler.?.current_time_ms());
        self.sample_metrics();
    }

    /// Quarantines canceled or unknown transaction state until close has drained.
    pub fn discard(self: *Db, lease: pool_module.Lease) runtime.RuntimeError!void {
        try self.pool.validate(lease);
        try self.pool.release(lease, false);
        self.connections[lease.index].stop(error.Canceled);
        self.sample_metrics();
    }

    pub fn cancel(self: *Db, request: *runtime.Query) runtime.RuntimeError!void {
        if (request.owner_context != @as(*anyopaque, self) or request.state == .idle) return error.NotReady;
        if (request.state == .waiting) {
            try self.pool.cancel_wait(request.waiter.?);
            self.finish_request(request, .{ .failure = error.Canceled });
            return;
        }
        self.cancel_running(request.lease.?.index, error.Canceled);
    }

    /// Starts asynchronous close; deinit waits for the App's shared loop drain.
    pub fn stop(self: *Db) void {
        if (!self.started or self.stopping) return;
        self.stopping = true;
        _ = self.scheduler.?.cancel(&self.maintenance);
        _ = self.scheduler.?.cancel(&self.startup_deadline);
        self.pool.stop();
        for (self.connections) |*connection| connection.stop(error.Canceled);
        for (self.cancel_connections) |*connection| connection.stop(error.Canceled);
        self.sample_metrics();
    }

    pub fn drained(self: *const Db) bool {
        for (self.connections) |*connection| {
            if (connection.phase != .dormant) return false;
        }
        for (self.cancel_connections) |*connection| {
            if (connection.phase != .dormant) return false;
        }
        return true;
    }

    pub fn ready(self: *const Db) bool {
        if (!self.started or self.stopping) return false;
        for (self.pool.slots[0..self.config.connections]) |slot| {
            if (slot.state == .connecting or slot.state == .failed) return false;
        }
        return true;
    }

    pub fn deinit(self: *Db) void {
        std.debug.assert(self.drained());
        for (self.connections) |*connection| connection.session.deinit();
        for (self.cancel_connections) |*connection| connection.session.deinit();
        if (self.context) |*context| context.deinit();
        self.allocator.free(self.slabs);
        self.allocator.free(self.connections);
        self.allocator.free(self.cancel_connections);
        self.connections = &.{};
        self.cancel_connections = &.{};
        self.slabs = &.{};
        self.context = null;
        self.started = false;
    }

    fn prepare_request(self: *Db, request: *runtime.Query, auto_release: bool) runtime.RuntimeError!void {
        if (!self.started or self.stopping) return error.NotReady;
        if (request.state != .idle) return error.QueryAlreadyActive;
        if (request.statement.sql.len > self.config.limits.max_statement_bytes) return error.StatementTooLarge;
        if (request.params.len > self.config.limits.max_parameters) return error.TooManyParameters;
        const now = self.scheduler.?.current_time_ms();
        if (request.deadline_ms == 0) request.deadline_ms = now +| self.config.query_timeout_ms;
        if (request.deadline_ms <= now) return error.QueryTimeout;
        request.auto_release = auto_release;
    }

    fn assign(self: *Db, lease: pool_module.Lease, request: *runtime.Query) runtime.RuntimeError!void {
        try self.connections[lease.index].execute(request);
        request.owner_context = self;
        request.lease = lease;
        request.waiter = null;
        request.state = .running;
        self.assigned[lease.index] = request;
        self.scheduler.?.schedule(&request.timer, request.deadline_ms, on_timeout, request);
        self.trace(request, .begin, null);
        self.sample_metrics();
    }

    fn start_connection(self: *Db, index: usize) runtime.RuntimeError!void {
        const connection = &self.connections[index];
        if (self.config.tls) |policy| {
            const cancel_connection = &self.cancel_connections[index];
            if (cancel_connection.session.ssl == null) {
                cancel_connection.session.init_for_protocol(self.context.?.ctx, policy.server_name, true, .postgres) catch return error.TlsFailed;
            }
            connection.session.init_for_protocol(self.context.?.ctx, policy.server_name, true, .postgres) catch return error.TlsFailed;
        }
        connection.start(.{ .loop = self.loop.?, .scheduler = self.scheduler.?, .io = self.io, .config = self.config, .index = index, .context = self, .ready = on_ready, .closed = on_closed, .complete = on_complete }) catch |err| {
            connection.session.deinit();
            return err;
        };
    }

    fn finish_request(self: *Db, request: *runtime.Query, outcome: runtime.QueryOutcome) void {
        _ = self.scheduler.?.cancel(&request.timer);
        const context = request.context;
        const callback = request.callback;
        const was_running = request.state == .running;
        request.state = .idle;
        request.owner_context = null;
        request.waiter = null;
        request.lease = null;
        if (was_running) self.trace(request, .end, if (outcome == .failure) outcome.failure else null);
        callback(context, outcome);
    }

    fn schedule_maintenance(self: *Db, deadline_ms: u64) void {
        if (self.stopping) return;
        if (self.maintenance.owner != null and self.maintenance.deadline_ms <= deadline_ms) return;
        self.scheduler.?.schedule(&self.maintenance, deadline_ms, on_maintenance, self);
    }

    fn sample_metrics(self: *Db) void {
        const registry = self.diagnostics.metrics orelse return;
        const stats = self.pool.stats();
        registry.set(.sql_active, @intCast(stats.active));
        registry.set(.sql_idle, @intCast(stats.idle));
        registry.set(.sql_waiting, @intCast(stats.waiting));
        registry.set(.sql_failed, @intCast(stats.failed));
        registry.set(.sql_reconnects, stats.reconnects);
    }

    fn trace(self: *Db, request: *const runtime.Query, phase: TracePhase, failure: ?runtime.RuntimeError) void {
        const callback = self.diagnostics.trace orelse return;
        const context = self.diagnostics.trace_context orelse return;
        callback(context, .{ .statement_name = request.statement.name, .phase = phase, .failure = failure });
    }

    fn on_acquired(context: *anyopaque, outcome: pool_module.AcquireOutcome) void {
        const request: *runtime.Query = @ptrCast(@alignCast(context));
        const self: *Db = @ptrCast(@alignCast(request.owner_context.?));
        request.waiter = null;
        switch (outcome) {
            .failure => |err| self.finish_request(request, .{ .failure = switch (err) {
                error.DeadlineExceeded => error.AcquireTimeout,
                error.Stopped => error.Canceled,
                else => err,
            } }),
            .lease => |lease| self.assign(lease, request) catch |err| {
                self.pool.release(lease, true) catch |release_error| {
                    self.finish_request(request, .{ .failure = release_error });
                    return;
                };
                self.finish_request(request, .{ .failure = err });
            },
        }
    }

    fn on_timeout(context: *anyopaque) void {
        const request: *runtime.Query = @ptrCast(@alignCast(context));
        const self: *Db = @ptrCast(@alignCast(request.owner_context.?));
        switch (request.state) {
            .idle => {},
            .waiting => {
                self.pool.cancel_wait(request.waiter.?) catch |err| {
                    self.finish_request(request, .{ .failure = err });
                    return;
                };
                self.finish_request(request, .{ .failure = error.AcquireTimeout });
            },
            .running => self.cancel_running(request.lease.?.index, error.QueryTimeout),
        }
        self.sample_metrics();
    }

    fn on_ready(context: *anyopaque, index: usize) void {
        const self: *Db = @ptrCast(@alignCast(context));
        self.pool.mark_ready(index) catch |err| {
            self.connections[index].stop(err);
            return;
        };
        self.next_reconnect[index] = 0;
        self.next_health[index] = self.scheduler.?.current_time_ms() +| self.config.health_interval_ms;
        if (self.ready()) {
            self.has_been_ready = true;
            _ = self.scheduler.?.cancel(&self.startup_deadline);
        }
        self.pool.dispatch(self.scheduler.?.current_time_ms());
        self.sample_metrics();
    }

    fn on_closed(context: *anyopaque, index: usize, failure: runtime.RuntimeError) void {
        const self: *Db = @ptrCast(@alignCast(context));
        self.pool.mark_failed(index) catch |err| {
            std.log.scoped(.sql).err("SQL closed slot invariant failed: {}", .{err});
            return;
        };
        if (self.assigned[index]) |request| {
            self.assigned[index] = null;
            self.finish_request(request, .{ .failure = failure });
        }
        if (!self.has_been_ready and terminal_startup_failure(failure)) {
            if (self.startup_failure == null) self.startup_failure = failure;
            self.stop();
        }
        if (!self.stopping) {
            const delay = self.pool.reconnect_delay(index, self.config.reconnect_base_ms, self.config.reconnect_cap_ms) catch |err| {
                std.log.scoped(.sql).err("SQL reconnect slot invariant failed: {}", .{err});
                return;
            };
            self.next_reconnect[index] = self.scheduler.?.current_time_ms() +| delay;
            self.schedule_maintenance(self.next_reconnect[index]);
        }
        self.sample_metrics();
    }

    fn on_complete(context: *anyopaque, index: usize, outcome: runtime.QueryOutcome) void {
        const self: *Db = @ptrCast(@alignCast(context));
        const request = self.assigned[index] orelse return;
        const lease = request.lease.?;
        self.assigned[index] = null;
        if (request.auto_release) {
            const healthy = self.connections[index].transaction_status == 'I';
            self.pool.release(lease, healthy) catch |err| {
                self.finish_request(request, .{ .failure = err });
                return;
            };
            if (!healthy) self.connections[index].stop(error.InvalidTransaction);
        }
        self.finish_request(request, outcome);
        if (!self.stopping) self.pool.dispatch(self.scheduler.?.current_time_ms());
        self.sample_metrics();
    }

    fn on_maintenance(context: *anyopaque) void {
        const self: *Db = @ptrCast(@alignCast(context));
        if (self.stopping) return;
        const now = self.scheduler.?.current_time_ms();
        self.pool.dispatch(now);
        var next = now +| self.config.health_interval_ms;
        for (self.connections, 0..) |*connection, index| {
            if (self.cancel_connections[index].phase != .dormant) continue;
            if (connection.phase == .dormant and self.pool.slots[index].state == .failed) {
                if (self.next_reconnect[index] <= now) {
                    self.pool.slots[index].state = .connecting;
                    self.start_connection(index) catch |err| on_closed(self, index, err);
                } else next = @min(next, self.next_reconnect[index]);
            }
            if (self.pool.slots[index].state != .idle) continue;
            if (self.next_health[index] <= now) self.start_health(index);
            next = @min(next, self.next_health[index]);
        }
        if (self.pool.stats().waiting > 0) next = @min(next, now +| 1);
        self.schedule_maintenance(@max(now +| 1, next));
        self.sample_metrics();
    }

    fn start_health(self: *Db, index: usize) void {
        if (self.pool.waiting_count != 0) return;
        self.next_health[index] = self.scheduler.?.current_time_ms() +| self.config.health_interval_ms;
        // Only this worker mutates slots, so the selected idle slot is reserved atomically by program order.
        const slot = &self.pool.slots[index];
        slot.state = .busy;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        const lease = pool_module.Lease{ .owner = &self.pool, .worker_index = self.pool.worker_index, .index = index, .generation = slot.generation };
        const request = &self.health_queries[index];
        request.deadline_ms = 0;
        self.query_on(lease, request) catch |err| {
            self.pool.release(lease, false) catch |release_error| std.log.scoped(.sql).err("SQL health release failed: {}", .{release_error});
            self.connections[index].stop(err);
            return;
        };
        request.auto_release = true;
    }

    fn on_health(_: *anyopaque, _: runtime.QueryOutcome) void {}

    fn cancel_running(self: *Db, index: usize, failure: runtime.RuntimeError) void {
        const connection = &self.connections[index];
        const cancel_connection = &self.cancel_connections[index];
        if (connection.backend_pid != 0 and cancel_connection.phase == .dormant and !self.stopping) {
            var config = self.config;
            config.connect_timeout_ms = config.cancel_timeout_ms;
            cancel_connection.start(.{
                .loop = self.loop.?,
                .scheduler = self.scheduler.?,
                .io = self.io,
                .config = config,
                .index = index,
                .context = self,
                .ready = on_cancel_ready,
                .closed = on_cancel_closed,
                .complete = on_cancel_complete,
                .cancel_key = .{ .pid = connection.backend_pid, .secret = connection.backend_secret },
            }) catch {
                // A failed cancellation side channel cannot release the quarantined main socket.
                self.cancel_failures +|= 1;
            };
        }
        connection.stop(failure);
    }

    fn on_cancel_closed(context: *anyopaque, index: usize, _: runtime.RuntimeError) void {
        const self: *Db = @ptrCast(@alignCast(context));
        if (self.cancel_connections[index].cancel_sent) self.cancel_requests +|= 1 else self.cancel_failures +|= 1;
        if (!self.stopping and self.connections[index].phase == .dormant) {
            self.schedule_maintenance(@max(self.scheduler.?.current_time_ms() +| 1, self.next_reconnect[index]));
        }
    }

    fn on_cancel_ready(context: *anyopaque, index: usize) void {
        const self: *Db = @ptrCast(@alignCast(context));
        self.cancel_connections[index].stop(error.ProtocolError);
    }

    fn on_cancel_complete(context: *anyopaque, index: usize, _: runtime.QueryOutcome) void {
        const self: *Db = @ptrCast(@alignCast(context));
        self.cancel_connections[index].stop(error.ProtocolError);
    }

    fn on_startup_timeout(context: *anyopaque) void {
        const self: *Db = @ptrCast(@alignCast(context));
        if (self.has_been_ready or self.stopping) return;
        if (self.startup_failure == null) self.startup_failure = error.QueryTimeout;
        self.stop();
    }
};

fn terminal_startup_failure(failure: runtime.RuntimeError) bool {
    return switch (failure) {
        error.AuthenticationFailed,
        error.UnsupportedAuthentication,
        error.CertificateVerificationFailed,
        error.TlsFailed,
        error.TlsRequired,
        error.InvalidConfiguration,
        error.QueryTimeout,
        => true,
        else => false,
    };
}
