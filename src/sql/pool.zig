//! Loop-confined leases and bounded FIFO acquisition; no socket effects.

pub const max_connections = 16;
pub const max_waiters = 64;

/// Stable failure modes of worker-local lease admission.
pub const PoolError = error{ InvalidPoolSize, InvalidWaitCapacity, PoolExhausted, WrongWorker, WrongPool, StaleLease, StaleWait, InvalidSlot, InvalidState, DeadlineExceeded, Stopped };
/// One generation-checked exclusive connection reservation.
pub const Lease = struct { owner: *const Pool, worker_index: usize, index: usize, generation: u64 };
/// Generation-checked bounded queue entry.
pub const WaitHandle = struct { owner: *const Pool, index: usize, generation: u64 };
/// Terminal acquisition result delivered on the owning worker.
pub const AcquireOutcome = union(enum) { lease: Lease, failure: PoolError };
/// Receives exactly one acquisition outcome.
pub const AcquireCallback = *const fn (context: *anyopaque, outcome: AcquireOutcome) void;
/// Counters sampled without synchronization on the owning worker.
pub const Stats = struct { active: usize = 0, idle: usize = 0, waiting: usize = 0, failed: usize = 0, reconnects: u64 = 0 };
/// Connection admission state, independent of transport completions.
pub const State = enum { connecting, idle, busy, failed };
/// Fixed connection metadata.
pub const Slot = struct { state: State = .connecting, generation: u64 = 0, attempts: u8 = 0 };
/// Borrowed acquisition continuation, removed before callback dispatch.
pub const Waiter = struct {
    context: *anyopaque = undefined,
    callback: ?AcquireCallback = null,
    deadline_ms: u64 = 0,
    sequence: u64 = 0,
    generation: u64 = 0,
};

