//! Optional worker-local SQLite connection with startup-prepared statements.
//! SQLite owns its internal C allocations; lookaside and result bounds do not
//! imply that upstream's pager or virtual machine never calls its allocator.

const std = @import("std");
const c = @import("sqlite_c");
const types = @import("types.zig");

/// Explicit parameter values shared with the PostgreSQL backend.
pub const Param = types.Param;

/// SQLite failures never include SQL text, values, paths, or engine messages.
pub const Error = types.SqlError || error{ InvalidStatement, StaleRow };
/// Explicit SQLite connection policy and result bounds.
pub const Options = struct {
    path: [:0]const u8 = ":memory:",
    busy_timeout_ms: u31 = 0,
    wal: bool = false,
    foreign_keys: bool = true,
    max_vm_steps: u32 = 1_000_000,
    limits: types.Limits = .{},
};
/// Caller-owned startup statement storage; no query compiles SQL implicitly.
pub const Prepared = struct {
    handle: ?*c.sqlite3_stmt = null,
    parameter_count: usize = 0,
};
/// Per-connection SQLite memory telemetry, including lookaside fallback demand.
pub const MemoryUsage = struct {
    cache_bytes: usize,
    schema_bytes: usize,
    statement_bytes: usize,
    lookaside_used: usize,
    lookaside_miss_size: usize,
    lookaside_miss_full: usize,
};
/// SQLite-wide allocator status; peaks bound simultaneous use, not churn.
pub const AllocationSnapshot = struct {
    current_bytes: i64,
    peak_bytes: i64,
    current_blocks: i64,
    peak_blocks: i64,
};

