const std = @import("std");
const varint = @import("varint.zig");
const session = @import("session.zig");

/// WT_CLOSE_SESSION capsule type.
pub const wt_close_session: u64 = 0x2843;
/// WT_DRAIN_SESSION capsule type.
pub const wt_drain_session: u64 = 0x78ae;
/// WT_MAX_DATA capsule type.
pub const wt_max_data: u64 = 0x190b4d3d;
/// WT_MAX_STREAMS_BIDI capsule type.
pub const wt_max_streams_bidi: u64 = 0x190b4d3f;
/// WT_MAX_STREAMS_UNI capsule type.
pub const wt_max_streams_uni: u64 = 0x190b4d40;
/// WT_DATA_BLOCKED capsule type.
pub const wt_data_blocked: u64 = 0x190b4d41;
/// WT_STREAMS_BLOCKED_BIDI capsule type.
pub const wt_streams_blocked_bidi: u64 = 0x190b4d43;
/// WT_STREAMS_BLOCKED_UNI capsule type.
pub const wt_streams_blocked_uni: u64 = 0x190b4d44;

/// Maximum WT_CLOSE_SESSION reason length accepted or emitted.
pub const max_close_message_size: usize = 1024;

/// Payload of a decoded WT_CLOSE_SESSION capsule.
pub const CloseSession = struct {
    /// Application-defined 32-bit close code.
    application_error: u32,
    /// UTF-8 reason borrowed from the decoder input.
    message: []const u8,
};

/// Unknown capsule retained for extension-aware dispatch.
pub const UnknownCapsule = struct {
    /// Unrecognized QUIC-varint capsule type.
    capsule_type: u64,
    /// Payload borrowed from the decoder input.
    payload: []const u8,
};

/// Decoded WebTransport session capsule.
///
/// Slice-bearing variants borrow the input passed to `decode_capsule`.
pub const Capsule = union(enum) {
    /// Peer requested graceful session draining.
    drain_session,
    /// Peer closed the session with an application code and reason.
    close_session: CloseSession,
    /// Peer raised the session data credit.
    max_data: u64,
    /// Peer raised the bidirectional stream credit.
    max_streams_bidi: u64,
    /// Peer raised the unidirectional stream credit.
    max_streams_uni: u64,
    /// Peer reported exhaustion of session data credit.
    data_blocked: u64,
    /// Peer reported exhaustion of bidirectional stream credit.
    streams_blocked_bidi: u64,
    /// Peer reported exhaustion of unidirectional stream credit.
    streams_blocked_uni: u64,
    /// Extension capsule not interpreted by this module.
    unknown: UnknownCapsule,
};

/// One decoded capsule and the total bytes consumed from the input.
pub const DecodedCapsule = struct {
    /// Parsed capsule value.
    capsule: Capsule,
    /// Header plus payload length, for advancing an incremental parser.
    length: usize,
};

/// Failures from WebTransport capsule coding.
pub const CapsuleError = error{
    /// The input does not contain a complete capsule.
    NeedMoreData,
    /// The encoded payload length cannot fit in `usize`.
    LengthOverflow,
    /// A known capsule carried an invalid payload length.
    InvalidLength,
    /// A close reason is not valid UTF-8.
    InvalidUtf8,
    /// A decoded stream limit exceeds `max_stream_count`.
    InvalidStreamLimit,
    /// Caller-owned output cannot hold the capsule.
    BufferTooSmall,
    /// A type, length, or value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes one complete capsule without allocating.
///
/// Returned message and unknown-payload slices borrow `input` and remain valid
/// only while it does. `NeedMoreData` carries no retained parser state.
pub fn decode_capsule(input: []const u8) CapsuleError!DecodedCapsule {
    const capsule_type = varint.decode_varint(input) catch |decode_error| {
        return map_varint_capsule_error(decode_error);
    };
    const encoded_length = varint.decode_varint(input[capsule_type.length..]) catch |decode_error| {
        return map_varint_capsule_error(decode_error);
    };
    if (encoded_length.value > std.math.maxInt(usize)) return error.LengthOverflow;
    const header_length = capsule_type.length + encoded_length.length;
    const payload_length: usize = @intCast(encoded_length.value);
    if (payload_length > input.len -| header_length) return error.NeedMoreData;
    const payload = input[header_length .. header_length + payload_length];

    const capsule: Capsule = switch (capsule_type.value) {
        wt_drain_session => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .drain_session;
        },
        wt_close_session => blk: {
            if (payload.len < 4 or payload.len > 4 + max_close_message_size) {
                return error.InvalidLength;
            }
            const message = payload[4..];
            if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
            const application_error_bytes: *const [4]u8 = @ptrCast(payload.ptr);
            break :blk .{ .close_session = .{
                .application_error = std.mem.readInt(u32, application_error_bytes, .big),
                .message = message,
            } };
        },
        wt_max_data => .{ .max_data = try decode_capsule_integer(payload, false) },
        wt_max_streams_bidi => .{ .max_streams_bidi = try decode_capsule_integer(payload, true) },
        wt_max_streams_uni => .{ .max_streams_uni = try decode_capsule_integer(payload, true) },
        wt_data_blocked => .{ .data_blocked = try decode_capsule_integer(payload, false) },
        wt_streams_blocked_bidi => .{ .streams_blocked_bidi = try decode_capsule_integer(payload, true) },
        wt_streams_blocked_uni => .{ .streams_blocked_uni = try decode_capsule_integer(payload, true) },
        else => .{ .unknown = .{ .capsule_type = capsule_type.value, .payload = payload } },
    };
    return .{ .capsule = capsule, .length = header_length + payload_length };
}

