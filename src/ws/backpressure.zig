const std = @import("std");

pub const Phase = enum(u8) {
    writable,
    backpressured,
    closing,
    closed,
    aborted,
};

/// Rejection of a zero high-water mark or an inverted mark pair.
pub const InitError = error{InvalidWaterMarks};

pub const State = struct {
    queued_bytes: usize = 0,
    high_water_mark: usize,
    low_water_mark: usize,
    phase: Phase = .writable,

    pub fn init(high_water_mark: usize, low_water_mark: usize) InitError!State {
        if (high_water_mark == 0 or low_water_mark > high_water_mark) {
            return error.InvalidWaterMarks;
        }
        return .{
            .high_water_mark = high_water_mark,
            .low_water_mark = low_water_mark,
        };
    }
};

pub const Event = union(enum) {
    enqueue: usize,
    flushed: usize,
    close,
    abort,
};

pub const Action = enum(u8) {
    none,
    write,
    pause_producer,
    resume_producer,
    close_transport,
    terminate_transport,
};

pub const Transition = struct {
    next_action: Action,
    new_state: State,
};

pub const TransitionError = error{
    ByteCountOverflow,
    FlushExceedsQueue,
    StreamClosed,
};

/// Computes the next flow-control state without mutating external state.
pub fn transition(current: State, event: Event) TransitionError!Transition {
    return switch (event) {
        .abort => .{
            .next_action = if (current.phase == .closed or current.phase == .aborted)
                .none
            else
                .terminate_transport,
            .new_state = with_phase(current, .aborted),
        },
        .close => close_transition(current),
        .enqueue => |byte_count| enqueue_transition(current, byte_count),
        .flushed => |byte_count| flush_transition(current, byte_count),
    };
}

fn enqueue_transition(current: State, byte_count: usize) TransitionError!Transition {
    if (current.phase == .closing or current.phase == .closed or current.phase == .aborted) {
        return error.StreamClosed;
    }
    const queued_bytes = std.math.add(usize, current.queued_bytes, byte_count) catch {
        return error.ByteCountOverflow;
    };
    var new_state = current;
    new_state.queued_bytes = queued_bytes;
    if (queued_bytes < current.high_water_mark) {
        return .{ .next_action = .write, .new_state = new_state };
    }
    new_state.phase = .backpressured;
    return .{ .next_action = .pause_producer, .new_state = new_state };
}

fn flush_transition(current: State, byte_count: usize) TransitionError!Transition {
    if (byte_count > current.queued_bytes) return error.FlushExceedsQueue;
    if (current.phase == .closed or current.phase == .aborted) {
        return .{ .next_action = .none, .new_state = current };
    }

    var new_state = current;
    new_state.queued_bytes -= byte_count;
    if (current.phase == .closing and new_state.queued_bytes == 0) {
        new_state.phase = .closed;
        return .{ .next_action = .close_transport, .new_state = new_state };
    }
    if (current.phase == .backpressured and new_state.queued_bytes <= current.low_water_mark) {
        new_state.phase = .writable;
        return .{ .next_action = .resume_producer, .new_state = new_state };
    }
    return .{ .next_action = .none, .new_state = new_state };
}

fn close_transition(current: State) Transition {
    if (current.phase == .closed or current.phase == .aborted) {
        return .{ .next_action = .none, .new_state = current };
    }
    if (current.queued_bytes != 0) {
        return .{ .next_action = .none, .new_state = with_phase(current, .closing) };
    }
    return .{ .next_action = .close_transport, .new_state = with_phase(current, .closed) };
}

fn with_phase(current: State, phase: Phase) State {
    var next = current;
    next.phase = phase;
    return next;
}
