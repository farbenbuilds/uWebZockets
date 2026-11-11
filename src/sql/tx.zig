//! Explicit pinned transactions; asynchronous failure never returns unknown state.
const std = @import("std");
const database = @import("db.zig");
const pool = @import("pool.zig");
const runtime = @import("runtime_types.zig");

/// Transaction transitions are confined to the leased worker.
pub const State = enum { fresh, active, failed, closed };
/// One bounded transaction operation in flight.
pub const Operation = enum { begin, query, commit, rollback, savepoint, rollback_to, release_savepoint };
/// Savepoint names are generated from bounded integer identities, never user SQL.
pub const Savepoint = struct { generation: u32, depth: u8 };
/// Caller-owned transaction handle; release only through commit, rollback, or discard.
pub const Tx = struct {
    db: *database.Db,
    lease: pool.Lease,
    state: State = .fresh,
    operation: Operation = .begin,
    pending: ?*runtime.Query = null,
    callback: ?runtime.QueryCallback = null,
    context: *anyopaque = undefined,
    command: [96]u8 = undefined,
    savepoints: [16]u32 = .{0} ** 16,
    savepoint_count: u8 = 0,
    savepoint_generation: u32 = 0,
    pending_savepoint: ?Savepoint = null,

    pub fn init(db: *database.Db, lease: pool.Lease) runtime.RuntimeError!Tx {
        try db.pool.validate(lease);
        if (db.connections[lease.index].transaction_status != 'I') return error.InvalidTransaction;
        return .{ .db = db, .lease = lease };
    }

    pub fn begin(self: *Tx, request: *runtime.Query) runtime.RuntimeError!void {
        if (self.state != .fresh) return error.InvalidTransaction;
        request.statement = .{ .name = "", .sql = "BEGIN" };
        request.params = &.{};
        try self.submit(request, .begin);
    }

    pub fn query(self: *Tx, request: *runtime.Query) runtime.RuntimeError!void {
        if (self.state != .active) return error.InvalidTransaction;
        try self.submit(request, .query);
    }

    pub fn commit(self: *Tx, request: *runtime.Query) runtime.RuntimeError!void {
        if (self.state != .active) return error.InvalidTransaction;
        request.statement = .{ .name = "", .sql = "COMMIT" };
        request.params = &.{};
        try self.submit(request, .commit);
    }

    pub fn rollback(self: *Tx, request: *runtime.Query) runtime.RuntimeError!void {
        if (self.state != .active and self.state != .failed) return error.InvalidTransaction;
        request.statement = .{ .name = "", .sql = "ROLLBACK" };
        request.params = &.{};
        try self.submit(request, .rollback);
    }

    /// The returned identity becomes usable after successful completion.
    pub fn savepoint(self: *Tx, request: *runtime.Query) runtime.RuntimeError!Savepoint {
        if (self.state != .active) return error.InvalidTransaction;
        if (self.savepoint_count == self.savepoints.len) return error.SavepointLimit;
        if (self.pending != null) return error.ConnectionBusy;
        self.savepoint_generation +%= 1;
        if (self.savepoint_generation == 0) self.savepoint_generation = 1;
        const token = Savepoint{ .generation = self.savepoint_generation, .depth = self.savepoint_count };
        const command = std.fmt.bufPrint(&self.command, "SAVEPOINT uwz_sp_{d}", .{token.generation}) catch return error.BufferTooSmall;
        request.statement = .{ .name = "", .sql = command };
        request.params = &.{};
        self.pending_savepoint = token;
        try self.submit(request, .savepoint);
        return token;
    }

    pub fn rollback_to(self: *Tx, request: *runtime.Query, token: Savepoint) runtime.RuntimeError!void {
        if (self.state != .active and self.state != .failed) return error.InvalidTransaction;
        try self.validate_savepoint(token);
        if (self.pending != null) return error.ConnectionBusy;
        const command = std.fmt.bufPrint(&self.command, "ROLLBACK TO SAVEPOINT uwz_sp_{d}", .{token.generation}) catch return error.BufferTooSmall;
        request.statement = .{ .name = "", .sql = command };
        request.params = &.{};
        self.pending_savepoint = token;
        try self.submit(request, .rollback_to);
    }

    pub fn release_savepoint(self: *Tx, request: *runtime.Query, token: Savepoint) runtime.RuntimeError!void {
        if (self.state != .active) return error.InvalidTransaction;
        try self.validate_savepoint(token);
        if (self.pending != null) return error.ConnectionBusy;
        const command = std.fmt.bufPrint(&self.command, "RELEASE SAVEPOINT uwz_sp_{d}", .{token.generation}) catch return error.BufferTooSmall;
        request.statement = .{ .name = "", .sql = command };
        request.params = &.{};
        self.pending_savepoint = token;
        try self.submit(request, .release_savepoint);
    }

    /// Explicit emergency cleanup closes the socket rather than guessing transaction state.
    pub fn discard(self: *Tx) runtime.RuntimeError!void {
        if (self.state == .closed) return;
        self.state = .closed;
        try self.db.discard(self.lease);
    }

    fn validate_savepoint(self: *const Tx, token: Savepoint) runtime.RuntimeError!void {
        if (token.depth >= self.savepoint_count) return error.InvalidSavepoint;
        if (self.savepoints[token.depth] != token.generation) return error.InvalidSavepoint;
    }

    fn submit(self: *Tx, request: *runtime.Query, operation: Operation) runtime.RuntimeError!void {
        if (self.pending != null) return error.ConnectionBusy;
        self.callback = request.callback;
        self.context = request.context;
        self.operation = operation;
        self.pending = request;
        if (operation != .query) {
            request.batch = &.{};
            request.mode = .extended;
        }
        request.callback = on_complete;
        request.context = self;
        self.db.query_on(self.lease, request) catch |err| {
            request.callback = self.callback.?;
            request.context = self.context;
            self.pending = null;
            return err;
        };
    }

    fn on_complete(context: *anyopaque, outcome: runtime.QueryOutcome) void {
        const self: *Tx = @ptrCast(@alignCast(context));
        const request = self.pending.?;
        const callback = self.callback.?;
        const user_context = self.context;
        request.callback = callback;
        request.context = user_context;
        self.pending = null;
        var result = outcome;
        if (outcome == .failure) {
            self.state = .failed;
            if (self.db.connections[self.lease.index].phase != .ready) {
                self.state = .closed;
            } else if (self.operation == .rollback or self.operation == .commit) {
                self.db.discard(self.lease) catch |err| {
                    result = .{ .failure = err };
                };
                self.state = .closed;
            }
            callback(user_context, result);
            return;
        }
        switch (self.operation) {
            .begin, .query => self.state = .active,
            .commit, .rollback => {
                self.state = .closed;
                self.db.release(self.lease) catch |err| {
                    result = .{ .failure = err };
                };
            },
            .savepoint => {
                const token = self.pending_savepoint.?;
                self.savepoints[token.depth] = token.generation;
                self.savepoint_count = token.depth + 1;
            },
            .rollback_to => {
                self.savepoint_count = self.pending_savepoint.?.depth + 1;
                self.state = .active;
            },
            .release_savepoint => self.savepoint_count = self.pending_savepoint.?.depth,
        }
        callback(user_context, result);
    }
};