/// A connection, its prepared cache, and the currently borrowed result lease.
/// Keep this value at a stable address once query results have been borrowed.
pub const Db = struct {
    handle: ?*c.sqlite3,
    statements: []Prepared,
    limits: types.Limits,
    active_index: ?usize = null,
    generation: u64 = 0,
    sealed: bool = false,
    max_vm_steps: u32,
    progress_budget: u32 = 0,

    /// Opens SQLite during startup. Storage and lookaside outlive the Db.
    pub fn init(options: Options, statements: []Prepared, lookaside: []align(8) u8) Error!Db {
        if (statements.len == 0 or lookaside.len < 512 or options.max_vm_steps < 1000) return error.InvalidConfiguration;
        if (std.mem.indexOfScalar(u8, options.path, 0) != null) return error.InvalidConfiguration;
        try validate_limits(options.limits);
        var handle: ?*c.sqlite3 = null;
        const status = c.sqlite3_open_v2(options.path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        errdefer if (handle) |db| {
            _ = c.sqlite3_close_v2(db);
        };
        try check(status);
        const db = handle orelse return error.SqliteError;
        const slot_count = @min(lookaside.len / 512, std.math.maxInt(c_int));
        try check(c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_LOOKASIDE, lookaside.ptr, @as(c_int, 512), @as(c_int, @intCast(slot_count))));
        try check(c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_ENABLE_FKEY, @as(c_int, @intFromBool(options.foreign_keys)), @as(?*c_int, null)));
        try check(c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_DEFENSIVE, @as(c_int, 1), @as(?*c_int, null)));
        try check(c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, @as(c_int, 0), @as(?*c_int, null)));
        try check(c.sqlite3_busy_timeout(db, @intCast(options.busy_timeout_ms)));
        _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, @intCast(options.limits.max_field_bytes));
        _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_SQL_LENGTH, @intCast(options.limits.max_statement_bytes));
        _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_COLUMN, @intCast(options.limits.max_columns));
        _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_VARIABLE_NUMBER, @intCast(options.limits.max_parameters));
        if (options.wal) try enable_wal(db);
        for (statements) |*statement| statement.* = .{};
        return .{ .handle = db, .statements = statements, .limits = options.limits, .max_vm_steps = options.max_vm_steps };
    }

    /// Finalizes every statement before closing the worker's connection.
    pub fn deinit(self: *Db) void {
        self.reset();
        for (self.statements) |*statement| {
            if (statement.handle) |handle| _ = c.sqlite3_finalize(handle);
            statement.* = .{};
        }
        if (self.handle) |handle| {
            const status = c.sqlite3_close(handle);
            std.debug.assert(status == c.SQLITE_OK);
        }
        self.handle = null;
    }

    /// Prevents subsequent statement compilation when request handling starts.
    pub fn seal(self: *Db) void {
        self.sealed = true;
    }

    /// Compiles one SQL statement into a caller-owned cache slot at startup.
    pub fn prepare(self: *Db, index: usize, sql: []const u8) Error!void {
        if (self.sealed) return error.AlreadyStarted;
        if (self.active_index != null) return error.ConnectionBusy;
        if (index >= self.statements.len) return error.StatementCacheFull;
        if (sql.len == 0 or sql.len > self.limits.max_statement_bytes) return error.StatementTooLarge;
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidStatement;
        const db = self.handle orelse return error.ConnectionClosed;
        var handle: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        try check(c.sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), c.SQLITE_PREPARE_PERSISTENT, &handle, &tail));
        errdefer if (handle) |statement| {
            _ = c.sqlite3_finalize(statement);
        };
        const statement = handle orelse return error.InvalidStatement;
        const used = @intFromPtr(tail) - @intFromPtr(sql.ptr);
        if (used > sql.len or std.mem.trim(u8, sql[used..], " \t\r\n;").len != 0) return error.InvalidStatement;
        const parameter_count: usize = @intCast(c.sqlite3_bind_parameter_count(statement));
        if (parameter_count > self.limits.max_parameters) return error.TooManyParameters;
        if (self.statements[index].handle) |old| _ = c.sqlite3_finalize(old);
        self.statements[index] = .{ .handle = statement, .parameter_count = parameter_count };
    }

    /// Binds borrowed parameters and acquires the connection's only row lease.
    /// Parameter strings, blobs, and UUID storage outlive Rows.deinit.
    pub fn query(self: *Db, index: usize, params: []const types.Param) Error!Rows {
        if (self.active_index != null) return error.ConnectionBusy;
        if (self.handle == null) return error.ConnectionClosed;
        if (index >= self.statements.len) return error.UnknownStatement;
        const prepared = self.statements[index];
        const handle = prepared.handle orelse return error.UnknownStatement;
        if (params.len != prepared.parameter_count or params.len > self.limits.max_parameters) return error.TooManyParameters;
        try check(c.sqlite3_clear_bindings(handle));
        errdefer _ = c.sqlite3_clear_bindings(handle);
        for (params, 0..) |*param, parameter_index| try bind(handle, @intCast(parameter_index + 1), param, self.limits.max_field_bytes);
        self.active_index = index;
        self.generation +%= 1;
        self.begin_bounded_work();
        return .{ .db = self, .handle = handle, .generation = self.generation };
    }

    /// Bounds SQLite VM work for a query or startup migration on this connection.
    pub fn begin_bounded_work(self: *Db) void {
        self.progress_budget = self.max_vm_steps / 1000;
        c.sqlite3_progress_handler(self.handle.?, 1000, on_progress, self);
    }

    /// Releases the borrowed callback before cleanup or rollback can run.
    pub fn end_bounded_work(self: *Db) void {
        if (self.handle) |handle| c.sqlite3_progress_handler(handle, 0, null, null);
    }

    /// Executes a startup-prepared statement and discards bounded result rows.
    pub fn exec(self: *Db, index: usize, params: []const types.Param) Error!void {
        var rows = try self.query(index, params);
        defer rows.deinit();
        while (try rows.next() != null) {}
    }

    /// Invalidates borrowed rows and releases the current statement lease.
    pub fn reset(self: *Db) void {
        self.generation +%= 1;
        const index = self.active_index orelse return;
        const handle = self.statements[index].handle.?;
        // reset reports the preceding step failure; next already propagated it.
        _ = c.sqlite3_reset(handle);
        _ = c.sqlite3_clear_bindings(handle);
        self.end_bounded_work();
        self.active_index = null;
    }

    /// Reads SQLite's per-connection accounting without changing global policy.
    pub fn memory_usage(self: *const Db) Error!MemoryUsage {
        const handle = self.handle orelse return error.ConnectionClosed;
        return .{
            .cache_bytes = try db_status(handle, c.SQLITE_DBSTATUS_CACHE_USED, false),
            .schema_bytes = try db_status(handle, c.SQLITE_DBSTATUS_SCHEMA_USED, false),
            .statement_bytes = try db_status(handle, c.SQLITE_DBSTATUS_STMT_USED, false),
            .lookaside_used = try db_status(handle, c.SQLITE_DBSTATUS_LOOKASIDE_USED, false),
            .lookaside_miss_size = try db_status(handle, c.SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE, true),
            .lookaside_miss_full = try db_status(handle, c.SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL, true),
        };
    }
};

