const std = @import("std");
const StreamingRequest = @import("streaming_request.zig").StreamingRequest;
const Response = @import("response.zig").Response;

/// Whether the sink accepts another borrowed chunk without an explicit resume.
pub const BodyReadiness = enum { ready, paused };
/// Accepted prefix of one nonempty borrowed chunk.
pub const BodyProgress = struct { consumed: usize, readiness: BodyReadiness };
/// Application-owned per-request context accepted after begin succeeds.
pub const BodyBinding = struct {
    context: *anyopaque,
    readiness: BodyReadiness = .ready,
};
/// Logical byte limit and positive per-session active sink bound.
///
/// HTTP/1 and TLS allow one active upload per connection; HTTP/2 bounds
/// concurrent streams by this value; HTTP/3 allows one per stream. The fixed
/// connection/stream slab remains the hard memory bound.
pub const BodyLimits = struct { max_body_bytes: u64, max_active: u16 };
/// Begins a request, returning independently owned sink state.
pub const BodyBeginFn = *const fn (*anyopaque, *const StreamingRequest, BodyControl) anyerror!BodyBinding;
/// Borrows one chunk only until the callback returns.
pub const BodyChunkFn = *const fn (*anyopaque, []const u8) anyerror!BodyProgress;
/// Owns successful terminal cleanup even when response completion fails.
pub const BodyEndFn = *const fn (*anyopaque, *const StreamingRequest, *Response) anyerror!void;
/// Owns cancellation cleanup after a successful begin.
pub const BodyCancelFn = *const fn (*anyopaque, BodyCancelReason) void;
/// Borrowed immutable callbacks; begin chooses the per-request context.
pub const BodySink = struct {
    context: *anyopaque,
    begin: BodyBeginFn,
    chunk: BodyChunkFn,
    end: BodyEndFn,
    cancel: BodyCancelFn,
};
/// Whether every global middleware callback is explicitly header-only.
pub const BodyMiddlewarePolicy = enum { reject_legacy, headers_only };
/// Borrowed route configuration whose lifetime covers the application.
pub const BodyRoute = struct {
    sink: BodySink,
    limits: BodyLimits,
    middleware_policy: BodyMiddlewarePolicy = .reject_legacy,
};
/// Terminal cause kept distinct from transport-specific error codes.
pub const BodyCancelReason = enum {
    cancelled,
    peer_closed,
    reset,
    invalid_body,
    body_too_large,
    timeout,
    shutdown,
    source_failure,
    sink_failure,
};
/// Validation failures preserve state; delivery failure has completed cleanup.
pub const BodyControlError = error{
    BodyControlExpired,
    BodyCallbackActive,
    BodyNotPaused,
    BodyDeliveryFailed,
};

/// Owner delivery failure is reported only after its terminal cleanup path.
pub const BodyResumeFn = *const fn (*anyopaque) error{BodyDeliveryFailed}!void;
/// The owner cancels synchronously and cannot return a delivery error.
pub const BodyControlCancelFn = *const fn (*anyopaque) void;
/// Stable transport owner, independent of the application's binding lifetime.
pub const BodyControlTarget = struct {
    context: *anyopaque,
    resume_fn: BodyResumeFn,
    cancel_fn: BodyControlCancelFn,
};

/// Copyable token confined to the owning event loop.
///
/// App and owner storage must outlive every use. Both operations may invoke
/// terminal callbacks and free the binding inline; copy needed values first.
pub const BodyControl = struct {
    owner: *BodyState,
    generation: u64,

    /// Retries retained input, including a pending end after a final-byte pause.
    pub fn @"resume"(self: BodyControl) BodyControlError!void {
        const target = try self.validate();
        if (self.owner.readiness != .paused) return error.BodyNotPaused;
        self.owner.readiness = .ready;
        return target.resume_fn(target.context);
    }

    /// Abandons a ready or paused upload before returning.
    pub fn cancel(self: BodyControl) BodyControlError!void {
        const target = try self.validate();
        target.cancel_fn(target.context);
    }

    fn validate(self: BodyControl) BodyControlError!BodyControlTarget {
        if (self.generation != self.owner.generation) return error.BodyControlExpired;
        if (self.owner.phase == .inactive or self.owner.phase == .terminal) return error.BodyControlExpired;
        if (self.owner.phase == .begin or self.owner.phase == .chunk) return error.BodyCallbackActive;
        return self.owner.target orelse error.BodyControlExpired;
    }
};

