const std = @import("std");
const support = @import("test_support");
const multipart = support.multipart;
const adapter = support.multipart_sink;
const body = support.request_body;

const entity = "preamble\r\n--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nhello\r\n--ab--\r\nepilogue";
const terminal_entity = "--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nhello\r\n--ab--";
const Event = enum { begin, write, end, cancel };

const Buffers = struct { headers: [128]u8 = undefined, carry: [6]u8 = undefined };

const Recorder = struct {
    output: [512]u8 = undefined,
    length: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    cancels: usize = 0,
    pause: ?Event = null,
    failure: ?Event = null,
    next_progress: ?body.BodyProgress = null,
    slow: bool = false,
    reason: ?body.BodyCancelReason = null,

    fn callbacks(self: *Recorder) adapter.PartSink {
        return .{ .context = self, .begin_part = begin, .write_chunk = write, .end_part = end, .cancel_part = cancel };
    }

    fn begin(context: *anyopaque, meta: multipart.PartMeta) !body.BodyReadiness {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.begins += 1;
        try std.testing.expectEqualStrings("x", meta.name);
        if (self.failure == .begin) return error.CallbackFailed;
        return self.readiness(.begin);
    }

    fn write(context: *anyopaque, input: []const u8) !body.BodyProgress {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.failure == .write) return error.CallbackFailed;
        const progress = self.next_progress orelse body.BodyProgress{
            .consumed = if (self.slow) 1 else input.len,
            .readiness = if (self.slow) .paused else self.readiness(.write),
        };
        self.next_progress = null;
        if (progress.consumed > input.len) return progress;
        if (self.length + progress.consumed > self.output.len) return error.OutputFull;
        @memcpy(self.output[self.length..][0..progress.consumed], input[0..progress.consumed]);
        self.length += progress.consumed;
        return progress;
    }

    fn end(context: *anyopaque) !body.BodyReadiness {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.ends += 1;
        if (self.failure == .end) return error.CallbackFailed;
        return self.readiness(.end);
    }

    fn cancel(context: *anyopaque, reason: body.BodyCancelReason) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.cancels += 1;
        self.reason = reason;
    }

    fn readiness(self: *Recorder, event: Event) body.BodyReadiness {
        if (self.pause != event) return .ready;
        self.pause = null;
        return .paused;
    }
};

fn make_adapter(recorder: *Recorder, buffers: *Buffers) !adapter.MultipartSink {
    return .{
        .parser = try multipart.StreamingParser.init("ab", .{
            .max_body_bytes = 4096,
            .max_parts = 8,
            .max_part_headers = 4,
        }, .{ .headers = &buffers.headers, .carry = &buffers.carry }),
        .sink = recorder.callbacks(),
    };
}

fn consume_all(sink: *adapter.MultipartSink, input: []const u8) !void {
    var offset: usize = 0;
    var calls: usize = 0;
    while (offset < input.len) {
        calls += 1;
        try std.testing.expect(calls <= 1024);
        const progress = try sink.consume(input[offset..]);
        try body.validate_progress(input.len - offset, progress);
        offset += progress.consumed;
    }
}

test "multipart sink: complete entity streams and finishes exactly once" {
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, entity);
    try sink.finish();
    sink.cancel(.cancelled);
    try std.testing.expectError(error.InvalidMultipartState, sink.finish());
    try std.testing.expectEqualStrings("hello", recorder.output[0..recorder.length]);
    try std.testing.expectEqual(@as(usize, 1), recorder.begins);
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: paused begin write and end are committed once" {
    for ([_]Event{ .begin, .write, .end }) |event| {
        var recorder = Recorder{ .pause = event };
        var buffers = Buffers{};
        var sink = try make_adapter(&recorder, &buffers);
        try consume_all(&sink, entity);
        try sink.finish();
        try std.testing.expectEqualStrings("hello", recorder.output[0..recorder.length]);
        try std.testing.expectEqual(@as(usize, 1), recorder.begins);
        try std.testing.expectEqual(@as(usize, 1), recorder.ends);
        try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
    }
}

test "multipart sink: slow partial acknowledgements preserve false prefixes" {
    const input = "--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nA\r\n--abX\r\r\n--abY\r\n--ab--";
    var recorder = Recorder{ .slow = true };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    for (input) |byte| {
        var current = [_]u8{byte};
        try consume_all(&sink, &current);
        current[0] = 0xcc;
    }
    try sink.finish();
    try std.testing.expectEqualStrings("A\r\n--abX\r\r\n--abY", recorder.output[0..recorder.length]);
}

test "multipart sink: failed begin rolls itself back without cancellation" {
    var recorder = Recorder{ .failure = .begin };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try std.testing.expectError(error.CallbackFailed, sink.consume(entity));
    sink.cancel(.sink_failure);
    sink.cancel(.cancelled);
    try std.testing.expectEqual(@as(usize, 1), recorder.begins);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: write failure retains cleanup until outer cancellation" {
    var recorder = Recorder{ .failure = .write };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try std.testing.expectError(error.CallbackFailed, sink.consume(entity));
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
    sink.cancel(.reset);
    sink.cancel(.cancelled);
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    try std.testing.expectEqual(body.BodyCancelReason.reset, recorder.reason.?);
}

