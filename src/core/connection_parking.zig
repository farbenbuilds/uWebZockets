//! Connection-owned delay slots. Transitions never run timers or application code.

const response = @import("../http/response.zig");
const timer_wheel = @import("timer_wheel.zig");

/// Resumes a handler on the owning connection's event loop.
pub const ResumeFn = *const fn (context: *anyopaque) void;

/// Borrowed handler continuation retained until expiry or cancellation.
pub const Resume = struct {
    context: *anyopaque,
    callback: ResumeFn,
};

/// Borrowed response fields retained until expiry or cancellation.
pub const Completion = struct {
    token: response.AsyncResponse,
    status: []const u8,
    headers: []const u8,
    body: []const u8,
};

/// Exactly one operation retained by an armed parking slot.
pub const Action = union(enum) {
    handler: Resume,
    complete: Completion,
};

/// Embedded timer and pending operation; its address stays fixed while armed.
pub const Slot = struct {
    connection: *anyopaque = undefined,
    pending: ?Action = null,
    node: timer_wheel.TimerNode = .{},
};

/// Taken by value before re-arming idle timers or invoking application code.
pub const Expiry = struct {
    connection: *anyopaque,
    action: Action,
};

/// Replaces one pending operation, counting a slot only on its first arm.
pub fn park(slot: *Slot, parked_count: *u16, connection: *anyopaque, action: Action) void {
    if (slot.pending == null) parked_count.* +|= 1;
    slot.connection = connection;
    slot.pending = action;
}

/// Clears the slot exactly once for expiry or cancellation, without running it.
pub fn take(slot: *Slot, parked_count: *u16) ?Expiry {
    const action = slot.pending orelse return null;
    slot.pending = null;
    if (parked_count.* != 0) parked_count.* -= 1;
    return .{ .connection = slot.connection, .action = action };
}