/// Shared validation errors; adapters retain responsibility for wire framing.
pub const BodyStateError = error{
    InvalidBodyLimits,
    BodyStateBusy,
    InvalidBodyState,
    BodyTooLarge,
    InvalidBodyLength,
    InvalidBodyProgress,
    BodyNotReady,
    BodyNotComplete,
};
/// Whether callback storage is borrowed or awaits terminal release.
pub const BodyPhase = enum { inactive, begin, active, chunk, terminal };
/// Copied terminal binding and cause; no retained pointer into owner state.
pub const BodyCancellation = struct { binding: BodyBinding, reason: BodyCancelReason };
/// The owner invokes this callback once, then releases its admission reservation.
pub const BodyTerminal = union(enum) { end: BodyBinding, cancel: BodyCancellation };

/// Pure accepted-prefix validation, independent of transport storage and credit.
pub fn validate_progress(offered: usize, progress: BodyProgress) BodyStateError!void {
    if (offered == 0 or progress.consumed > offered) return error.InvalidBodyProgress;
    if (progress.readiness == .ready and progress.consumed != offered) return error.InvalidBodyProgress;
}

/// Bounded middleware response headers carried from head admission to body end.
pub const PendingHeaders = struct {
    storage: [2048]u8 = undefined,
    length: usize = 0,

    pub fn capture(self: *PendingHeaders, response: *const Response) void {
        const length = @min(response.pending_header_length, response.pending_headers.len);
        @memcpy(self.storage[0..length], response.pending_headers[0..length]);
        self.length = length;
    }

    pub fn apply(self: *const PendingHeaders, response: *Response) void {
        if (self.length == 0) return;
        @memcpy(response.pending_headers[0..self.length], self.storage[0..self.length]);
        response.pending_header_length = self.length;
    }

    pub fn clear(self: *PendingHeaders) void {
        self.length = 0;
    }
};

