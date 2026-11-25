const std = @import("std");
const c = @import("c");
const pool = @import("../../core/pool.zig");
const backend = @import("backend.zig");
const session = @import("session.zig");
const early_debt = @import("early_debt.zig");
const session_control = @import("session_control.zig");
const pending = @import("pending_datagrams.zig");
const RouteId = @import("../../router/datagram.zig").RouteId;

/// Publication ownership captured before callbacks can invalidate the parent.
pub const SessionNotice = struct {
    connection: ConnectionHandle,
    session: session.SessionHandle,
    session_id: u64,
    route: RouteId,
};

/// CONNECT owns lifecycle and publication until its native stream closes.
pub const SessionRecord = struct {
    notice: SessionNotice,
    receive_debt: early_debt.Debt = .{},
    /// Negotiated positive flow owns its counters instead of legacy receive_debt.
    flow: ?session_control.State = null,
    phase: session.SessionState = .accepting,
    notice_published: bool = false,
};

/// Worker-local identity that cannot resolve after its slot is reused.
pub const ConnectionHandle = @import("identity.zig").ConnectionHandle;

/// Native connection ownership retained until every stream releases its lease.
pub const Connection = struct {
    handle: ConnectionHandle = .{},
    owner: *anyopaque = undefined,
    native: ?*c.lsquic_conn = null,
    stream_count: usize = 0,
    pending_child_count: usize = 0,
    peer: ?backend.Peer = null,
    session_count: usize = 0,
    /// Exhaustion or cooldown disables new unknown associations for this generation.
    unknown_early_disabled: bool = false,
    /// Lost stream debt blocks fresh CONNECT identities independently of datagram buffering.
    unknown_receive_disabled: bool = false,
    /// Local dispatch attempts, including full-ring drops; never a wire sequence.
    receive_ordinal: u64 = 0,
};

/// One noncopyable stream reference; release consumes this caller-owned value.
pub const StreamLease = struct {
    connection: ConnectionHandle = .{},
    active: bool = false,
};

/// Native classification is distinct from application session admission.
pub const StreamRole = enum(u8) { unresolved, http, connect, child };

/// Stable per-stream ownership and copied native association metadata.
pub const StreamState = struct {
    lease: StreamLease = .{},
    info: ?backend.StreamInfo = null,
    role: StreamRole = .unresolved,
    /// CONNECT reservations only; child parents live in child_runtime.State.
    session: ?session.SessionHandle = null,
    pending_settings: bool = false,

    pub fn mark_http(state: *StreamState) bool {
        if (state.role != .unresolved and state.role != .http) return false;
        state.role = .http;
        return true;
    }

    /// Accepts only validated backend snapshots and preserves established roles.
    pub fn classify(state: *StreamState, info: backend.StreamInfo) bool {
        if (state.info) |previous| return std.meta.eql(previous, info);
        switch (info.association) {
            .connect => if (state.role == .child) return false,
            .child => if (state.role != .unresolved) return false,
        }
        state.info = info;
        state.role = if (info.association == .connect) .connect else .child;
        return true;
    }
};

/// Startup allocation and pure pending-store geometry failures.
pub const PendingStorageError = std.mem.Allocator.Error || pending.InitError;

