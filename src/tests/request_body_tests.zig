const std = @import("std");
const support = @import("test_support");
const uz = support.public_api;
const body = support.request_body;
const StreamingRequest = uz.StreamingRequest;
const Response = support.http_response.Response;

const empty_metadata = StreamingRequest{
    .method = "",
    .target = "",
    .path = "",
    .protocol = "",
    .query = "",
    .headers = .{ .names = &.{}, .values = &.{} },
    .params = .{ .names = &.{}, .values = &.{} },
};

test "request body: ADR public aliases retain exact callback contracts" {
    try std.testing.expectEqual(@as(usize, 9), std.enums.values(body.BodyCancelReason).len);
    const limits = body.BodyLimits{ .max_body_bytes = 0, .max_active = 1 };
    try std.testing.expectEqual(@as(u64, 0), limits.max_body_bytes);
    const check_resume: *const fn (body.BodyControl) body.BodyControlError!void = &body.BodyControl.@"resume";
    const check_cancel: *const fn (body.BodyControl) body.BodyControlError!void = &body.BodyControl.cancel;
    _ = check_resume;
    _ = check_cancel;
}

test "request body: progress enforces full ready and bounded paused prefixes" {
    try body.validate_progress(3, .{ .consumed = 3, .readiness = .ready });
    for (0..4) |accepted| try body.validate_progress(3, .{ .consumed = accepted, .readiness = .paused });
    try std.testing.expectError(error.InvalidBodyProgress, body.validate_progress(3, .{ .consumed = 4, .readiness = .paused }));
    try std.testing.expectError(error.InvalidBodyProgress, body.validate_progress(3, .{ .consumed = 2, .readiness = .ready }));
    try std.testing.expectError(error.InvalidBodyProgress, body.validate_progress(3, .{ .consumed = 0, .readiness = .ready }));
    try std.testing.expectError(error.InvalidBodyProgress, body.validate_progress(0, .{ .consumed = 0, .readiness = .ready }));
}

const Event = enum { begin_enter, begin_exit, chunk_enter, chunk_exit, end_enter, end_exit, cancel, release };

const Binding = struct {
    owner: *Owner,
    control: body.BodyControl,
    alive: bool = true,
};