/// One exclusive iterator over a startup-prepared SQLite statement.
pub const Rows = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    generation: u64,
    row_count: usize = 0,
    response_bytes: usize = 0,
    done: bool = false,

    /// A returned row expires at next, deinit, reset, or a subsequent query.
    pub fn next(self: *Rows) Error!?Row {
        if (self.done) return null;
        if (self.db.generation != self.generation) return error.StaleRow;
        self.db.generation +%= 1;
        self.generation = self.db.generation;
        const status = c.sqlite3_step(self.handle);
        if (status == c.SQLITE_DONE) {
            self.deinit();
            return null;
        }
        errdefer self.deinit();
        try check(status);
        if (self.row_count == self.db.limits.max_rows) return error.TooManyRows;
        const count: usize = @intCast(c.sqlite3_column_count(self.handle));
        if (count > self.db.limits.max_columns) return error.TooManyColumns;
        var row_bytes: usize = 0;
        for (0..count) |index| {
            const field_bytes = column_size(self.handle, @intCast(index));
            if (field_bytes > self.db.limits.max_field_bytes) return error.FieldTooLarge;
            if (field_bytes > self.db.limits.max_response_bytes - row_bytes) return error.ResponseTooLarge;
            row_bytes += field_bytes;
        }
        if (row_bytes > self.db.limits.max_response_bytes - self.response_bytes) return error.ResponseTooLarge;
        self.response_bytes += row_bytes;
        self.row_count += 1;
        return .{ .db = self.db, .handle = self.handle, .generation = self.generation, .column_count = count };
    }

    /// Releases the row lease even when iteration stops before SQLITE_DONE.
    pub fn deinit(self: *Rows) void {
        if (self.done) return;
        if (self.db.generation == self.generation) self.db.reset();
        self.done = true;
    }
};

/// Borrowed SQLite values are valid only during this row's generation.
pub const Row = struct {
    db: *const Db,
    handle: *c.sqlite3_stmt,
    generation: u64,
    column_count: usize,

    pub fn value(self: Row, index: usize) Error!types.Value {
        if (self.db.generation != self.generation) return error.StaleRow;
        if (index >= self.column_count) return error.ColumnNotFound;
        const column: c_int = @intCast(index);
        return switch (c.sqlite3_column_type(self.handle, column)) {
            c.SQLITE_NULL => .null,
            c.SQLITE_INTEGER => .{ .int8 = c.sqlite3_column_int64(self.handle, column) },
            c.SQLITE_FLOAT => .{ .float8 = c.sqlite3_column_double(self.handle, column) },
            c.SQLITE_TEXT => .{ .text = try bytes(self.handle, column, false) },
            c.SQLITE_BLOB => .{ .bytea = try bytes(self.handle, column, true) },
            else => error.UnsupportedType,
        };
    }

    /// Explicit scalar conversion; no schema generation or runtime reflection.
    pub fn get(self: Row, comptime T: type, index: usize) Error!T {
        const field = try self.value(index);
        if (field == .null) return error.NullValue;
        if (T == []const u8) return switch (field) {
            .text, .bytea => |data| data,
            else => error.TypeMismatch,
        };
        if (T == i16 or T == i32 or T == i64) return switch (field) {
            .int8 => |integer| std.math.cast(T, integer) orelse error.InvalidValue,
            else => error.TypeMismatch,
        };
        if (T == f32 or T == f64) return switch (field) {
            .float8 => |number| @floatCast(number),
            else => error.TypeMismatch,
        };
        if (T == bool) return switch (field) {
            .int8 => |integer| switch (integer) {
                0 => false,
                1 => true,
                else => error.InvalidValue,
            },
            else => error.TypeMismatch,
        };
        @compileError("SQLite Row.get supports i16/i32/i64, f32/f64, bool, and []const u8");
    }

    /// Copies one text/blob field to caller storage for use after next.
    pub fn keep(self: Row, index: usize, buffer: []u8) Error![]const u8 {
        const data = try self.get([]const u8, index);
        if (data.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..data.len], data);
        return buffer[0..data.len];
    }
};

/// SQLite-wide C memory counters are observational and never reconfigure it.
pub fn allocation_snapshot(reset_peak: bool) Error!AllocationSnapshot {
    var snapshot: AllocationSnapshot = undefined;
    try check(c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &snapshot.current_bytes, &snapshot.peak_bytes, @intFromBool(reset_peak)));
    try check(c.sqlite3_status64(c.SQLITE_STATUS_MALLOC_COUNT, &snapshot.current_blocks, &snapshot.peak_blocks, @intFromBool(reset_peak)));
    return snapshot;
}

fn check(status: c_int) Error!void {
    switch (status & 0xff) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.SqliteBusy,
        c.SQLITE_NOMEM => return error.OutOfMemory,
        c.SQLITE_INTERRUPT => return error.QueryTimeout,
        c.SQLITE_CONSTRAINT => return error.SqliteConstraint,
        c.SQLITE_TOOBIG => return error.FieldTooLarge,
        else => return error.SqliteError,
    }
}

