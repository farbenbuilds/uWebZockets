const std = @import("std");
const multipart = @import("multipart_streaming.zig");
const body = @import("request_body.zig");

/// Metadata is borrowed only until this callback returns, including a pause.
pub const PartBeginFn = *const fn (*anyopaque, multipart.PartMeta) anyerror!body.BodyReadiness;
/// Acknowledges a prefix of a nonempty borrowed part-data chunk.
pub const PartWriteFn = *const fn (*anyopaque, []const u8) anyerror!body.BodyProgress;
/// Owns part cleanup on success, pause, or failure.
pub const PartEndFn = *const fn (*anyopaque) anyerror!body.BodyReadiness;
/// Releases an accepted active part exactly once after callback unwinding.
pub const PartCancelFn = *const fn (*anyopaque, body.BodyCancelReason) void;

/// Immutable callbacks with an application-owned per-upload context.
pub const PartSink = struct {
    context: *anyopaque,
    begin_part: PartBeginFn,
    write_chunk: PartWriteFn,
    end_part: PartEndFn,
    cancel_part: PartCancelFn,
};

const Phase = enum { open, failed, terminal };

/// Effect boundary for pure multipart events and accepted-prefix accounting.
/// Part callbacks cannot reenter this adapter or free its containing upload.
pub const MultipartSink = struct {
    parser: multipart.StreamingParser,
    sink: PartSink,
    phase: Phase = .open,
    part_active: bool = false,

    /// Accepts one outer body chunk; retry only its unaccepted suffix on resume.
    /// Errors leave accepted-part cleanup to the outer cancellation callback.
    pub fn consume(self: *MultipartSink, input: []const u8) anyerror!body.BodyProgress {
        if (self.phase != .open) return error.InvalidMultipartState;
        errdefer self.phase = .failed;
        if (input.len == 0) return error.InvalidBodyProgress;
        var consumed: usize = 0;
        while (consumed < input.len) {
            const step = try self.parser.next(input[consumed..]);
            consumed += step.consumed;
            const event = step.event orelse break;
            const readiness = try self.deliver(event, &consumed);
            if (readiness == .paused) return .{ .consumed = consumed, .readiness = .paused };
        }
        return .{ .consumed = consumed, .readiness = .ready };
    }

    /// Outer end owns cleanup even on failure; no later cancel is required.
    pub fn finish(self: *MultipartSink) anyerror!void {
        if (self.phase != .open) {
            self.cancel(.sink_failure);
            return error.InvalidMultipartState;
        }
        self.parser.finish() catch |err| {
            // A truncated or malformed entity is invalid input, not a sink
            // callback failure; keep the cancellation reason truthful.
            self.cancel(.invalid_body);
            return err;
        };
        std.debug.assert(!self.part_active);
        self.phase = .terminal;
    }

    /// Terminates before notifying the part owner, making repeats harmless.
    pub fn cancel(self: *MultipartSink, reason: body.BodyCancelReason) void {
        if (self.phase == .terminal) return;
        self.phase = .terminal;
        if (!self.part_active) return;
        self.part_active = false;
        self.sink.cancel_part(self.sink.context, reason);
    }

    fn deliver(self: *MultipartSink, event: multipart.StreamingEvent, consumed: *usize) anyerror!body.BodyReadiness {
        switch (event) {
            .part_begin => |metadata| {
                std.debug.assert(!self.part_active);
                const readiness = try self.sink.begin_part(self.sink.context, metadata);
                self.part_active = true;
                return readiness;
            },
            .part_data => |data| {
                std.debug.assert(self.part_active);
                const progress = try self.sink.write_chunk(self.sink.context, data);
                try body.validate_progress(data.len, progress);
                consumed.* += try self.parser.accept_data(progress.consumed);
                return progress.readiness;
            },
            .part_end => {
                std.debug.assert(self.part_active);
                self.part_active = false;
                return self.sink.end_part(self.sink.context);
            },
        }
    }
};