/// Encodes a zero-length drain capsule into caller-owned `output`.
pub fn encode_drain_session(output: []u8) CapsuleError!usize {
    return encode_capsule_header(wt_drain_session, 0, output);
}

/// Encodes a close capsule into caller-owned `output` without allocation.
///
/// `message` must be valid UTF-8 and at most `max_close_message_size` bytes.
/// A short buffer may contain a partial header on error.
pub fn encode_close_session(application_error: u32, message: []const u8, output: []u8) CapsuleError!usize {
    if (message.len > max_close_message_size) return error.InvalidLength;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
    const payload_length = 4 + message.len;
    const header_length = try encode_capsule_header(wt_close_session, payload_length, output);
    if (payload_length > output.len - header_length) return error.BufferTooSmall;
    const application_error_bytes: *[4]u8 = @ptrCast(output[header_length..].ptr);
    std.mem.writeInt(u32, application_error_bytes, application_error, .big);
    @memcpy(output[header_length + 4 .. header_length + payload_length], message);
    return header_length + payload_length;
}

/// Encodes a single-varint capsule into caller-owned `output`.
///
/// This primitive does not restrict `capsule_type` to known flow-control types
/// or apply `max_stream_count`. A short output may retain a partial header.
pub fn encode_integer_capsule(capsule_type: u64, value: u64, output: []u8) CapsuleError!usize {
    var integer: [8]u8 = undefined;
    const integer_length = varint.encode_varint(value, &integer) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    const header_length = try encode_capsule_header(capsule_type, integer_length, output);
    if (integer_length > output.len - header_length) return error.BufferTooSmall;
    @memcpy(output[header_length .. header_length + integer_length], integer[0..integer_length]);
    return header_length + integer_length;
}

/// Mutable receive-side WebTransport session flow-control state.
pub const FlowState = struct {
    /// Current aggregate data credit.
    max_data: u64 = 0,
    /// Current bidirectional stream credit.
    max_streams_bidi: u64 = 0,
    /// Current unidirectional stream credit.
    max_streams_uni: u64 = 0,
    /// Whether the peer sent WT_DRAIN_SESSION.
    draining: bool = false,
    /// Whether the peer sent WT_CLOSE_SESSION.
    closed: bool = false,
};

/// Dispatch result after applying a decoded capsule.
pub const CapsuleAction = enum(u8) {
    /// The capsule changed session state.
    applied,
    /// The capsule is unknown or flow control is disabled.
    ignored,
    /// The peer reported a flow-control blocked condition.
    peer_blocked,
};

/// Semantic failures while applying session flow-control capsules.
pub const FlowError = error{
    /// A credit failed to increase monotonically or exceeded its limit.
    FlowControlViolation,
};

/// Applies one capsule to caller-owned session flow state.
///
/// Drain and close capsules apply regardless of `enabled`. Disabled flow
/// control ignores all credit and blocked capsules. Errors leave the targeted
/// credit unchanged.
pub fn apply_capsule(state: *FlowState, capsule: Capsule, enabled: bool) FlowError!CapsuleAction {
    return switch (capsule) {
        .drain_session => blk: {
            state.draining = true;
            break :blk .applied;
        },
        .close_session => blk: {
            state.closed = true;
            break :blk .applied;
        },
        .max_data => |value| if (!enabled)
            .ignored
        else blk: {
            if (value <= state.max_data) return error.FlowControlViolation;
            state.max_data = value;
            break :blk .applied;
        },
        .max_streams_bidi => |value| if (!enabled)
            .ignored
        else blk: {
            if (value > session.max_stream_count or value <= state.max_streams_bidi) {
                return error.FlowControlViolation;
            }
            state.max_streams_bidi = value;
            break :blk .applied;
        },
        .max_streams_uni => |value| if (!enabled)
            .ignored
        else blk: {
            if (value > session.max_stream_count or value <= state.max_streams_uni) {
                return error.FlowControlViolation;
            }
            state.max_streams_uni = value;
            break :blk .applied;
        },
        .data_blocked, .streams_blocked_bidi, .streams_blocked_uni => if (enabled)
            .peer_blocked
        else
            .ignored,
        .unknown => .ignored,
    };
}

fn decode_capsule_integer(payload: []const u8, stream_limit: bool) CapsuleError!u64 {
    const value = varint.decode_varint(payload) catch |decode_error| {
        return map_varint_capsule_error(decode_error);
    };
    if (value.length != payload.len) return error.InvalidLength;
    if (stream_limit and value.value > session.max_stream_count) return error.InvalidStreamLimit;
    return value.value;
}

fn encode_capsule_header(capsule_type: u64, payload_length: usize, output: []u8) CapsuleError!usize {
    const type_length = varint.encode_varint(capsule_type, output) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    const length_length = varint.encode_varint(payload_length, output[type_length..]) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    return type_length + length_length;
}

fn map_varint_capsule_error(varint_error: varint.VarintError) CapsuleError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}