const Owner = struct {
    state: body.BodyState = .{},
    request: StreamingRequest = empty_metadata,
    binding: ?*Binding = null,
    inline_binding: Binding = undefined,
    events: [32]Event = undefined,
    event_count: usize = 0,
    reservations: u16 = 0,
    releases: usize = 0,
    ends: usize = 0,
    cancels: usize = 0,
    last_reason: ?body.BodyCancelReason = null,
    terminal_control_error: ?body.BodyControlError = null,
    reentrant_resume_error: ?body.BodyControlError = null,
    reentrant_cancel_error: ?body.BodyControlError = null,
    begin_failure: bool = false,
    chunk_failure: bool = false,
    end_failure: bool = false,
    cancel_during_begin: ?body.BodyCancelReason = null,
    cancel_during_chunk: ?body.BodyCancelReason = null,
    progress: ?body.BodyProgress = null,
    begin_readiness: body.BodyReadiness = .ready,
    queued: []const u8 = "",
    validated_complete: bool = false,
    heap_binding: bool = false,
    request_controls: bool = false,

    fn event(self: *Owner, value: Event) void {
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = value;
        self.event_count += 1;
    }

    fn sink(self: *Owner) body.BodySink {
        return .{ .context = self, .begin = begin, .chunk = chunk, .end = end, .cancel = cancel };
    }

    fn start(self: *Owner, limit: u64, declared: ?u64) !body.BodyControl {
        const control = try self.state.arm(.{ .context = self, .resume_fn = resume_owner, .cancel_fn = cancel_owner }, .{ .max_body_bytes = limit, .max_active = 1 }, declared);
        self.reservations += 1;
        const binding = self.sink().begin(self, &self.request, control) catch |err| {
            self.release(self.state.reject_begin());
            return err;
        };
        if (self.state.accept_begin(binding)) |terminal| _ = self.terminate(terminal);
        return control;
    }

    fn release(self: *Owner, released: bool) void {
        if (!released) return;
        std.debug.assert(self.reservations == 1);
        self.reservations -= 1;
        self.releases += 1;
        self.event(.release);
    }

    fn begin(context: *anyopaque, _: *const StreamingRequest, control: body.BodyControl) !body.BodyBinding {
        const self: *Owner = @ptrCast(@alignCast(context));
        self.event(.begin_enter);
        if (self.request_controls) {
            control.@"resume"() catch |err| {
                self.reentrant_resume_error = err;
            };
            control.cancel() catch |err| {
                self.reentrant_cancel_error = err;
            };
        }
        if (self.cancel_during_begin) |reason| {
            std.debug.assert(self.state.request_cancel(reason) == null);
            std.debug.assert(self.state.request_cancel(.cancelled) == null);
        }
        self.event(.begin_exit);
        if (self.begin_failure) {
            const partial = try std.testing.allocator.create(u8);
            defer std.testing.allocator.destroy(partial);
            return error.BeginFailed;
        }
        const binding = if (self.heap_binding) try std.testing.allocator.create(Binding) else &self.inline_binding;
        binding.* = .{ .owner = self, .control = control };
        self.binding = binding;
        return .{ .context = binding, .readiness = self.begin_readiness };
    }

    fn chunk(context: *anyopaque, input: []const u8) !body.BodyProgress {
        const binding: *Binding = @ptrCast(@alignCast(context));
        const self = binding.owner;
        std.debug.assert(binding.alive);
        self.event(.chunk_enter);
        if (self.request_controls) {
            binding.control.@"resume"() catch |err| {
                self.reentrant_resume_error = err;
            };
            binding.control.cancel() catch |err| {
                self.reentrant_cancel_error = err;
            };
        }
        if (self.cancel_during_chunk) |reason| {
            std.debug.assert(self.state.request_cancel(reason) == null);
            std.debug.assert(self.state.request_cancel(.cancelled) == null);
        }
        std.debug.assert(binding.alive);
        self.event(.chunk_exit);
        if (self.chunk_failure) return error.ChunkFailed;
        return self.progress orelse .{ .consumed = input.len, .readiness = .ready };
    }

    fn end(context: *anyopaque, _: *const StreamingRequest, _: *support.http_response.Response) !void {
        const binding: *Binding = @ptrCast(@alignCast(context));
        const self = binding.owner;
        self.event(.end_enter);
        std.debug.assert(self.reservations == 1);
        std.debug.assert(self.state.phase == .terminal and self.state.binding == null and self.state.reserved);
        self.ends += 1;
        const control = binding.control;
        control.@"resume"() catch |err| {
            self.terminal_control_error = err;
        };
        const failure = self.end_failure;
        self.drop_binding(binding);
        self.event(.end_exit);
        if (failure) return error.EndFailed;
    }

    fn cancel(context: *anyopaque, reason: body.BodyCancelReason) void {
        const binding: *Binding = @ptrCast(@alignCast(context));
        const self = binding.owner;
        std.debug.assert(self.reservations == 1);
        std.debug.assert(self.state.phase == .terminal and self.state.binding == null and self.state.reserved);
        self.cancels += 1;
        self.last_reason = reason;
        self.event(.cancel);
        const control = binding.control;
        control.cancel() catch |err| {
            self.terminal_control_error = err;
        };
        self.drop_binding(binding);
    }

    fn drop_binding(self: *Owner, binding: *Binding) void {
        std.debug.assert(binding.alive);
        binding.alive = false;
        self.binding = null;
        if (self.heap_binding) std.testing.allocator.destroy(binding);
    }

    fn terminate(self: *Owner, terminal: body.BodyTerminal) bool {
        var failed = false;
        switch (terminal) {
            .end => |binding| {
                // The test sink never inspects the response; this is not a wire fixture.
                var response: support.http_response.Response = undefined;
                self.sink().end(binding.context, &self.request, &response) catch {
                    failed = true;
                };
            },
            .cancel => |cancellation| self.sink().cancel(cancellation.binding.context, cancellation.reason),
        }
        self.release(self.state.finish_terminal());
        return failed;
    }

    fn feed(self: *Owner, input: []const u8) !void {
        std.debug.assert(self.queued.len == 0);
        try self.state.observe(input.len);
        self.queued = input;
        try self.deliver();
    }

    fn deliver(self: *Owner) error{BodyDeliveryFailed}!void {
        if (self.state.readiness == .paused) return;
        if (self.queued.len != 0) {
            self.state.start_chunk(self.queued.len) catch {
                if (self.state.request_cancel(.source_failure)) |terminal| _ = self.terminate(terminal);
                return error.BodyDeliveryFailed;
            };
            const progress = self.sink().chunk(self.binding.?, self.queued) catch {
                _ = self.terminate(self.state.fail_chunk());
                return error.BodyDeliveryFailed;
            };
            const terminal = self.state.accept_chunk(progress) catch {
                _ = self.terminate(self.state.fail_chunk());
                return error.BodyDeliveryFailed;
            };
            self.queued = self.queued[progress.consumed..];
            if (terminal) |value| {
                _ = self.terminate(value);
                return;
            }
        }
        if (!self.validated_complete or self.queued.len != 0 or self.state.readiness == .paused) return;
        const terminal = self.state.take_end(true, 0) catch {
            if (self.state.request_cancel(.invalid_body)) |value| _ = self.terminate(value);
            return error.BodyDeliveryFailed;
        };
        if (self.terminate(terminal)) return error.BodyDeliveryFailed;
    }

    fn resume_owner(context: *anyopaque) error{BodyDeliveryFailed}!void {
        const self: *Owner = @ptrCast(@alignCast(context));
        return self.deliver();
    }

    fn cancel_owner(context: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.state.request_cancel(.cancelled)) |terminal| _ = self.terminate(terminal);
    }
};