/// Stable caller-owned lifecycle; effects and sink invocation stay in adapters.
///
/// Arm only after admission is reserved. A failed begin releases that reservation
/// through reject_begin; terminal actions release it only after their callback
/// returns through finish_terminal. No operation owns or frees binding storage.
pub const BodyState = struct {
    target: ?BodyControlTarget = null,
    binding: ?BodyBinding = null,
    declared: ?u64 = null,
    pending_cancel: ?BodyCancelReason = null,
    generation: u64 = 0,
    limit: u64 = 0,
    observed: u64 = 0,
    consumed: u64 = 0,
    offered: usize = 0,
    phase: BodyPhase = .inactive,
    readiness: BodyReadiness = .ready,
    reserved: bool = false,

    /// Starts begin without accepting an application context yet.
    pub fn arm(self: *BodyState, target: BodyControlTarget, limits: BodyLimits, declared: ?u64) BodyStateError!BodyControl {
        if (self.phase != .inactive) return error.BodyStateBusy;
        if (limits.max_active == 0) return error.InvalidBodyLimits;
        if (declared) |length| if (length > limits.max_body_bytes) return error.BodyTooLarge;
        const generation = next_generation(self.generation);
        self.* = .{
            .target = target,
            .declared = declared,
            .generation = generation,
            .limit = limits.max_body_bytes,
            .phase = .begin,
            .reserved = true,
        };
        return .{ .owner = self, .generation = generation };
    }

    /// Accepts one binding, including cancellation recorded during begin.
    pub fn accept_begin(self: *BodyState, binding: BodyBinding) ?BodyTerminal {
        std.debug.assert(self.phase == .begin);
        self.binding = binding;
        self.readiness = binding.readiness;
        self.phase = .active;
        if (self.pending_cancel) |reason| return self.take_cancel(reason);
        return null;
    }

    /// Failed begin owns its own rollback and receives no terminal callback.
    pub fn reject_begin(self: *BodyState) bool {
        std.debug.assert(self.phase == .begin);
        self.invalidate();
        self.pending_cancel = null;
        self.phase = .inactive;
        return self.release_reservation();
    }

    /// Counts new logical input once; retries of retained bytes do not call this.
    pub fn observe(self: *BodyState, length: u64) BodyStateError!void {
        if (self.phase != .active) return error.InvalidBodyState;
        const total = @addWithOverflow(self.observed, length);
        if (total[1] != 0 or total[0] > self.limit) return error.BodyTooLarge;
        if (self.declared) |declared| if (total[0] > declared) return error.InvalidBodyLength;
        self.observed = total[0];
    }

    /// Counts an offered chunk when it contains new bytes and starts delivery.
    ///
    /// Retained bytes are offered again after a pause without being counted
    /// twice. This is the single adapter entry point for new and replayed
    /// payloads.
    pub fn prepare_chunk(self: *BodyState, offered: usize) BodyStateError!void {
        if (offered == 0) return error.InvalidBodyProgress;
        const retained = self.observed - self.consumed;
        if (@as(u64, offered) > retained) {
            const added: usize = offered - @as(usize, @intCast(retained));
            try self.observe(@as(u64, added));
        }
        try self.start_chunk(offered);
    }

    /// Borrows callback storage only for a nonempty, already observed prefix.
    pub fn start_chunk(self: *BodyState, offered: usize) BodyStateError!void {
        if (self.phase != .active) return error.InvalidBodyState;
        if (self.readiness != .ready) return error.BodyNotReady;
        if (offered == 0 or offered > self.observed - self.consumed) return error.InvalidBodyProgress;
        self.offered = offered;
        self.phase = .chunk;
    }

    /// Invalid progress leaves callback state for the owner's fail_chunk path.
    pub fn accept_chunk(self: *BodyState, progress: BodyProgress) BodyStateError!?BodyTerminal {
        if (self.phase != .chunk) return error.InvalidBodyState;
        try validate_progress(self.offered, progress);
        // start_chunk bounded the offer by unconsumed observed bytes.
        self.consumed += progress.consumed;
        self.offered = 0;
        self.readiness = progress.readiness;
        self.phase = .active;
        if (self.pending_cancel) |reason| return self.take_cancel(reason);
        return null;
    }

    /// Sink errors and invalid progress terminate after the chunk callback exits.
    pub fn fail_chunk(self: *BodyState) BodyTerminal {
        std.debug.assert(self.phase == .chunk);
        self.phase = .active;
        return self.take_cancel(self.pending_cancel orelse .sink_failure);
    }

    /// Owner cancellation is deferred while begin/chunk borrows the context.
    pub fn request_cancel(self: *BodyState, reason: BodyCancelReason) ?BodyTerminal {
        switch (self.phase) {
            .inactive, .terminal => return null,
            .begin, .chunk => {
                if (self.pending_cancel == null) self.pending_cancel = reason;
                return null;
            },
            .active => return self.take_cancel(reason),
        }
    }

    /// Framing and trailers must already be validated by the owning adapter.
    pub fn take_end(self: *BodyState, validated_complete: bool, queued_bytes: usize) BodyStateError!BodyTerminal {
        if (self.phase != .active) return error.InvalidBodyState;
        if (!validated_complete or queued_bytes != 0 or self.readiness != .ready) return error.BodyNotComplete;
        if (self.consumed != self.observed) return error.BodyNotComplete;
        if (self.declared) |declared| if (self.observed != declared) return error.InvalidBodyLength;
        return .{ .end = self.take_binding() };
    }

    /// Call after end/cancel returns, even when end fails. True releases once.
    pub fn finish_terminal(self: *BodyState) bool {
        if (self.phase != .terminal) return false;
        self.phase = .inactive;
        return self.release_reservation();
    }

    fn take_cancel(self: *BodyState, reason: BodyCancelReason) BodyTerminal {
        return .{ .cancel = .{ .binding = self.take_binding(), .reason = reason } };
    }

    fn take_binding(self: *BodyState) BodyBinding {
        const binding = self.binding.?;
        self.binding = null;
        self.pending_cancel = null;
        self.offered = 0;
        self.invalidate();
        self.phase = .terminal;
        return binding;
    }

    fn invalidate(self: *BodyState) void {
        self.generation = next_generation(self.generation);
        self.target = null;
    }

    fn release_reservation(self: *BodyState) bool {
        const reserved = self.reserved;
        self.reserved = false;
        return reserved;
    }
};

fn next_generation(generation: u64) u64 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}
