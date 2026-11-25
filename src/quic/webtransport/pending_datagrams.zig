const std = @import("std");
const identity = @import("identity.zig");

const no_index = std.math.maxInt(usize);

/// A native CONNECT identifier scoped to one connection generation.
pub const SessionKey = struct {
    connection: identity.ConnectionHandle = .{},
    session_id: u64 = 0,
};

/// Pending metadata; payload stays in this entry's fixed physical stride.
pub const Entry = struct {
    key: SessionKey = .{},
    deadline_us: u64 = 0,
    payload_length: usize = 0,
    previous: usize = no_index,
    next: usize = no_index,
};

/// A terminal identity retained until its exact connection generation clears.
pub const Terminal = struct {
    key: SessionKey = .{},
    active: bool = false,
};

/// Caller-owned startup regions; all slices must outlive their Store.
pub const Storage = struct {
    entries: []Entry,
    payloads: []u8,
    terminals: []Terminal,
};

/// Independent physical payload, per-connection count, and supplied-time bounds.
pub const Policy = struct {
    payload_stride: usize,
    per_connection_limit: usize,
    lifetime_us: u64,
};

/// One payload copied into caller output and already removed from the queue.
pub const TakenDatagram = struct {
    payload_length: usize,
};

/// Geometry failures are detected before caller storage is mutated.
pub const InitError = error{
    InvalidCapacity,
    InvalidStride,
    InvalidConnectionLimit,
    StorageOverflow,
    PayloadStorageTooSmall,
};

/// Expiry may reclaim old entries; these failures preserve every retained entry.
pub const EnqueueError = error{ RetiredSession, PayloadTooLarge, ConnectionLimit, Full };

/// A small output preserves the matching entry and leaves output untouched.
pub const TakeError = error{BufferTooSmall};

/// Exhaustion still purges the key; the caller must suppress further early traffic.
pub const RetireResult = enum(u8) { remembered, exhausted };