test "request body: failed begin releases reservation without accepted context or cancel" {
    var owner = Owner{ .begin_failure = true, .cancel_during_begin = .shutdown };
    try std.testing.expectError(error.BeginFailed, owner.start(0, 0));
    try std.testing.expectEqual(@as(usize, 0), owner.cancels);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
    try std.testing.expectEqual(@as(u16, 0), owner.reservations);
    try std.testing.expect(owner.binding == null);
    try std.testing.expect(!owner.state.finish_terminal());
}

test "request body: begin cancellation waits for binding then cancels exactly once" {
    var owner = Owner{ .cancel_during_begin = .shutdown };
    const control = try owner.start(0, 0);
    try std.testing.expectEqualSlices(Event, &.{ .begin_enter, .begin_exit, .cancel, .release }, owner.events[0..owner.event_count]);
    try std.testing.expectEqual(body.BodyCancelReason.shutdown, owner.last_reason.?);
    try std.testing.expectEqual(error.BodyControlExpired, owner.terminal_control_error.?);
    try std.testing.expectError(error.BodyControlExpired, control.cancel());
    try std.testing.expectEqual(@as(usize, 1), owner.cancels);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
}

test "request body: ready resume and reentrant controls preserve state" {
    var owner = Owner{ .request_controls = true };
    const control = try owner.start(3, 3);
    try std.testing.expectEqual(error.BodyCallbackActive, owner.reentrant_resume_error.?);
    try std.testing.expectEqual(error.BodyCallbackActive, owner.reentrant_cancel_error.?);
    try std.testing.expectError(error.BodyNotPaused, control.@"resume"());
    try owner.feed("abc");
    try std.testing.expectEqual(error.BodyCallbackActive, owner.reentrant_resume_error.?);
    try std.testing.expectEqual(error.BodyCallbackActive, owner.reentrant_cancel_error.?);
    try std.testing.expectEqual(@as(usize, 0), owner.cancels);
    try control.cancel();
    try std.testing.expectEqual(@as(usize, 1), owner.cancels);
}

test "request body: paused prefixes retry without counting logical bytes twice" {
    var owner = Owner{ .progress = .{ .consumed = 1, .readiness = .paused } };
    const control = try owner.start(3, 3);
    try owner.feed("abc");
    try std.testing.expectEqual(@as(u64, 3), owner.state.observed);
    try std.testing.expectEqual(@as(u64, 1), owner.state.consumed);
    try std.testing.expectEqualStrings("bc", owner.queued);
    owner.progress = null;
    owner.validated_complete = true;
    try control.@"resume"();
    try std.testing.expectEqual(@as(u64, 3), owner.state.observed);
    try std.testing.expectEqual(@as(u64, 3), owner.state.consumed);
    try std.testing.expectEqual(@as(usize, 1), owner.ends);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
}

