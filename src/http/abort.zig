const std = @import("std");

/// Stable cancellation reasons shared by RPC, stream, timer, and socket code.
pub const AbortReason = enum(u8) {
    none,
    caller,
    timeout,
    connection_closed,
    shutdown,
};

/// Caller-owned state shared by any number of lightweight signals.
pub const AbortState = struct {
    word: std.atomic.Value(u64) = .init(pack(0, .none)),
};

/// Non-owning cooperative cancellation view.
///
/// The controller that produced a signal must outlive every signal copy.
pub const AbortSignal = struct {
    state: *const AbortState,
    epoch_snapshot: u56,

    pub fn aborted(self: AbortSignal) bool {
        const word = self.state.word.load(.acquire);
        if (unpack_epoch(word) != self.epoch_snapshot) return true;
        return unpack_reason(word) != .none;
    }

    pub fn reason(self: AbortSignal) AbortReason {
        const word = self.state.word.load(.acquire);
        if (unpack_epoch(word) != self.epoch_snapshot) return .connection_closed;
        return unpack_reason(word);
    }

    pub fn checkpoint(self: AbortSignal) error{Aborted}!void {
        if (self.aborted()) return error.Aborted;
    }

    pub fn epoch(self: AbortSignal) u56 {
        return self.epoch_snapshot;
    }
};

/// Owns cancellation state without allocating or hiding lifecycle changes.
pub const AbortController = struct {
    state: AbortState = .{},

    pub fn signal(self: *const AbortController) AbortSignal {
        const word = self.state.word.load(.acquire);
        return .{
            .state = &self.state,
            .epoch_snapshot = unpack_epoch(word),
        };
    }

    /// Publishes the first abort reason. Later aborts cannot replace it.
    pub fn abort(self: *AbortController, reason: AbortReason) bool {
        if (reason == .none) return false;
        var current = self.state.word.load(.acquire);
        while (unpack_reason(current) == .none) {
            const desired = pack(unpack_epoch(current), reason);
            current = self.state.word.cmpxchgWeak(
                current,
                desired,
                .release,
                .acquire,
            ) orelse return true;
        }
        return false;
    }

    /// Starts a new owner lifecycle while permanently invalidating old signals.
    pub fn reset(self: *AbortController) void {
        var current = self.state.word.load(.acquire);
        while (true) {
            const next_epoch = unpack_epoch(current) +% 1;
            current = self.state.word.cmpxchgWeak(
                current,
                pack(next_epoch, .none),
                .acq_rel,
                .acquire,
            ) orelse return;
        }
    }
};

fn pack(epoch: u56, reason: AbortReason) u64 {
    return (@as(u64, epoch) << 8) | @intFromEnum(reason);
}

fn unpack_epoch(word: u64) u56 {
    return @truncate(word >> 8);
}

fn unpack_reason(word: u64) AbortReason {
    return @enumFromInt(@as(u8, @truncate(word)));
}

/// Converts an explicit monotonic deadline into cooperative cancellation.
pub fn abort_if_expired(
    controller: *AbortController,
    now_ms: i64,
    deadline_ms: i64,
) bool {
    if (now_ms < deadline_ms) return false;
    return controller.abort(.timeout);
}
