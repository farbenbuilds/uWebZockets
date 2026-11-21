const std = @import("std");
const c = @import("c");
const backend = @import("backend.zig");
const child = @import("child_runtime.zig");
const binding = @import("binding.zig");
const wt = @import("../webtransport.zig");

const log = std.log.scoped(.quic);
const application_cancel = wt.application_error_to_http3(0);

/// Revalidates the stable stream lease, parent generation and shutdown state.
pub const LiveCallback = *const fn (*anyopaque, *const child.State) bool;
/// One concrete owner check; consumers never receive a native pointer.
pub const Guard = struct { context: *anyopaque, live: LiveCallback };
/// Root chooses a close cause after callbacks invalidate an association.
pub const Result = enum(u8) { progress, not_live };
/// Native cancellation retries retain the first immutable error.
pub const Actions = struct {
    stop_code: ?u64 = null,
    reset_code: ?u64 = null,
    stop: bool = false,
    reset: bool = false,
};

/// Borrowed only during synchronous native writef callbacks.
const Reader = struct { bytes: []const u8, consumed: usize = 0 };
/// Synchronous native-copy boundary; a compile-time binding also permits fault tests.
pub const WriteCallback = *const fn (?*c.lsquic_stream, [*c]c.struct_lsquic_reader) callconv(.c) isize;
pub const FlushCallback = *const fn (?*c.lsquic_stream) callconv(.c) c_int;
pub const WriteOperations = struct { write: WriteCallback, flush: FlushCallback };
pub const native_writer = WriteOperations{ .write = c.lsquic_stream_writef, .flush = c.lsquic_stream_flush };

fn reader_size(context: ?*anyopaque) callconv(.c) usize {
    const reader: *Reader = @ptrCast(@alignCast(context orelse return 0));
    return reader.bytes.len - reader.consumed;
}

fn reader_copy(context: ?*anyopaque, destination: ?*anyopaque, requested: usize) callconv(.c) usize {
    const reader: *Reader = @ptrCast(@alignCast(context orelse return 0));
    const count = @min(requested, reader.bytes.len - reader.consumed);
    if (count == 0) return 0;
    const output: [*]u8 = @ptrCast(destination orelse return 0);
    @memcpy(output[0..count], reader.bytes[reader.consumed..][0..count]);
    reader.consumed += count;
    return count;
}

/// Reader progress is authoritative even if native flushing subsequently fails.
pub fn write(comptime operations: WriteOperations, raw: *c.lsquic_stream, bytes: []const u8) child.WriteAttempt {
    var reader = Reader{ .bytes = bytes };
    var native = c.struct_lsquic_reader{ .lsqr_read = reader_copy, .lsqr_size = reader_size, .lsqr_ctx = &reader };
    // Internal packet-generation failures may leave libc errno unchanged.
    std.c._errno().* = 0;
    const result = operations.write(raw, &native);
    const write_error = if (result < 0) std.c.errno(result) else .SUCCESS;
    if (result < 0 and reader.consumed != 0) return child.complete_write(reader.consumed, .failed);
    if (result < 0) return child.complete_write(0, switch (write_error) {
        .AGAIN => .blocked,
        .BADF, .CONNRESET => .closed,
        else => .failed,
    });
    if (reader.consumed != 0 and operations.flush(raw) != 0) return child.complete_write(reader.consumed, .failed);
    return child.complete_write(reader.consumed, .progress);
}