test "multipart sink: end owns cleanup even when it fails" {
    var recorder = Recorder{ .failure = .end };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try std.testing.expectError(error.CallbackFailed, sink.consume(entity));
    sink.cancel(.sink_failure);
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: invalid progress is rejected before parser acknowledgement" {
    for ([_]body.BodyProgress{
        .{ .consumed = 1, .readiness = .ready },
        .{ .consumed = 99, .readiness = .paused },
    }) |progress| {
        var recorder = Recorder{ .next_progress = progress };
        var buffers = Buffers{};
        var sink = try make_adapter(&recorder, &buffers);
        try std.testing.expectError(error.InvalidBodyProgress, sink.consume(entity));
        try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
        const payload_start = std.mem.indexOf(u8, entity, "hello").?;
        try std.testing.expectEqual(@as(u64, payload_start), sink.parser.total_bytes);
        sink.cancel(.sink_failure);
        try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    }
}

test "multipart sink: failed finish cancels the accepted part once" {
    const input = "--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nhello";
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, input);
    try std.testing.expectError(error.IncompleteMultipartBody, sink.finish());
    try std.testing.expectEqual(body.BodyCancelReason.invalid_body, recorder.reason.?);
    sink.cancel(.peer_closed);
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    try std.testing.expectEqual(@as(usize, 0), recorder.ends);
}

test "multipart sink: paused final end needs no synthetic chunk" {
    var recorder = Recorder{ .pause = .end };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    const progress = try sink.consume(terminal_entity);
    try std.testing.expectEqual(terminal_entity.len, progress.consumed);
    try std.testing.expectEqual(body.BodyReadiness.paused, progress.readiness);
    try sink.finish();
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: every initial paused payload prefix preserves output" {
    for (0..6) |accepted| {
        var recorder = Recorder{ .next_progress = .{ .consumed = accepted, .readiness = .paused } };
        var buffers = Buffers{};
        var sink = try make_adapter(&recorder, &buffers);
        try consume_all(&sink, entity);
        try sink.finish();
        try std.testing.expectEqualStrings("hello", recorder.output[0..recorder.length]);
        try std.testing.expectEqual(@as(usize, 1), recorder.begins);
        try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    }
}

test "multipart sink: cancellation after paused metadata owns only active parts" {
    for ([_]Event{ .begin, .end }) |event| {
        var recorder = Recorder{ .pause = event };
        var buffers = Buffers{};
        var sink = try make_adapter(&recorder, &buffers);
        const progress = try sink.consume(entity);
        try std.testing.expectEqual(body.BodyReadiness.paused, progress.readiness);
        sink.cancel(.shutdown);
        sink.cancel(.cancelled);
        try std.testing.expectEqual(@as(usize, if (event == .begin) 1 else 0), recorder.cancels);
        try std.testing.expectError(error.InvalidMultipartState, sink.consume(entity));
    }
}

test "multipart sink: parser error keeps accepted cleanup until outer unwind" {
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    const payload_start = std.mem.indexOf(u8, entity, "hello").?;
    sink.parser.limits.max_body_bytes = payload_start + 2;
    try std.testing.expectError(error.MultipartBodyTooLarge, sink.consume(entity));
    try std.testing.expectEqual(@as(usize, 1), recorder.begins);
    try std.testing.expectEqual(@as(usize, 0), recorder.length);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
    sink.cancel(.sink_failure);
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
}

/// Minimal retained-input owner using the real outer body lifecycle.
const UploadOwner = struct {
    state: body.BodyState = .{},
    sink: *adapter.MultipartSink,
    queued: []const u8 = "",
    complete: bool = false,
    chunk_calls: usize = 0,
    end_calls: usize = 0,
    releases: usize = 0,

    fn start(self: *UploadOwner) !body.BodyControl {
        const control = try self.state.arm(.{
            .context = self,
            .resume_fn = resume_upload,
            .cancel_fn = cancel_upload,
        }, .{ .max_body_bytes = 4096, .max_active = 1 }, null);
        std.debug.assert(self.state.accept_begin(.{ .context = self }) == null);
        return control;
    }

    fn feed(self: *UploadOwner, input: []const u8) !void {
        try self.state.observe(input.len);
        self.queued = input;
        self.complete = true;
        try self.drive();
    }

    fn drive(self: *UploadOwner) error{BodyDeliveryFailed}!void {
        if (self.state.readiness == .paused) return;
        if (self.queued.len != 0) {
            self.state.start_chunk(self.queued.len) catch return error.BodyDeliveryFailed;
            self.chunk_calls += 1;
            const progress = self.sink.consume(self.queued) catch {
                self.cancel_terminal(self.state.fail_chunk());
                return error.BodyDeliveryFailed;
            };
            const terminal = self.state.accept_chunk(progress) catch {
                self.cancel_terminal(self.state.fail_chunk());
                return error.BodyDeliveryFailed;
            };
            if (terminal) |action| {
                self.cancel_terminal(action);
                return error.BodyDeliveryFailed;
            }
            self.queued = self.queued[progress.consumed..];
        }
        if (self.state.readiness == .paused or !self.complete or self.queued.len != 0) return;
        const terminal = self.state.take_end(true, 0) catch return error.BodyDeliveryFailed;
        std.debug.assert(terminal == .end);
        defer self.release();
        self.end_calls += 1;
        self.sink.finish() catch return error.BodyDeliveryFailed;
    }

    fn cancel_terminal(self: *UploadOwner, terminal: body.BodyTerminal) void {
        std.debug.assert(terminal == .cancel);
        self.sink.cancel(terminal.cancel.reason);
        self.release();
    }

    fn release(self: *UploadOwner) void {
        if (self.state.finish_terminal()) self.releases += 1;
    }

    fn resume_upload(context: *anyopaque) error{BodyDeliveryFailed}!void {
        const self: *UploadOwner = @ptrCast(@alignCast(context));
        return self.drive();
    }

    fn cancel_upload(context: *anyopaque) void {
        const self: *UploadOwner = @ptrCast(@alignCast(context));
        const terminal = self.state.request_cancel(.cancelled) orelse return;
        self.cancel_terminal(terminal);
    }
};