test "request body: final-byte pause requires explicit resume before end" {
    var owner = Owner{ .progress = .{ .consumed = 3, .readiness = .paused }, .validated_complete = true };
    const control = try owner.start(3, 3);
    try owner.feed("abc");
    try std.testing.expectEqual(@as(usize, 0), owner.ends);
    try std.testing.expectEqual(@as(usize, 0), owner.releases);
    try control.@"resume"();
    try std.testing.expectEqual(@as(usize, 1), owner.ends);
    try std.testing.expectEqual(error.BodyControlExpired, owner.terminal_control_error.?);
    try std.testing.expectError(error.BodyControlExpired, control.@"resume"());
}

test "request body: cancel ready or paused releases heap binding inline" {
    for ([_]body.BodyReadiness{ .ready, .paused }) |readiness| {
        var owner = Owner{ .begin_readiness = readiness, .heap_binding = true };
        const control = try owner.start(0, 0);
        try control.cancel();
        try std.testing.expect(owner.binding == null);
        try std.testing.expectEqual(@as(usize, 1), owner.cancels);
        try std.testing.expectEqual(@as(usize, 1), owner.releases);
        try std.testing.expectError(error.BodyControlExpired, control.cancel());
    }
}

test "request body: resume may free heap binding and reports terminal end failure once" {
    for ([_]bool{ false, true }) |failure| {
        var owner = Owner{ .begin_readiness = .paused, .validated_complete = true, .heap_binding = true, .end_failure = failure };
        const control = try owner.start(0, 0);
        if (failure) try std.testing.expectError(error.BodyDeliveryFailed, control.@"resume"()) else try control.@"resume"();
        try std.testing.expect(owner.binding == null);
        try std.testing.expectEqual(@as(usize, 1), owner.ends);
        try std.testing.expectEqual(@as(usize, 0), owner.cancels);
        try std.testing.expectEqual(@as(usize, 1), owner.releases);
        try std.testing.expectError(error.BodyControlExpired, control.cancel());
    }
}

test "request body: owner cancellation during chunk defers terminal and preserves first cause" {
    var owner = Owner{ .cancel_during_chunk = .reset };
    const control = try owner.start(3, 3);
    try owner.feed("abc");
    try std.testing.expectEqualSlices(Event, &.{ .begin_enter, .begin_exit, .chunk_enter, .chunk_exit, .cancel, .release }, owner.events[0..owner.event_count]);
    try std.testing.expectEqual(body.BodyCancelReason.reset, owner.last_reason.?);
    try std.testing.expectError(error.BodyControlExpired, control.@"resume"());
}

test "request body: sink failure and invalid progress terminate before delivery error" {
    for ([_]bool{ false, true }) |invalid| {
        var owner = Owner{ .chunk_failure = !invalid, .heap_binding = true, .progress = if (invalid) .{ .consumed = 1, .readiness = .ready } else null };
        const control = try owner.start(3, 3);
        try std.testing.expectError(error.BodyDeliveryFailed, owner.feed("abc"));
        try std.testing.expectEqual(body.BodyCancelReason.sink_failure, owner.last_reason.?);
        try std.testing.expect(owner.binding == null);
        try std.testing.expectEqual(@as(usize, 1), owner.cancels);
        try std.testing.expectEqual(@as(usize, 1), owner.releases);
        try std.testing.expectError(error.BodyControlExpired, control.cancel());
    }
}

test "request body: every cancellation cause survives common terminal transition" {
    for (std.enums.values(body.BodyCancelReason)) |reason| {
        var owner = Owner{};
        _ = try owner.start(0, 0);
        const terminal = owner.state.request_cancel(reason).?;
        try std.testing.expect(owner.state.request_cancel(.cancelled) == null);
        _ = owner.terminate(terminal);
        try std.testing.expectEqual(reason, owner.last_reason.?);
        try std.testing.expectEqual(@as(usize, 1), owner.releases);
        try std.testing.expect(!owner.state.finish_terminal());
    }
}

test "request body: controls cannot act on recycled owner generation" {
    var owner = Owner{};
    const stale = try owner.start(0, 0);
    try stale.cancel();
    const current = try owner.start(0, 0);
    try std.testing.expectError(error.BodyControlExpired, stale.cancel());
    try std.testing.expectError(error.BodyControlExpired, stale.@"resume"());
    try std.testing.expectEqual(@as(u16, 1), owner.reservations);
    try current.cancel();
    try std.testing.expectEqual(@as(usize, 2), owner.cancels);
    try std.testing.expectEqual(@as(usize, 2), owner.releases);
}

