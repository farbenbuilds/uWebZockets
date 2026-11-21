const capsule = @import("capsule.zig");
const early = @import("early_debt.zig");
const flow = @import("session_flow.zig");
const max_data = @import("varint.zig").max_quic_varint;
const max_streams = @import("session.zig").max_stream_count;

/// Receipt, reclamation and startup import failures preserve the complete state.
pub const Error = early.ImportError;
/// Credit effects distinguish deferred sender wakeups from peer diagnostics.
pub const CapsuleAction = enum(u8) { data_credit, stream_credit, peer_blocked, ignored };

/// Validated limits negotiate flow only when both endpoints declare intent.
pub fn negotiated(local: flow.Limits, peer: flow.Limits) bool {
    const local_intent = local.data != 0 or local.streams_bidi != 0 or local.streams_uni != 0;
    const peer_intent = peer.data != 0 or peer.streams_bidi != 0 or peer.streams_uni != 0;
    return local_intent and peer_intent;
}

/// Caller-owned negotiated budgets; Native callbacks and lifecycle stay outside.
pub const State = struct {
    send: flow.Budget,
    receive: flow.Receiver,
    credits: flow.CreditOutput = .{},

    /// Import retained debt before an application can approve or observe the session.
    pub fn init(local: flow.Limits, peer: flow.Limits, debt: early.Debt) Error!State {
        const send = try flow.Budget.init(peer);
        var receive = try flow.Receiver.init(local);
        try debt.import_into(&receive);
        return .{ .send = send, .receive = receive };
    }

    /// Native supplies exact-once usage; reclamation never refunds cumulative debit.
    pub fn apply_receive(state: *State, delta: early.Debt) Error!void {
        var combined = early.Debt{ .used = state.receive.budget.used, .reclaimed = state.receive.reclaimed };
        try combined.add(delta);
        const limit = state.receive.budget.limits;
        if (combined.used.data > limit.data or combined.used.streams_bidi > limit.streams_bidi or
            combined.used.streams_uni > limit.streams_uni) return error.FlowControlViolation;
        const desired = flow.Limits{
            .data = state.receive.desired.data + @min(delta.reclaimed.data, max_data - state.receive.desired.data),
            .streams_bidi = state.receive.desired.streams_bidi + @min(delta.reclaimed.streams_bidi, max_streams - state.receive.desired.streams_bidi),
            .streams_uni = state.receive.desired.streams_uni + @min(delta.reclaimed.streams_uni, max_streams - state.receive.desired.streams_uni),
        };
        state.receive.budget.used = combined.used;
        state.receive.reclaimed = combined.reclaimed;
        state.receive.desired = desired;
    }

    /// Lifecycle and unknown capsules are handled by the owning CONNECT path.
    pub fn apply_capsule(state: *State, value: capsule.Capsule) flow.FlowError!CapsuleAction {
        switch (value) {
            .max_data => |maximum| {
                try state.send.grant(.data, maximum);
                return .data_credit;
            },
            .max_streams_bidi => |maximum| {
                try state.send.grant(.streams_bidi, maximum);
                return .stream_credit;
            },
            .max_streams_uni => |maximum| {
                try state.send.grant(.streams_uni, maximum);
                return .stream_credit;
            },
            .data_blocked => |maximum| {
                if (maximum > max_data) return error.FlowControlViolation;
                return .peer_blocked;
            },
            .streams_blocked_bidi, .streams_blocked_uni => |maximum| {
                if (maximum > max_streams) return error.FlowControlViolation;
                return .peer_blocked;
            },
            .drain_session, .close_session, .unknown => return .ignored,
        }
    }
};