/// Refreshes immutable receive facts without dispatching application callbacks.
pub fn observe_receive(raw: *c.lsquic_stream, state: *child.State) bool {
    var received: backend.ReceiveSnapshot = .{};
    if (backend.read_receive(raw, &received) != .ok) return false;
    _ = state.ledger.observe(received) catch |err| {
        log.warn("child receive snapshot failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

pub fn open(
    raw: *c.lsquic_stream,
    state: *child.State,
    actions: *Actions,
    info: child.Info,
    consumer: binding.ChildConsumer,
    guard: Guard,
) Result {
    if (!guard.live(guard.context, state)) return .not_live;
    const accepted = consumer.open(consumer.context, info);
    if (!accepted) _ = state.begin_close(.rejected, application_cancel);
    state.complete_open(accepted) catch |err| {
        log.err("child open transition failed: {s}", .{@errorName(err)});
        return .not_live;
    };
    // An accepting callback owns close even when it requested shutdown.
    if (!guard.live(guard.context, state)) return .not_live;
    if (!accepted) cancel(raw, state, actions, .rejected, application_cancel);
    return .progress;
}

fn snapshot(raw: *c.lsquic_stream, state: *child.State, actions: *Actions) bool {
    if (observe_receive(raw, state)) return true;
    cancel(raw, state, actions, .protocol_error, wt.h3_message_error);
    return false;
}

fn notifications(
    raw: *c.lsquic_stream,
    state: *child.State,
    actions: *Actions,
    consumer: binding.ChildConsumer,
    guard: Guard,
) Result {
    if (!state.consumer_owned) return .progress;
    const key = state.key orelse return .not_live;
    if (!guard.live(guard.context, state)) return .not_live;
    if (child.has_receive(state.metadata) and actions.stop_code == null) if (state.ledger.take_reset()) |code| {
        if (consumer.policy == .receive_only) _ = state.begin_close(.peer_reset, code);
        if (consumer.policy == .duplex) _ = c.lsquic_stream_shutdown(raw, 0);
        consumer.reset(consumer.context, key, code, state.ledger.final_payload_size.?);
        if (!guard.live(guard.context, state)) return .not_live;
    };
    if (state.ledger.take_stop()) |code| {
        consumer.stop(consumer.context, key, code);
        if (!guard.live(guard.context, state)) return .not_live;
    }
    if (state.phase == .closing and state.cancel_code != null) {
        cancel(raw, state, actions, state.cancel_reason.?, state.cancel_code.?);
    }
    return .progress;
}

/// Reads borrowed chunks only while the captured parent remains valid.
pub fn read(
    raw: *c.lsquic_stream,
    state: *child.State,
    actions: *Actions,
    consumer: binding.ChildConsumer,
    guard: Guard,
) Result {
    if (!guard.live(guard.context, state)) return .not_live;
    if (!snapshot(raw, state, actions)) return .progress;
    if (notifications(raw, state, actions, consumer, guard) == .not_live) return .not_live;
    if (!child.has_receive(state.metadata) or actions.stop_code != null or state.ledger.receive_terminal != .none) return .progress;
    var bytes: [2048]u8 = undefined;
    while (state.phase == .active and actions.stop_code == null and state.ledger.receive_terminal == .none) {
        if (!guard.live(guard.context, state)) return .not_live;
        const size = c.lsquic_stream_read(raw, &bytes, bytes.len);
        const read_error = if (size < 0) std.c.errno(size) else .SUCCESS;
        if (size > 0) {
            _ = state.ledger.record_read(@intCast(size)) catch |err| {
                log.warn("child payload accounting failed: {s}", .{@errorName(err)});
                cancel(raw, state, actions, .protocol_error, wt.h3_message_error);
                return .progress;
            };
        }
        if (!snapshot(raw, state, actions)) return .progress;
        if (size <= 0) {
            if (notifications(raw, state, actions, consumer, guard) == .not_live) return .not_live;
            if (state.phase != .active or actions.stop_code != null) return .progress;
            if (size == 0) return eof(raw, state, actions, consumer, guard);
            if (read_error != .AGAIN) cancel(raw, state, actions, .protocol_error, wt.wt_session_gone);
            return .progress;
        }
        if (!guard.live(guard.context, state)) return .not_live;
        const accepted = consumer.data(consumer.context, state.key.?, bytes[0..@intCast(size)]);
        if (!accepted) _ = state.begin_close(.consumer_cancelled, application_cancel);
        if (!guard.live(guard.context, state)) return .not_live;
        if (!accepted) {
            cancel(raw, state, actions, .consumer_cancelled, application_cancel);
            return .progress;
        }
        // A read can make a reliable reset visible; its last payload goes first.
        if (notifications(raw, state, actions, consumer, guard) == .not_live) return .not_live;
    }
    return .progress;
}

fn eof(
    raw: *c.lsquic_stream,
    state: *child.State,
    actions: *Actions,
    consumer: binding.ChildConsumer,
    guard: Guard,
) Result {
    const first = state.ledger.record_eof() catch |err| {
        log.warn("child EOF accounting failed: {s}", .{@errorName(err)});
        cancel(raw, state, actions, .protocol_error, wt.h3_message_error);
        return .progress;
    };
    if (first) {
        if (!guard.live(guard.context, state)) return .not_live;
        consumer.eof(consumer.context, state.key.?, state.ledger.final_payload_size.?);
        if (!guard.live(guard.context, state)) return .not_live;
    }
    _ = c.lsquic_stream_shutdown(raw, 0);
    if (consumer.policy == .receive_only) {
        _ = state.begin_close(.completed, null);
        if (state.metadata.direction == .bidi) _ = c.lsquic_stream_shutdown(raw, 1);
    }
    return .progress;
}

/// Cancellation affects this child; Root retains its lease through native close.
pub fn cancel(raw: *c.lsquic_stream, state: *child.State, actions: *Actions, reason: child.CloseReason, code: u64) void {
    _ = state.begin_close(reason, code);
    if (state.open_pending) {
        // Root calls this after open returns, or before invoking an invalid open.
        state.complete_open(false) catch |err| log.err("child cancelled open failed: {s}", .{@errorName(err)});
    }
    if (state.cancel_code) |first_code| {
        if (child.has_receive(state.metadata) and actions.stop_code == null) {
            actions.stop_code = first_code;
            actions.stop = true;
        }
        if (child.has_send(state.metadata) and actions.reset_code == null) {
            actions.reset_code = first_code;
            actions.reset = true;
        }
    }
    retry(raw, actions);
}

/// A pending write cancellation may need connection-level credit to resume.
pub fn retry(raw: *c.lsquic_stream, actions: *Actions) void {
    if (actions.stop) {
        const result = backend.stop_receiving(raw, actions.stop_code.?);
        actions.stop = result == .blocked;
        // Native RESET visibility need not close the application's read half.
        if (result == .closed) _ = c.lsquic_stream_shutdown(raw, 0);
        if (result == .invalid or result == .unsupported) {
            log.warn("child receive cancellation failed: {s}", .{@tagName(result)});
            // Native terminal/error state can no longer accept a new code.
            _ = c.lsquic_stream_shutdown(raw, 0);
        }
    }
    if (actions.reset) {
        const result = backend.reset_stream(raw, actions.reset_code.?);
        actions.reset = result == .blocked;
        // A prior peer STOP can already own the immutable native write error.
        if (result == .invalid or result == .unsupported) _ = c.lsquic_stream_shutdown(raw, 1);
    }
    if (actions.stop_code != null) _ = c.lsquic_stream_wantread(raw, 0);
}

/// Native close is authoritative even when the parent or connection is gone.
pub fn close(raw: *c.lsquic_stream, state: *child.State, consumer: ?binding.ChildConsumer) void {
    var received: backend.ReceiveSnapshot = .{};
    if (backend.read_receive(raw, &received) == .ok) {
        _ = state.ledger.observe(received) catch |err| failed: {
            log.warn("child close snapshot failed: {s}", .{@errorName(err)});
            // Preserve earlier immutable accounting when terminal metadata fails.
            break :failed .{};
        };
    }
    const event = state.finish_close() catch |err| {
        log.err("child close transition failed: {s}", .{@errorName(err)});
        return;
    };
    if (event) |closed| if (consumer) |active| active.closed(active.context, closed);
}