test "request body: observed limits zero declared length and overflow refuse atomically" {
    var owner = Owner{};
    try std.testing.expectError(error.BodyTooLarge, owner.start(0, 1));
    try std.testing.expectEqual(@as(u16, 0), owner.reservations);
    const control = try owner.start(0, 0);
    try std.testing.expectError(error.BodyTooLarge, owner.state.observe(1));
    try std.testing.expectEqual(@as(u64, 0), owner.state.observed);
    try control.cancel();

    var huge = Owner{};
    const huge_control = try huge.start(std.math.maxInt(u64), null);
    try huge.state.observe(std.math.maxInt(u64));
    try std.testing.expectError(error.BodyTooLarge, huge.state.observe(1));
    try std.testing.expectEqual(std.math.maxInt(u64), huge.state.observed);
    try huge_control.cancel();

    var declared = Owner{};
    const declared_control = try declared.start(10, 3);
    try std.testing.expectError(error.InvalidBodyLength, declared.state.observe(4));
    try std.testing.expectEqual(@as(u64, 0), declared.state.observed);
    try declared_control.cancel();
}

test "request body: end requires validated framing no retained data and exact length" {
    var owner = Owner{};
    const control = try owner.start(3, 3);
    try std.testing.expectError(error.BodyNotComplete, owner.state.take_end(false, 0));
    try owner.state.observe(3);
    try std.testing.expectError(error.BodyNotComplete, owner.state.take_end(true, 3));
    try std.testing.expectError(error.BodyNotComplete, owner.state.take_end(true, 0));
    try owner.state.start_chunk(3);
    try std.testing.expect((try owner.state.accept_chunk(.{ .consumed = 3, .readiness = .ready })) == null);
    _ = owner.terminate(try owner.state.take_end(true, 0));
    try std.testing.expectError(error.BodyControlExpired, control.cancel());

    var short = Owner{};
    const short_control = try short.start(3, 3);
    try std.testing.expectError(error.InvalidBodyLength, short.state.take_end(true, 0));
    try short_control.cancel();
}

test "request body: invalid admission limits and busy arm leave state unchanged" {
    var owner = Owner{};
    const target = body.BodyControlTarget{ .context = &owner, .resume_fn = Owner.resume_owner, .cancel_fn = Owner.cancel_owner };
    try std.testing.expectError(error.InvalidBodyLimits, owner.state.arm(target, .{ .max_body_bytes = 10, .max_active = 0 }, null));
    try std.testing.expectEqual(@as(u64, 0), owner.state.generation);
    try std.testing.expect(!owner.state.reserved);
    const control = try owner.start(0, 0);
    const generation = owner.state.generation;
    try std.testing.expectError(error.BodyStateBusy, owner.state.arm(target, .{ .max_body_bytes = 10, .max_active = 1 }, null));
    try std.testing.expectEqual(generation, owner.state.generation);
    try std.testing.expect(owner.state.reserved);
    try control.cancel();
}

test "request body: zero-prefix pause retains input and inactive generation wins" {
    var owner = Owner{ .progress = .{ .consumed = 0, .readiness = .paused } };
    const control = try owner.start(3, 3);
    try owner.feed("abc");
    try std.testing.expectEqualStrings("abc", owner.queued);
    try std.testing.expectEqual(@as(u64, 0), owner.state.consumed);
    try std.testing.expectError(error.BodyNotReady, owner.state.start_chunk(3));
    owner.progress = null;
    owner.validated_complete = true;
    try control.@"resume"();
    const inactive = body.BodyControl{ .owner = &owner.state, .generation = owner.state.generation };
    try std.testing.expectError(error.BodyControlExpired, inactive.@"resume"());
    try std.testing.expectError(error.BodyControlExpired, inactive.cancel());
    try std.testing.expectEqual(@as(usize, 1), owner.ends);
}

