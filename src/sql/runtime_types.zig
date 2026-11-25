//! Explicit request ownership and transport policy for the SQL worker.
const std = @import("std");
const types = @import("types.zig");
const row = @import("rows.zig");
const pool = @import("pool.zig");
const timer_wheel = @import("../core/timer_wheel.zig");

/// Runtime errors include lease integrity failures and bounded wire failures.
pub const RuntimeError = types.SqlError || pool.PoolError || error{ InvalidSavepoint, QueryAlreadyActive, BatchLimit };
/// Maximum extended-protocol operations sharing one Sync round trip.
pub const max_batch_statements = 16;
/// One explicitly bound operation in a pipeline; slices remain borrowed through completion.
pub const BoundStatement = struct { statement: types.Statement, params: []const types.Param = &.{} };
/// TLS always verifies the chain and peer name; PostgreSQL has no insecure TLS mode.
pub const TlsConfig = struct { ca_path: [:0]const u8, server_name: []const u8 };
/// Startup-owned worker configuration; credentials and statement slices are borrowed.
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8,
    database: []const u8,
    password: []const u8 = "",
    tls: ?TlsConfig = null,
    allow_plaintext: bool = false,
    connections: usize = 8,
    wait_capacity: usize = 64,
    limits: types.Limits = .{},
    write_bytes: usize = 128 * 1024,
    statement_cache_entries: usize = 16,
    connect_timeout_ms: u64 = 10_000,
    cancel_timeout_ms: u64 = 1_000,
    acquire_timeout_ms: u64 = 5_000,
    query_timeout_ms: u64 = 10_000,
    health_interval_ms: u64 = 30_000,
    reconnect_base_ms: u64 = 100,
    reconnect_cap_ms: u64 = 30_000,
};
/// A completed response borrows worker storage until its callback returns.
pub const QueryResult = struct {
    rows: row.Rows,
    results: []const ResultSet = &.{},
    transaction_status: u8,
    command_tag: []const u8,
};
/// One pipeline operation's independently typed, bounded result rows.
pub const ResultSet = struct { rows: row.Rows, command_tag: []const u8 };
/// One terminal query outcome; server error text is deliberately omitted.
pub const QueryOutcome = union(enum) { success: QueryResult, failure: RuntimeError };
/// Called once on the owning worker; callbacks may enqueue subsequent work.
pub const QueryCallback = *const fn (context: *anyopaque, outcome: QueryOutcome) void;
/// Caller-owned request state; SQL and parameter slices remain borrowed until completion.
pub const Query = struct {
    statement: types.Statement,
    params: []const types.Param = &.{},
    batch: []const BoundStatement = &.{},
    mode: QueryMode = .extended,
    deadline_ms: u64 = 0,
    context: *anyopaque,
    callback: QueryCallback,
    timer: timer_wheel.TimerNode = .{},
    owner_context: ?*anyopaque = null,
    lease: ?pool.Lease = null,
    waiter: ?pool.WaitHandle = null,
    state: QueryState = .idle,
    auto_release: bool = true,
};
/// Enforces one owner and one terminal callback for caller-owned requests.
pub const QueryState = enum { idle, waiting, running };
/// Simple protocol is reserved for trusted embedded multi-statement migrations.
pub const QueryMode = enum { extended, migration };
/// Startup validation has no effects and rejects capacities before allocation.
pub fn validate_config(config: Config) RuntimeError!void {
    if (config.tls == null and !config.allow_plaintext) return error.TlsRequired;
    if (config.user.len == 0 or config.database.len == 0) return error.InvalidConfiguration;
    if (std.mem.indexOfScalar(u8, config.user, 0) != null or std.mem.indexOfScalar(u8, config.database, 0) != null) return error.InvalidConfiguration;
    if (config.connections < 8 or config.connections > pool.max_connections) return error.InvalidPoolSize;
    if (config.wait_capacity > pool.max_waiters) return error.InvalidWaitCapacity;
    if (config.statement_cache_entries == 0 or config.statement_cache_entries > 32) return error.InvalidConfiguration;
    if (config.write_bytes < 128 or config.write_bytes > std.math.maxInt(c_int)) return error.InvalidConfiguration;
    if (config.limits.max_message_bytes < 64 or config.limits.max_message_bytes > std.math.maxInt(c_int)) return error.InvalidConfiguration;
    if (config.limits.max_columns == 0 or config.limits.max_columns > 64) return error.InvalidConfiguration;
    if (config.limits.max_statement_bytes == 0 or config.limits.max_statement_bytes > 4096) return error.InvalidConfiguration;
    if (config.limits.max_parameters > 64 or config.limits.max_rows == 0 or config.limits.max_response_bytes < 16) return error.InvalidConfiguration;
    if (config.connect_timeout_ms == 0 or config.query_timeout_ms == 0 or config.acquire_timeout_ms == 0) return error.InvalidConfiguration;
    if (config.cancel_timeout_ms == 0) return error.InvalidConfiguration;
    if (config.reconnect_base_ms == 0 or config.reconnect_cap_ms < config.reconnect_base_ms) return error.InvalidConfiguration;
    if (config.health_interval_ms == 0) return error.InvalidConfiguration;
    if (config.tls) |tls| {
        if (tls.server_name.len == 0 or tls.server_name.len > 255 or tls.ca_path.len == 0) return error.InvalidConfiguration;
    }
}