/// Owns the three slabs borrowed by the allocation-free pending store.
pub const PendingDatagramStorage = struct {
    store: pending.Store,

    /// Stream-only endpoints retain terminal identities without datagram slabs.
    pub fn init_terminal_only(allocator: std.mem.Allocator, count: usize) PendingStorageError!PendingDatagramStorage {
        const terminals = try allocator.alloc(pending.Terminal, count);
        errdefer allocator.free(terminals);
        return .{ .store = try pending.Store.init(.{
            .entries = &.{},
            .payloads = &.{},
            .terminals = terminals,
        }, .{ .payload_stride = 0, .per_connection_limit = 1, .lifetime_us = 0 }) };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        count: usize,
        policy: pending.Policy,
    ) PendingStorageError!PendingDatagramStorage {
        const payload_size = std.math.mul(usize, count, policy.payload_stride) catch return error.StorageOverflow;
        const entries = try allocator.alloc(pending.Entry, count);
        errdefer allocator.free(entries);
        const payloads = try allocator.alloc(u8, payload_size);
        errdefer allocator.free(payloads);
        const terminals = try allocator.alloc(pending.Terminal, count);
        errdefer allocator.free(terminals);
        return .{ .store = try pending.Store.init(.{
            .entries = entries,
            .payloads = payloads,
            .terminals = terminals,
        }, policy) };
    }

    pub fn deinit(storage: *PendingDatagramStorage, allocator: std.mem.Allocator) void {
        std.debug.assert(storage.store.pending_count == 0);
        std.debug.assert(storage.store.terminal_count == 0);
        allocator.free(storage.store.storage.terminals);
        allocator.free(storage.store.storage.payloads);
        allocator.free(storage.store.storage.entries);
    }
};

/// Returns bounded connection storage; only initialization allocates.
pub fn connection_table(comptime capacity: usize) type {
    const Pool = pool.freelist_pool(Connection, capacity);
    return struct {
        const Self = @This();

        pool: Pool,
        /// Never wraps: exhausted worker identities reject further admission.
        generation: u64 = 0,

        pub fn init() !Self {
            return .{ .pool = try Pool.init() };
        }

        pub fn from_slices(storage: []Connection, indices: []usize) !Self {
            return .{ .pool = try Pool.from_slices(storage, indices) };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.pool.count_active() == 0);
            self.pool.deinit();
        }

        pub fn acquire(self: *Self, owner: *anyopaque, native: *c.lsquic_conn) ?*Connection {
            if (self.generation == std.math.maxInt(u64)) return null;
            const connection = self.pool.acquire() orelse return null;
            const index = self.pool.index_of(connection) orelse unreachable;
            self.generation += 1;
            connection.* = .{
                .handle = .{ .index = index, .generation = self.generation },
                .owner = owner,
                .native = native,
            };
            return connection;
        }

        /// Resolves occupied storage, including a closed slot with stream leases.
        pub fn find(self: *Self, handle: ConnectionHandle) ?*Connection {
            if (handle.generation == 0 or !self.pool.is_active(handle.index)) return null;
            const connection = &self.pool.storage[handle.index];
            if (connection.handle.generation != handle.generation) return null;
            return connection;
        }

        pub fn retain(self: *Self, handle: ConnectionHandle, lease: *StreamLease) bool {
            if (lease.active) return false;
            const connection = self.find(handle) orelse return false;
            if (connection.native == null or connection.stream_count == std.math.maxInt(usize)) return false;
            connection.stream_count += 1;
            lease.* = .{ .connection = handle, .active = true };
            return true;
        }

        /// Releases a stream without consulting a possibly destroyed native conn.
        pub fn release(self: *Self, lease: *StreamLease) bool {
            if (!lease.active) return false;
            const connection = self.find(lease.connection) orelse return false;
            if (connection.stream_count == 0) return false;
            lease.active = false;
            connection.stream_count -= 1;
            if (connection.native == null and connection.stream_count == 0) {
                std.debug.assert(connection.session_count == 0);
                std.debug.assert(self.pool.release(connection));
            }
            return true;
        }

        /// The caller clears native connctx before this transition can reuse it.
        pub fn close(self: *Self, handle: ConnectionHandle) bool {
            const connection = self.find(handle) orelse return false;
            if (connection.native == null) return false;
            connection.native = null;
            if (connection.stream_count == 0) {
                std.debug.assert(connection.session_count == 0);
                std.debug.assert(self.pool.release(connection));
            }
            return true;
        }

        /// A completed peer snapshot is immutable for this connection generation.
        pub fn cache_peer(self: *Self, handle: ConnectionHandle, peer: backend.Peer) bool {
            const connection = self.find(handle) orelse return false;
            if (connection.native == null or connection.peer != null) return false;
            connection.peer = peer;
            return true;
        }
    };
}
