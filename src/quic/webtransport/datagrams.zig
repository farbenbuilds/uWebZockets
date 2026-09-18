const std = @import("std");
const varint = @import("varint.zig");
const session = @import("session.zig");

/// QUIC transport parameter advertising datagram payload capacity.
pub const max_datagram_frame_size_parameter: u64 = 0x20;

/// Decoded WebTransport HTTP datagram.
pub const Datagram = struct {
    /// CONNECT stream ID reconstructed from the quarter-stream ID.
    session_id: u64,
    /// Payload borrowed from the decoder input.
    payload: []const u8,
    /// Number of bytes occupied by the quarter-stream ID.
    header_length: usize,
};

/// Failures from WebTransport datagram coding.
pub const DatagramError = error{
    /// The input ends within the quarter-stream ID.
    NeedMoreData,
    /// The decoded or supplied session ID is invalid.
    InvalidSessionId,
    /// Caller-owned output cannot hold the header and payload.
    BufferTooSmall,
    /// A value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes a WebTransport datagram and borrows its payload from `input`.
///
/// The returned payload remains valid only while `input` does.
pub fn decode_datagram(input: []const u8) DatagramError!Datagram {
    const quarter = varint.decode_varint(input) catch |decode_error| {
        return map_varint_datagram_error(decode_error);
    };
    const session_id = std.math.mul(u64, quarter.value, 4) catch return error.InvalidSessionId;
    if (!session.valid_session_id(session_id)) return error.InvalidSessionId;
    return .{
        .session_id = session_id,
        .payload = input[quarter.length..],
        .header_length = quarter.length,
    };
}

/// Encodes a datagram into caller-owned `output` without allocating.
///
/// `payload` may be released after return. A short buffer can contain the
/// encoded quarter-stream ID before `BufferTooSmall` is returned.
pub fn encode_datagram(session_id: u64, payload: []const u8, output: []u8) DatagramError!usize {
    if (!session.valid_session_id(session_id)) return error.InvalidSessionId;
    const header_length = varint.encode_varint(session_id / 4, output) catch |encode_error| {
        return map_varint_datagram_error(encode_error);
    };
    if (payload.len > output.len - header_length) return error.BufferTooSmall;
    @memcpy(output[header_length .. header_length + payload.len], payload);
    return header_length + payload.len;
}

fn map_varint_datagram_error(varint_error: varint.VarintError) DatagramError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}
