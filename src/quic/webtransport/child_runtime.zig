const identity = @import("identity.zig");
const session = @import("session.zig");
const child_ledger = @import("child_ledger.zig");
const RouteId = @import("../../router/datagram.zig").RouteId;
const stream_api = @import("stream_api.zig");

/// Sending facts occupy the existing stream sidecar, independently of RX.
pub const TransmitState = struct {
    published: bool = false,
    finish_requested: bool = false,
    writable_requested: bool = false,
    accepted_bytes: u64 = 0,
};

/// Native observations supplied by the I/O boundary after a nonempty write.
pub const WriteStatus = enum(u8) { progress, blocked, closed, failed };
/// Failure after a positive result still transfers that prefix to native storage.
pub const WriteAttempt = struct { result: stream_api.WriteError!usize, failed: bool };

pub fn complete_write(consumed: usize, status: WriteStatus) WriteAttempt {
    if (consumed != 0) return .{ .result = consumed, .failed = status == .closed or status == .failed };
    return switch (status) {
        .progress, .blocked => .{ .result = error.WouldBlock, .failed = false },
        .closed => .{ .result = error.WriteClosed, .failed = false },
        .failed => .{ .result = error.WriteFailed, .failed = true },
    };
}

/// Direction is independent of the native backend enum.
pub const Direction = enum(u8) { uni, bidi };
/// A global engine stream slot; generation zero is never publicly resolvable.
pub const Location = struct { index: usize = 0, generation: u64 = 0 };
/// Native child facts captured before an application parent is available.
pub const Metadata = struct {
    connection: identity.ConnectionHandle,
    session_id: u64,
    stream_id: u64,
    receive_prefix_size: u8,
    direction: Direction,
    location: Location = .{},
};
/// Full transport IDs and both owner generations identify one admitted child.
pub const Key = struct {
    connection: identity.ConnectionHandle,
    session: session.SessionHandle,
    session_id: u64,
    stream_id: u64,
    location: Location = .{},
    route: RouteId = @enumFromInt(0),
};
/// Immutable facts supplied to the private open consumer.
pub const Info = struct {
    key: Key,
    route: RouteId,
    direction: Direction,
    receive_prefix_size: u8,
};
/// The first local closing cause survives callback reentry.
pub const CloseReason = stream_api.CloseReason;
/// A close notification owns no borrowed native memory; unknown final stays null.
pub const ClosedEvent = struct {
    key: Key,
    reason: CloseReason,
    code: ?u64,
    final_payload_size: ?u64,
    accounted_bytes: u64,
};
/// Opening is separate from ownership because its callback can cancel reentrantly.
pub const Phase = enum(u8) { waiting_parent, opening, active, closing, closed };
/// Invalid transitions preserve the complete caller-owned state.
pub const StateError = error{ InvalidMetadata, InvalidParent, InvalidTransition, OpenInProgress };

/// Inline lifecycle facts; quotas, clocks, callbacks and native handles stay outside.
pub const State = struct {
    metadata: Metadata,
    deadline_us: u64,
    ledger: child_ledger.Ledger,
    key: ?Key = null,
    route: ?RouteId = null,
    phase: Phase = .waiting_parent,
    open_pending: bool = false,
    consumer_owned: bool = false,
    close_delivered: bool = false,
    pending_reserved: bool = false,
    pending_taken: bool = false,
    cancel_reason: ?CloseReason = null,
    cancel_code: ?u64 = null,

    /// A peer child always has an actual receive prefix; endpoint role is external.
    pub fn init(metadata: Metadata, deadline_us: u64) StateError!State {
        if (metadata.connection.generation == 0 or !session.valid_session_id(metadata.session_id) or
            metadata.stream_id > (1 << 62) - 1 or metadata.receive_prefix_size < 3 or
            (metadata.direction == .uni) != (metadata.stream_id & 2 != 0)) return error.InvalidMetadata;
        return .{
            .metadata = metadata,
            .deadline_us = deadline_us,
            .ledger = child_ledger.Ledger.init(metadata.receive_prefix_size) catch return error.InvalidMetadata,
        };
    }

    /// Transfers one bounded waiting-slot reservation to this state.
    pub fn reserve_pending(state: *State) bool {
        if (state.phase != .waiting_parent or state.pending_reserved or state.pending_taken) return false;
        state.pending_reserved = true;
        return true;
    }

    /// Root decrements its counters only when this consumes the reservation.
    pub fn take_pending(state: *State) bool {
        if (!state.pending_reserved) return false;
        state.pending_reserved = false;
        state.pending_taken = true;
        return true;
    }

    /// Captures parent identity before any open callback can reenter.
    pub fn begin_open(state: *State, parent: session.SessionHandle, route: RouteId) StateError!Info {
        if (state.phase != .waiting_parent) return error.InvalidTransition;
        if (parent.generation == 0) return error.InvalidParent;
        const key = Key{
            .connection = state.metadata.connection,
            .session = parent,
            .session_id = state.metadata.session_id,
            .stream_id = state.metadata.stream_id,
            .location = state.metadata.location,
            .route = route,
        };
        state.key = key;
        state.route = route;
        state.open_pending = true;
        state.phase = .opening;
        return .{
            .key = key,
            .route = route,
            .direction = state.metadata.direction,
            .receive_prefix_size = state.metadata.receive_prefix_size,
        };
    }

    /// Acceptance owns a close notification even if its callback already cancelled.
    pub fn complete_open(state: *State, accepted: bool) StateError!void {
        if (!state.open_pending or (state.phase != .opening and state.phase != .closing)) return error.InvalidTransition;
        state.consumer_owned = accepted;
        state.open_pending = false;
        if (state.phase == .closing) return;
        if (accepted) {
            state.phase = .active;
            return;
        }
        _ = state.begin_close(.rejected, null);
    }

    /// The boundary validates native error codes before recording the first cause.
    pub fn begin_close(state: *State, reason: CloseReason, code: ?u64) bool {
        if (state.cancel_reason != null or state.phase == .closed) return false;
        state.cancel_reason = reason;
        state.cancel_code = code;
        state.phase = .closing;
        return true;
    }

    /// Call only at native close, after the authoritative receive snapshot.
    pub fn finish_close(state: *State) StateError!?ClosedEvent {
        if (state.phase == .closed) return null;
        if (state.open_pending) return error.OpenInProgress;
        if (state.consumer_owned and state.key == null) return error.InvalidTransition;
        const event: ?ClosedEvent = if (state.consumer_owned and !state.close_delivered) .{
            .key = state.key.?,
            .reason = state.cancel_reason orelse if (state.ledger.receive_terminal == .reset) .peer_reset else .completed,
            .code = if (state.cancel_reason != null) state.cancel_code else if (state.ledger.receive_terminal == .reset) state.ledger.reset_error else null,
            .final_payload_size = state.ledger.final_payload_size,
            .accounted_bytes = state.ledger.accounted_bytes,
        } else null;
        _ = state.ledger.close();
        state.phase = .closed;
        if (event != null) state.close_delivered = true;
        return event;
    }
};