test "multipart sink: outer control resumes final end without an empty chunk" {
    var recorder = Recorder{ .pause = .end };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    var owner = UploadOwner{ .sink = &sink };
    const control = try owner.start();
    try owner.feed(terminal_entity);
    try std.testing.expectEqual(@as(usize, 0), owner.queued.len);
    try std.testing.expectEqual(@as(usize, 0), owner.end_calls);
    try std.testing.expectEqual(@as(usize, 0), owner.releases);
    try control.@"resume"();
    try std.testing.expectEqual(@as(usize, 1), owner.chunk_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.end_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectError(error.BodyControlExpired, control.cancel());
}

test "multipart sink: outer failure cancels after consume returns and expires controls" {
    var recorder = Recorder{ .failure = .write };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    var owner = UploadOwner{ .sink = &sink };
    const control = try owner.start();
    try std.testing.expectError(error.BodyDeliveryFailed, owner.feed(entity));
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
    try std.testing.expectEqual(body.BodyCancelReason.sink_failure, recorder.reason.?);
    try std.testing.expectError(error.BodyControlExpired, control.@"resume"());
}

test "multipart sink: failed outer end releases once without later cancellation" {
    const truncated = "--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nhello";
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    var owner = UploadOwner{ .sink = &sink };
    const control = try owner.start();
    try std.testing.expectError(error.BodyDeliveryFailed, owner.feed(truncated));
    try std.testing.expectEqual(@as(usize, 1), owner.end_calls);
    try std.testing.expectEqual(@as(usize, 1), owner.releases);
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    try std.testing.expectError(error.BodyControlExpired, control.cancel());
}

const first_part = "--ab\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\none\r\n--ab\r\n";
const second_part = "Content-Disposition: form-data; name=\"x\"\r\n\r\ntwo\r\n--ab--";

test "multipart sink: multiple parts retain paused boundary ownership" {
    var recorder = Recorder{ .pause = .end };
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, first_part);
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    recorder.pause = .begin;
    try consume_all(&sink, second_part);
    try sink.finish();
    try std.testing.expectEqualStrings("onetwo", recorder.output[0..recorder.length]);
    try std.testing.expectEqual(@as(usize, 2), recorder.begins);
    try std.testing.expectEqual(@as(usize, 2), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: second part write failure cancels only that active part" {
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, first_part);
    recorder.failure = .write;
    try std.testing.expectError(error.CallbackFailed, sink.consume(second_part));
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
    sink.cancel(.peer_closed);
    sink.cancel(.cancelled);
    try std.testing.expectEqual(@as(usize, 1), recorder.cancels);
    try std.testing.expectEqual(body.BodyCancelReason.peer_closed, recorder.reason.?);
}

test "multipart sink: second part failed begin does not recancel the ended part" {
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, first_part);
    recorder.failure = .begin;
    try std.testing.expectError(error.CallbackFailed, sink.consume(second_part));
    sink.cancel(.sink_failure);
    try std.testing.expectEqual(@as(usize, 2), recorder.begins);
    try std.testing.expectEqual(@as(usize, 1), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}

test "multipart sink: failed second end owns both part cleanups" {
    var recorder = Recorder{};
    var buffers = Buffers{};
    var sink = try make_adapter(&recorder, &buffers);
    try consume_all(&sink, first_part);
    recorder.failure = .end;
    try std.testing.expectError(error.CallbackFailed, sink.consume(second_part));
    sink.cancel(.sink_failure);
    try std.testing.expectEqualStrings("onetwo", recorder.output[0..recorder.length]);
    try std.testing.expectEqual(@as(usize, 2), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.cancels);
}