/// Fixed-capacity single-worker pool; never copied after requests are queued.
pub const Pool = struct {
    slots: [max_connections]Slot = [_]Slot{.{}} ** max_connections,
    waiters: [max_waiters]Waiter = [_]Waiter{.{}} ** max_waiters,
    worker_index: usize,
    connection_count: usize,
    wait_capacity: usize,
    next_sequence: u64 = 0,
    waiting_count: usize = 0,
    reconnects: u64 = 0,
    stopped: bool = false,

    pub fn init(worker_index: usize, connections: usize, wait_capacity: usize) PoolError!Pool {
        if (connections < 8 or connections > max_connections) return error.InvalidPoolSize;
        if (wait_capacity > max_waiters) return error.InvalidWaitCapacity;
        return .{ .worker_index = worker_index, .connection_count = connections, .wait_capacity = wait_capacity };
    }

    pub fn mark_ready(self: *Pool, index: usize) PoolError!void {
        if (index >= self.connection_count) return error.InvalidSlot;
        const slot = &self.slots[index];
        if (slot.state != .connecting and slot.state != .failed) return error.InvalidState;
        slot.state = .idle;
        slot.attempts = 0;
    }

    pub fn acquire(self: *Pool) PoolError!Lease {
        if (self.stopped) return error.Stopped;
        if (self.waiting_count != 0) return error.PoolExhausted;
        return self.acquire_idle();
    }

    fn acquire_idle(self: *Pool) PoolError!Lease {
        if (self.stopped) return error.Stopped;
        for (self.slots[0..self.connection_count], 0..) |*slot, index| {
            if (slot.state != .idle) continue;
            slot.state = .busy;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            return .{ .owner = self, .worker_index = self.worker_index, .index = index, .generation = slot.generation };
        }
        return error.PoolExhausted;
    }

    pub fn validate(self: *const Pool, lease: Lease) PoolError!void {
        if (lease.worker_index != self.worker_index) return error.WrongWorker;
        if (lease.owner != self) return error.WrongPool;
        if (lease.index >= self.connection_count) return error.StaleLease;
        const slot = self.slots[lease.index];
        if (slot.state != .busy or slot.generation != lease.generation) return error.StaleLease;
    }

    pub fn release(self: *Pool, lease: Lease, healthy: bool) PoolError!void {
        try self.validate(lease);
        self.slots[lease.index].state = if (healthy) .idle else .failed;
    }

    pub fn mark_failed(self: *Pool, index: usize) PoolError!void {
        if (index >= self.connection_count) return error.InvalidSlot;
        self.slots[index].state = .failed;
    }

    pub fn wait(self: *Pool, deadline_ms: u64, context: *anyopaque, callback: AcquireCallback) PoolError!WaitHandle {
        if (self.stopped) return error.Stopped;
        for (self.waiters[0..self.wait_capacity], 0..) |*waiter, index| {
            if (waiter.callback != null) continue;
            self.next_sequence +%= 1;
            waiter.generation +%= 1;
            if (waiter.generation == 0) waiter.generation = 1;
            waiter.context = context;
            waiter.callback = callback;
            waiter.deadline_ms = deadline_ms;
            waiter.sequence = self.next_sequence;
            self.waiting_count += 1;
            return .{ .owner = self, .index = index, .generation = waiter.generation };
        }
        return error.PoolExhausted;
    }

    pub fn cancel_wait(self: *Pool, handle: WaitHandle) PoolError!void {
        if (handle.owner != self) return error.WrongPool;
        if (handle.index >= self.wait_capacity) return error.StaleWait;
        const waiter = &self.waiters[handle.index];
        if (waiter.callback == null or waiter.generation != handle.generation) return error.StaleWait;
        waiter.callback = null;
        self.waiting_count -= 1;
    }

    /// Expired waiters cannot block later FIFO admission.
    pub fn dispatch(self: *Pool, now_ms: u64) void {
        for (self.waiters[0..self.wait_capacity]) |*waiter| {
            if (waiter.callback == null or waiter.deadline_ms > now_ms) continue;
            self.deliver(waiter, .{ .failure = error.DeadlineExceeded });
        }
        var remaining = self.wait_capacity;
        while (remaining > 0) : (remaining -= 1) {
            const waiter = self.oldest_waiter() orelse return;
            const lease = self.acquire_idle() catch return;
            self.deliver(waiter, .{ .lease = lease });
        }
    }

    pub fn stop(self: *Pool) void {
        self.stopped = true;
        for (self.waiters[0..self.wait_capacity]) |*waiter| {
            if (waiter.callback != null) self.deliver(waiter, .{ .failure = error.Stopped });
        }
    }

    pub fn stats(self: *const Pool) Stats {
        var result = Stats{ .reconnects = self.reconnects, .waiting = self.waiting_count };
        for (self.slots[0..self.connection_count]) |slot| switch (slot.state) {
            .busy => result.active += 1,
            .idle => result.idle += 1,
            .failed => result.failed += 1,
            .connecting => {},
        };
        return result;
    }

    /// Exponential backoff with a deterministic per-slot phase avoids a herd.
    pub fn reconnect_delay(self: *Pool, index: usize, base_ms: u64, cap_ms: u64) PoolError!u64 {
        if (index >= self.connection_count) return error.InvalidSlot;
        const slot = &self.slots[index];
        const shift: u6 = @intCast(@min(slot.attempts, 20));
        const exponential = base_ms *| (@as(u64, 1) << shift);
        slot.attempts +|= 1;
        self.reconnects +|= 1;
        return @min(cap_ms, exponential +| (base_ms *| index / self.connection_count));
    }

    fn oldest_waiter(self: *Pool) ?*Waiter {
        var oldest: ?*Waiter = null;
        for (self.waiters[0..self.wait_capacity]) |*waiter| {
            if (waiter.callback == null) continue;
            if (oldest == null or waiter.sequence < oldest.?.sequence) oldest = waiter;
        }
        return oldest;
    }

    fn deliver(self: *Pool, waiter: *Waiter, outcome: AcquireOutcome) void {
        const callback = waiter.callback.?;
        const context = waiter.context;
        waiter.callback = null;
        self.waiting_count -= 1;
        callback(context, outcome);
    }
};