/// Fixed-stride pending traffic with indexed FIFO/free lists and no allocations.
///
/// Only Store operations may mutate metadata after init. Payload input/output
/// must not alias the Store's backing regions. Time and identities are supplied
/// by the owning engine; no callback runs while a queue mutation is in progress.
pub const Store = struct {
    storage: Storage,
    policy: Policy,
    active_head: usize = no_index,
    active_tail: usize = no_index,
    free_head: usize = no_index,
    pending_count: usize = 0,
    terminal_count: usize = 0,

    pub fn init(storage: Storage, policy: Policy) InitError!Store {
        const terminal_only = storage.entries.len == 0;
        if (terminal_only and (storage.terminals.len == 0 or policy.payload_stride != 0)) return error.InvalidCapacity;
        if (!terminal_only and policy.payload_stride == 0) return error.InvalidStride;
        if (policy.per_connection_limit == 0) return error.InvalidConnectionLimit;
        if (!terminal_only and storage.entries.len > std.math.maxInt(usize) / policy.payload_stride) return error.StorageOverflow;
        if (storage.payloads.len < storage.entries.len * policy.payload_stride) return error.PayloadStorageTooSmall;
        for (storage.entries, 0..) |*entry, index| {
            entry.* = .{ .next = if (index + 1 == storage.entries.len) no_index else index + 1 };
        }
        for (storage.terminals) |*terminal| terminal.* = .{};
        return .{ .storage = storage, .policy = policy, .free_head = if (terminal_only) no_index else 0 };
    }

    /// Copies one payload after expiry and all admission bounds are checked.
    pub fn enqueue(store: *Store, key: SessionKey, payload: []const u8, now_us: u64) EnqueueError!void {
        store.expire(now_us);
        if (store.is_retired(key)) return error.RetiredSession;
        if (payload.len > store.policy.payload_stride) return error.PayloadTooLarge;
        if (store.connection_count(key.connection) >= store.policy.per_connection_limit) return error.ConnectionLimit;
        const index = store.free_head;
        if (index == no_index) return error.Full;
        const entry = &store.storage.entries[index];
        store.free_head = entry.next;
        entry.* = .{
            .key = key,
            .deadline_us = now_us +| store.policy.lifetime_us,
            .payload_length = payload.len,
            .previous = store.active_tail,
        };
        const start = index * store.policy.payload_stride;
        @memcpy(store.storage.payloads[start..][0..payload.len], payload);
        if (store.active_tail == no_index) {
            store.active_head = index;
        } else {
            store.storage.entries[store.active_tail].next = index;
        }
        store.active_tail = index;
        store.pending_count += 1;
    }

    /// Copies the oldest matching payload and removes it before caller delivery.
    pub fn take_into(store: *Store, key: SessionKey, now_us: u64, output: []u8) TakeError!?TakenDatagram {
        store.expire(now_us);
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            if (!same_key(entry.key, key)) {
                index = entry.next;
                continue;
            }
            const length = entry.payload_length;
            if (output.len < length) return error.BufferTooSmall;
            const start = index * store.policy.payload_stride;
            @memcpy(output[0..length], store.storage.payloads[start..][0..length]);
            store.remove(index);
            return .{ .payload_length = length };
        }
        return null;
    }

    /// Purges this exact key even when no terminal slot can remember it.
    pub fn retire(store: *Store, key: SessionKey) RetireResult {
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            const next = entry.next;
            if (same_key(entry.key, key)) store.remove(index);
            index = next;
        }
        if (store.is_retired(key)) return .remembered;
        for (store.storage.terminals) |*terminal| {
            if (terminal.active) continue;
            terminal.* = .{ .key = key, .active = true };
            store.terminal_count += 1;
            return .remembered;
        }
        return .exhausted;
    }

    /// Terminal keys remain exact until their connection generation is cleared.
    pub fn is_retired(store: *const Store, key: SessionKey) bool {
        for (store.storage.terminals) |terminal| {
            if (terminal.active and same_key(terminal.key, key)) return true;
        }
        return false;
    }

    /// Connection teardown also releases its permanently remembered terminals.
    pub fn clear_connection(store: *Store, connection: identity.ConnectionHandle) void {
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            const next = entry.next;
            if (same_connection(entry.key.connection, connection)) store.remove(index);
            index = next;
        }
        for (store.storage.terminals) |*terminal| {
            if (!terminal.active or !same_connection(terminal.key.connection, connection)) continue;
            terminal.active = false;
            store.terminal_count -= 1;
        }
    }

    /// Equality expires an entry, including a deadline saturated at maxInt(u64).
    pub fn expire(store: *Store, now_us: u64) void {
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            const next = entry.next;
            if (entry.deadline_us <= now_us) store.remove(index);
            index = next;
        }
    }

    /// Earliest pending expiry; terminal identities never contribute a deadline.
    pub fn next_deadline(store: *const Store) ?u64 {
        var earliest: ?u64 = null;
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            if (earliest == null or entry.deadline_us < earliest.?) earliest = entry.deadline_us;
            index = entry.next;
        }
        return earliest;
    }

    fn connection_count(store: *const Store, connection: identity.ConnectionHandle) usize {
        var count: usize = 0;
        var index = store.active_head;
        while (index != no_index) {
            const entry = &store.storage.entries[index];
            if (same_connection(entry.key.connection, connection)) count += 1;
            index = entry.next;
        }
        return count;
    }

    fn remove(store: *Store, index: usize) void {
        const entry = &store.storage.entries[index];
        if (entry.previous == no_index) {
            store.active_head = entry.next;
        } else {
            store.storage.entries[entry.previous].next = entry.next;
        }
        if (entry.next == no_index) {
            store.active_tail = entry.previous;
        } else {
            store.storage.entries[entry.next].previous = entry.previous;
        }
        entry.previous = no_index;
        entry.next = store.free_head;
        store.free_head = index;
        store.pending_count -= 1;
    }
};

fn same_key(first: SessionKey, second: SessionKey) bool {
    return first.session_id == second.session_id and same_connection(first.connection, second.connection);
}

fn same_connection(first: identity.ConnectionHandle, second: identity.ConnectionHandle) bool {
    return first.index == second.index and first.generation == second.generation;
}