test "request body: maximum observed prefix cannot overflow consumed counter" {
    var owner = Owner{};
    const control = try owner.start(std.math.maxInt(u64), null);
    const length = std.math.maxInt(usize);
    try owner.state.observe(length);
    try owner.state.start_chunk(length);
    try std.testing.expect((try owner.state.accept_chunk(.{ .consumed = length, .readiness = .ready })) == null);
    try std.testing.expectEqual(@as(u64, length), owner.state.consumed);
    try std.testing.expectError(error.InvalidBodyProgress, owner.state.start_chunk(1));
    try control.cancel();
}

test "request body: pending middleware headers round trip through body end" {
    var captured = Response{ .target = undefined };
    const fields = "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n";
    @memcpy(captured.pending_headers[0..fields.len], fields);
    captured.pending_header_length = fields.len;
    var pending = body.PendingHeaders{};
    pending.capture(&captured);
    try std.testing.expectEqual(fields.len, pending.length);
    var applied = Response{ .target = undefined };
    pending.apply(&applied);
    try std.testing.expectEqualStrings(fields, applied.pending_headers[0..applied.pending_header_length]);
}

test "request body: prepare_chunk retries retained bytes without double counting" {
    var owner = Owner{};
    const control = try owner.start(5, 5);
    try owner.state.prepare_chunk(2);
    try std.testing.expectEqual(@as(usize, 2), owner.state.offered);
    try std.testing.expectEqual(@as(u64, 2), owner.state.observed);
    try std.testing.expect((try owner.state.accept_chunk(.{ .consumed = 2, .readiness = .ready })) == null);
    try owner.state.prepare_chunk(3);
    try std.testing.expectEqual(@as(usize, 3), owner.state.offered);
    try std.testing.expectEqual(@as(u64, 5), owner.state.observed);
    try std.testing.expect((try owner.state.accept_chunk(.{ .consumed = 3, .readiness = .ready })) == null);
    try std.testing.expectEqual(@as(u64, 5), owner.state.consumed);
    _ = owner.terminate(try owner.state.take_end(true, 0));
    try std.testing.expectError(error.BodyControlExpired, control.cancel());
}

test "request body: resumed chunk failure cleans binding before returning delivery failure" {
    var owner = Owner{ .begin_readiness = .paused, .chunk_failure = true, .heap_binding = true };
    const control = try owner.start(3, 3);
    try owner.feed("abc");
    try std.testing.expectEqual(@as(usize, 0), owner.cancels);
    try std.testing.expectError(error.BodyDeliveryFailed, control.@"resume"());
    try std.testing.expect(owner.binding == null);
    try std.testing.expectEqual(body.BodyCancelReason.sink_failure, owner.last_reason.?);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
    try std.testing.expectError(error.BodyControlExpired, control.cancel());
}

test "request body: failed begin control expires before owner reuse" {
    var owner = Owner{};
    const target = body.BodyControlTarget{ .context = &owner, .resume_fn = Owner.resume_owner, .cancel_fn = Owner.cancel_owner };
    const failed = try owner.state.arm(target, .{ .max_body_bytes = 0, .max_active = 1 }, 0);
    try std.testing.expect(owner.state.reject_begin());
    try std.testing.expectError(error.BodyControlExpired, failed.cancel());
    try std.testing.expectError(error.BodyControlExpired, failed.@"resume"());
    const current = try owner.start(0, 0);
    try std.testing.expectError(error.BodyControlExpired, failed.cancel());
    try current.cancel();
    try std.testing.expectEqual(@as(usize, 1), owner.cancels);
}

test "request body: revised callback aliases and middleware policy are explicit" {
    var owner = Owner{};
    const begin: uz.BodyBeginFn = Owner.begin;
    const chunk: uz.BodyChunkFn = Owner.chunk;
    const end: uz.BodyEndFn = Owner.end;
    const cancel: uz.BodyCancelFn = Owner.cancel;
    const sink = uz.BodySink{ .context = &owner, .begin = begin, .chunk = chunk, .end = end, .cancel = cancel };
    const route = uz.BodyRoute{ .sink = sink, .limits = .{ .max_body_bytes = 100_000_000, .max_active = 1 } };
    try std.testing.expectEqual(uz.BodyMiddlewarePolicy.reject_legacy, route.middleware_policy);
    const authorized = uz.BodyRoute{ .sink = sink, .limits = route.limits, .middleware_policy = .headers_only };
    try std.testing.expectEqual(uz.BodyMiddlewarePolicy.headers_only, authorized.middleware_policy);
}
