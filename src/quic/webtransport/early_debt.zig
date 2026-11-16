const flow = @import("session_flow.zig");
const identity = @import("identity.zig");
const max_data = @import("varint.zig").max_quic_varint;
const max_streams = @import("session.zig").max_stream_count;

/// Full session identity scoped to a worker connection generation.
pub const SessionKey = @import("pending_datagrams.zig").SessionKey;
/// Geometry errors are detected before caller storage changes.
pub const InitError = error{ InvalidCapacity, InvalidConnectionLimit };
/// Invalid updates preserve every aggregate and store entry.
pub const UpdateError = error{ InvalidKey, CapacityExceeded, SizeOverflow, InvalidReclamation };
/// Receiver limit errors also preserve the incoming debt.
pub const ImportError = UpdateError || flow.FlowError;

/// Lifetime debt survives child destruction; native callbacks supply exact-once deltas.
pub const Debt = struct {
    used: flow.Limits = .{},
    reclaimed: flow.Limits = .{},

    /// Reclamation-only deltas may refer to usage retained by earlier observations.
    pub fn add(debt: *Debt, delta: Debt) UpdateError!void {
        const used = try sum_limits(debt.used, delta.used);
        const reclaimed = try sum_limits(debt.reclaimed, delta.reclaimed);
        if (!reclamation_valid(used, reclaimed)) return error.InvalidReclamation;
        debt.* = .{ .used = used, .reclaimed = reclaimed };
    }

    /// Import before admission; ownership may be removed from the store only on success.
    pub fn import_into(debt: Debt, receiver: *flow.Receiver) ImportError!void {
        if (!reclamation_valid(debt.used, debt.reclaimed)) return error.InvalidReclamation;
        var combined = Debt{ .used = receiver.budget.used, .reclaimed = receiver.reclaimed };
        try combined.add(debt);
        const limit = receiver.budget.limits;
        if (combined.used.data > limit.data or combined.used.streams_bidi > limit.streams_bidi or
            combined.used.streams_uni > limit.streams_uni) return error.FlowControlViolation;
        const desired = flow.Limits{
            .data = try replenish(receiver.desired.data, debt.reclaimed.data, max_data),
            .streams_bidi = try replenish(receiver.desired.streams_bidi, debt.reclaimed.streams_bidi, max_streams),
            .streams_uni = try replenish(receiver.desired.streams_uni, debt.reclaimed.streams_uni, max_streams),
        };
        receiver.budget.used = combined.used;
        receiver.reclaimed = combined.reclaimed;
        receiver.desired = desired;
    }
};

/// One retained SID, independent of the lifetime of any corresponding child.
pub const Entry = struct {
    key: SessionKey = .{},
    debt: Debt = .{},
    active: bool = false,
};

/// Caller-owned SID buckets; a connection index scans only its fixed partition.
///
/// Only store operations mutate entries after init. Entries have no expiration;
/// dropping debt requires successful transfer, permanent retirement, or teardown.
pub const Store = struct {
    entries: []Entry,
    per_connection_limit: usize,
    active_count: usize = 0,

    pub fn init(entries: []Entry, per_connection_limit: usize) InitError!Store {
        if (per_connection_limit == 0) return error.InvalidConnectionLimit;
        if (entries.len == 0 or entries.len % per_connection_limit != 0) return error.InvalidCapacity;
        for (entries) |*entry| entry.* = .{};
        return .{ .entries = entries, .per_connection_limit = per_connection_limit };
    }

    /// Existing keys remain writable even when their connection's bucket is full.
    pub fn add(store: *Store, key: SessionKey, delta: Debt) UpdateError!void {
        const entries = store.bucket(key) orelse return error.InvalidKey;
        var free: ?*Entry = null;
        for (entries) |*entry| {
            if (!entry.active) {
                free = free orelse entry;
                continue;
            }
            if (same_key(entry.key, key)) return entry.debt.add(delta);
        }
        var debt = Debt{};
        try debt.add(delta);
        if (empty(debt.used) and empty(debt.reclaimed)) return;
        const entry = free orelse return error.CapacityExceeded;
        entry.* = .{ .key = key, .debt = debt, .active = true };
        store.active_count += 1;
    }

    /// Copying prevents callers from mutating retained counters outside checked addition.
    pub fn find(store: *const Store, key: SessionKey) ?Debt {
        const entry = store.lookup(key) orelse return null;
        return entry.debt;
    }

    /// Move ownership only after the destination has accepted the retained accounting.
    pub fn take(store: *Store, key: SessionKey) ?Debt {
        const entry = store.lookup(key) orelse return null;
        const debt = entry.debt;
        entry.* = .{};
        store.active_count -= 1;
        return debt;
    }

    /// Retirement must prevent subsequent admission before discarding this debt.
    pub fn forget(store: *Store, key: SessionKey) bool {
        const entry = store.lookup(key) orelse return false;
        entry.* = .{};
        store.active_count -= 1;
        return true;
    }

    /// A stale teardown must not clear another generation occupying the same bucket.
    pub fn clear_connection(store: *Store, connection: identity.ConnectionHandle) void {
        const entries = store.bucket(.{ .connection = connection }) orelse return;
        for (entries) |*entry| {
            if (!entry.active or !same_connection(entry.key.connection, connection)) continue;
            entry.* = .{};
            store.active_count -= 1;
        }
    }

    fn lookup(store: *const Store, key: SessionKey) ?*Entry {
        const entries = store.bucket(key) orelse return null;
        for (entries) |*entry| {
            if (entry.active and same_key(entry.key, key)) return entry;
        }
        return null;
    }

    fn bucket(store: *const Store, key: SessionKey) ?[]Entry {
        if (key.connection.generation == 0 or key.session_id > max_data or key.session_id & 3 != 0) return null;
        if (key.connection.index >= store.entries.len / store.per_connection_limit) return null;
        const start = key.connection.index * store.per_connection_limit;
        return store.entries[start..][0..store.per_connection_limit];
    }
};

fn sum_limits(current: flow.Limits, delta: flow.Limits) UpdateError!flow.Limits {
    if (current.data > max_data or current.streams_bidi > max_streams or current.streams_uni > max_streams) {
        return error.SizeOverflow;
    }
    if (delta.data > max_data - current.data or delta.streams_bidi > max_streams - current.streams_bidi or
        delta.streams_uni > max_streams - current.streams_uni) return error.SizeOverflow;
    return .{
        .data = current.data + delta.data,
        .streams_bidi = current.streams_bidi + delta.streams_bidi,
        .streams_uni = current.streams_uni + delta.streams_uni,
    };
}

fn replenish(current: u64, reclaimed: u64, maximum: u64) UpdateError!u64 {
    if (current > maximum) return error.SizeOverflow;
    return current + @min(reclaimed, maximum - current);
}

fn reclamation_valid(used: flow.Limits, reclaimed: flow.Limits) bool {
    return reclaimed.data <= used.data and reclaimed.streams_bidi <= used.streams_bidi and reclaimed.streams_uni <= used.streams_uni;
}

fn empty(limits: flow.Limits) bool {
    return limits.data == 0 and limits.streams_bidi == 0 and limits.streams_uni == 0;
}

fn same_key(first: SessionKey, second: SessionKey) bool {
    return first.session_id == second.session_id and same_connection(first.connection, second.connection);
}

fn same_connection(first: identity.ConnectionHandle, second: identity.ConnectionHandle) bool {
    return first.index == second.index and first.generation == second.generation;
}
