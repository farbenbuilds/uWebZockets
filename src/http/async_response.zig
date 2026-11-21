const response_fields = @import("response_fields.zig");
const status_code = response_fields.status_code;
const status_forbids_body = response_fields.status_forbids_body;
const valid_headers = response_fields.valid_headers;

/// Deferred completion callback: status, response fields, and body bytes.
pub const AsyncCompleteFn = *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void;
/// Wakes the suspended transport dispatch after deferred completion.
pub const AsyncWakeFn = *const fn (*anyopaque) void;

/// Parks a deferred response until `delay_ms` elapses, then invokes `resume`.
pub const AsyncSleepFn = *const fn (
    context: *anyopaque,
    delay_ms: u64,
    resume_ctx: *anyopaque,
    resume_fn: *const fn (*anyopaque) void,
) void;

/// Parks a deferred response and completes it with borrowed response fields
/// when the delay expires. The slices must outlive the delay.
pub const AsyncSleepCompleteFn = *const fn (
    context: *anyopaque,
    delay_ms: u64,
    token: AsyncResponse,
    status: []const u8,
    headers: []const u8,
    body: []const u8,
) void;

/// Transport callbacks retained by a connection-owned async response state.
pub const AsyncTarget = struct {
    context: *anyopaque,
    complete_fn: AsyncCompleteFn,
    wake_fn: AsyncWakeFn,
    /// Null on transports without a connection-owned timer slot.
    sleep_fn: ?AsyncSleepFn = null,
    /// Null on transports that cannot retain a completion payload.
    sleep_complete_fn: ?AsyncSleepCompleteFn = null,
};

/// Lifecycle of one connection-owned async response slot.
pub const AsyncState = enum(u8) {
    idle,
    pending,
    completing,
    completed,
    cancelled,
};

/// Stable state embedded in an HTTP/1 connection, HTTP/2 stream, or HTTP/3 stream.
///
/// Re-arming increments a generation so tokens retained past transport reuse
/// fail closed. Methods are event-loop confined; cross-thread completion must
/// first be marshalled onto the owning loop.
pub const AsyncResponseState = struct {
    target: ?AsyncTarget = null,
    generation: u64 = 0,
    state: AsyncState = .idle,

    /// Arms the slot and returns a copyable one-shot token.
    pub fn arm(self: *AsyncResponseState, target: AsyncTarget) AsyncResponse {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = target;
        self.state = .pending;
        return .{ .owner = self, .generation = self.generation };
    }

    /// Invalidates every outstanding token without touching the transport.
    pub fn cancel(self: *AsyncResponseState) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = null;
        self.state = .cancelled;
    }

    /// Reports whether the current generation still awaits completion.
    pub fn is_pending(self: *const AsyncResponseState) bool {
        return self.state == .pending;
    }
};

/// Copyable generation-checked token for exactly one deferred response.
///
/// The token borrows transport-owned state that remains stable until the
/// connection or stream closes. Completion must run on that transport's event
/// loop. A second completion or a completion after reuse returns an error.
pub const AsyncResponse = struct {
    owner: *AsyncResponseState,
    generation: u64,

    /// Completes with no additional response fields.
    pub fn complete(
        self: AsyncResponse,
        status: []const u8,
        body: []const u8,
    ) !void {
        return self.complete_with_headers(status, "", body);
    }

    /// Completes once and wakes the suspended transport dispatch.
    pub fn complete_with_headers(
        self: AsyncResponse,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.generation != self.owner.generation) return error.AsyncResponseExpired;
        if (self.owner.state != .pending) return error.AsyncResponseAlreadyCompleted;
        const target = self.owner.target orelse return error.AsyncResponseExpired;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        self.owner.state = .completing;
        target.complete_fn(target.context, status, headers, body) catch |err| {
            self.owner.state = .completed;
            self.owner.target = null;
            target.wake_fn(target.context);
            return err;
        };
        self.owner.state = .completed;
        self.owner.target = null;
        target.wake_fn(target.context);
    }

    /// Parks the response until `delay_ms` elapses, then invokes `resume`.
    ///
    /// The slot is owned by the connection or stream, so a re-armed generation
    /// and a disconnected peer fail closed. `resume` must complete this exact
    /// token; completing it from any other callback races the transport.
    pub fn sleep(
        self: AsyncResponse,
        delay_ms: u64,
        resume_ctx: *anyopaque,
        resume_fn: *const fn (*anyopaque) void,
    ) !void {
        if (!self.is_pending()) return error.AsyncResponseExpired;
        const target = self.owner.target orelse return error.AsyncResponseExpired;
        const sleep_fn = target.sleep_fn orelse return error.TimerUnavailable;
        sleep_fn(target.context, delay_ms, resume_ctx, resume_fn);
    }

    /// Parks the response and completes it with borrowed fields on expiry.
    ///
    /// This is the zero-allocation `/delay` path: the transport stores the
    /// token and the three slices in its connection-owned parking slot. The
    /// caller must keep the slices valid until `delay_ms` elapses.
    pub fn sleep_complete(
        self: AsyncResponse,
        delay_ms: u64,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (!self.is_pending()) return error.AsyncResponseExpired;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;
        const target = self.owner.target orelse return error.AsyncResponseExpired;
        const sleep_fn = target.sleep_complete_fn orelse return error.TimerUnavailable;
        sleep_fn(target.context, delay_ms, self, status, headers, body);
    }

    /// Reports whether this exact generation can still complete.
    pub fn is_pending(self: AsyncResponse) bool {
        return self.generation == self.owner.generation and self.owner.state == .pending;
    }
};