fn validate_limits(limits: types.Limits) Error!void {
    if (limits.max_statement_bytes == 0 or limits.max_statement_bytes > 65536) return error.InvalidConfiguration;
    if (limits.max_parameters > 64 or limits.max_columns == 0 or limits.max_columns > 64) return error.InvalidConfiguration;
    if (limits.max_field_bytes == 0 or limits.max_field_bytes > 1048576) return error.InvalidConfiguration;
    if (limits.max_rows == 0 or limits.max_response_bytes < limits.max_field_bytes) return error.InvalidConfiguration;
}

fn enable_wal(handle: *c.sqlite3) Error!void {
    var prepared: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v3(handle, "PRAGMA journal_mode=WAL", -1, 0, &prepared, null));
    const statement = prepared orelse return error.SqliteError;
    defer _ = c.sqlite3_finalize(statement);
    const status = c.sqlite3_step(statement);
    try check(status);
    if (status != c.SQLITE_ROW) return error.InvalidConfiguration;
    if (!std.mem.eql(u8, try bytes(statement, 0, false), "wal")) return error.InvalidConfiguration;
    try check(c.sqlite3_step(statement));
}

fn bind(handle: *c.sqlite3_stmt, index: c_int, param: *const types.Param, max_bytes: usize) Error!void {
    const status = switch (param.value) {
        .null => c.sqlite3_bind_null(handle, index),
        .bool => |boolean| c.sqlite3_bind_int(handle, index, @intFromBool(boolean)),
        .int2 => |integer| c.sqlite3_bind_int(handle, index, integer),
        .int4 => |integer| c.sqlite3_bind_int(handle, index, integer),
        .int8 => |integer| c.sqlite3_bind_int64(handle, index, integer),
        .float4 => |number| c.sqlite3_bind_double(handle, index, number),
        .float8 => |number| c.sqlite3_bind_double(handle, index, number),
        .timestamp => |timestamp| c.sqlite3_bind_int64(handle, index, timestamp.microseconds),
        .date => |date| c.sqlite3_bind_int(handle, index, date.days),
        .text, .varchar => |data| try bind_bytes(handle, index, data, false, max_bytes),
        .bytea => |data| try bind_bytes(handle, index, data, true, max_bytes),
        .uuid => try bind_bytes(handle, index, &param.value.uuid.bytes, true, max_bytes),
        .numeric => return error.UnsupportedType,
    };
    try check(status);
}

fn bind_bytes(handle: *c.sqlite3_stmt, index: c_int, data: []const u8, blob: bool, max_bytes: usize) Error!c_int {
    if (data.len > max_bytes) return error.FieldTooLarge;
    // A non-null pointer preserves the distinction between an empty blob and NULL.
    const pointer = if (data.len == 0) "".ptr else data.ptr;
    if (blob) return c.sqlite3_bind_blob64(handle, index, pointer, data.len, null);
    return c.sqlite3_bind_text64(handle, index, pointer, data.len, null, c.SQLITE_UTF8);
}

fn bytes(handle: *c.sqlite3_stmt, index: c_int, blob: bool) Error![]const u8 {
    const pointer: ?[*]const u8 = if (blob) @ptrCast(c.sqlite3_column_blob(handle, index)) else c.sqlite3_column_text(handle, index);
    const length: usize = @intCast(c.sqlite3_column_bytes(handle, index));
    if (length == 0) return "";
    return (pointer orelse return error.OutOfMemory)[0..length];
}

fn column_size(handle: *c.sqlite3_stmt, index: c_int) usize {
    return switch (c.sqlite3_column_type(handle, index)) {
        c.SQLITE_NULL => 0,
        c.SQLITE_INTEGER, c.SQLITE_FLOAT => 8,
        else => @intCast(c.sqlite3_column_bytes(handle, index)),
    };
}

fn db_status(handle: *c.sqlite3, operation: c_int, use_peak: bool) Error!usize {
    var current: c_int = 0;
    var peak: c_int = 0;
    try check(c.sqlite3_db_status(handle, operation, &current, &peak, 0));
    return @intCast(if (use_peak) peak else current);
}

fn on_progress(context: ?*anyopaque) callconv(.c) c_int {
    const db: *Db = @ptrCast(@alignCast(context orelse return 1));
    if (db.progress_budget == 0) return 1;
    db.progress_budget -= 1;
    return @intFromBool(db.progress_budget == 0);
}
