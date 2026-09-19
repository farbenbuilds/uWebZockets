const std = @import("std");
const varint = @import("varint.zig");

/// Largest stream count allowed by the draft session flow controller.
pub const max_stream_count: u64 = 1 << 60;

/// Returns whether an ID can identify a client-initiated bidirectional stream.
pub fn valid_session_id(session_id: u64) bool {
    return session_id <= varint.max_quic_varint and session_id & 0x03 == 0;
}

/// Lifecycle state recorded for one WebTransport session.
pub const SessionState = enum(u8) {
    /// CONNECT validation succeeded but the response is not final.
    accepting,
    /// The CONNECT response established the session.
    established,
    /// The application has been asked to begin graceful shutdown.
    draining,
    /// The session is terminal.
    closed,
};

/// Generation-checked reference to one active WebTransport session.
///
/// A handle remains valid only until that session is closed. Callers may copy
/// handles but must not construct them or retain them across `close`.
pub const SessionHandle = struct {
    /// Fixed slab slot occupied by the session.
    index: usize,
    /// Slot generation that prevents aliases after slot reuse.
    generation: u64,
};

/// Failures from fixed-capacity session bookkeeping.
pub const SessionError = error{
    /// The CONNECT stream ID was not a client-initiated bidirectional ID.
    InvalidSessionId,
    /// The session ID already identifies an active session.
    DuplicateSession,
    /// Flow control is disabled and another session remains open.
    TooManySessions,
    /// Every compile-time slot is occupied.
    CapacityExceeded,
    /// A slot exhausted its generation space and cannot safely be reused.
    GenerationExhausted,
    /// The handle is closed, superseded, or outside this slab.
    StaleHandle,
    /// The requested lifecycle transition is not permitted.
    InvalidTransition,
};

/// Returns fixed-capacity, allocation-free session lifecycle storage.
///
/// `capacity` bounds simultaneous sessions. Closing a session releases its slot;
/// per-slot generations ensure old handles cannot alias a later occupant. The
/// zero value is ready for use. Keep one stable instance and do not copy it
/// after mutation because handles are meaningful only for their source slab.
pub fn session_slab(comptime capacity: usize) type {
    if (capacity == 0) @compileError("WebTransport session capacity must be greater than zero");

    return struct {
        const Self = @This();

        /// Session IDs indexed by slot; only active entries are meaningful.
        session_ids: [capacity]u64 = .{0} ** capacity,
        /// Lifecycle states indexed by slot; callers must not mutate them.
        states: [capacity]SessionState = .{.closed} ** capacity,
        /// Current generation for each slot; callers must not mutate it.
        generations: [capacity]u64 = .{0} ** capacity,
        /// Slots occupied by active sessions; callers must not mutate it.
        active: std.StaticBitSet(capacity) = .empty,
        /// Number of active sessions; callers must not mutate it.
        active_count: usize = 0,

        /// Records an accepted CONNECT stream and returns its stable handle.
        ///
        /// Without negotiated flow control, at most one active session is
        /// permitted. Closed slots are reusable. All failures leave the slab
        /// unchanged.
        pub fn open(self: *Self, session_id: u64, use_flow_control: bool) SessionError!SessionHandle {
            if (!valid_session_id(session_id)) return error.InvalidSessionId;
            if (self.find(session_id) != null) return error.DuplicateSession;
            if (!use_flow_control and self.active_count != 0) return error.TooManySessions;

            var slot: ?usize = null;
            var has_reusable_slot = false;
            for (0..capacity) |index| {
                if (self.active.isSet(index)) continue;
                has_reusable_slot = true;
                if (self.generations[index] == std.math.maxInt(u64)) continue;
                slot = index;
                break;
            }
            const index = slot orelse {
                if (has_reusable_slot) return error.GenerationExhausted;
                return error.CapacityExceeded;
            };

            self.generations[index] += 1;
            self.session_ids[index] = session_id;
            self.states[index] = .accepting;
            self.active.set(index);
            self.active_count += 1;
            return .{ .index = index, .generation = self.generations[index] };
        }

        /// Returns the active handle for `session_id`, or `null` if absent.
        pub fn find(self: *const Self, session_id: u64) ?SessionHandle {
            var iterator = self.active.iterator(.{});
            while (iterator.next()) |slot| {
                if (self.session_ids[slot] != session_id) continue;
                return .{ .index = slot, .generation = self.generations[slot] };
            }
            return null;
        }

        /// Advances an accepting session to established.
        pub fn establish(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            if (self.states[slot] != .accepting) return error.InvalidTransition;
            self.states[slot] = .established;
        }

        /// Advances an established session to draining.
        ///
        /// Repeating the drain transition is idempotent. Accepting sessions
        /// cannot begin draining before establishment.
        pub fn drain(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            if (self.states[slot] == .draining) return;
            if (self.states[slot] != .established) return error.InvalidTransition;
            self.states[slot] = .draining;
        }

        /// Closes an active session and releases its slot for reuse.
        ///
        /// The supplied handle and all of its copies become stale on return.
        pub fn close(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            self.states[slot] = .closed;
            self.active.unset(slot);
            self.active_count -= 1;
        }

        /// Returns the state of an active generation-checked handle.
        pub fn state(self: *const Self, handle: SessionHandle) SessionError!SessionState {
            const slot = try self.validate_handle(handle);
            return self.states[slot];
        }

        /// Returns the number of active sessions in constant time.
        pub fn open_count(self: *const Self) usize {
            return self.active_count;
        }

        fn validate_handle(self: *const Self, handle: SessionHandle) SessionError!usize {
            if (handle.index >= capacity) return error.StaleHandle;
            if (!self.active.isSet(handle.index)) return error.StaleHandle;
            if (self.generations[handle.index] != handle.generation) return error.StaleHandle;
            return handle.index;
        }
    };
}
