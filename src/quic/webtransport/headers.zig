const varint = @import("varint.zig");
const session = @import("session.zig");

/// WebTransport unidirectional stream type.
pub const unidirectional_stream_type: u64 = 0x54;
/// WebTransport bidirectional stream prefix.
pub const bidirectional_stream_signal: u64 = 0x41;

/// Parsed WebTransport stream association prefix.
pub const StreamHeader = struct {
    /// CONNECT stream ID identifying the associated session.
    session_id: u64,
    /// Number of prefix bytes consumed from the stream.
    length: usize,
};

/// Failures from WebTransport stream-prefix coding.
pub const StreamHeaderError = error{
    /// The input ends within the prefix.
    NeedMoreData,
    /// A unidirectional stream carried another stream type.
    InvalidStreamType,
    /// A bidirectional stream carried another signal value.
    InvalidSignal,
    /// The session ID is not a client-initiated bidirectional stream ID.
    InvalidSessionId,
    /// Caller-owned output cannot hold the prefix.
    BufferTooSmall,
    /// A value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes a unidirectional association prefix without retaining `input`.
pub fn decode_unidirectional_header(input: []const u8) StreamHeaderError!StreamHeader {
    const stream_type = varint.decode_varint(input) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (stream_type.value != unidirectional_stream_type) return error.InvalidStreamType;
    const session_header = varint.decode_varint(input[stream_type.length..]) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (!session.valid_session_id(session_header.value)) return error.InvalidSessionId;
    return .{
        .session_id = session_header.value,
        .length = stream_type.length + session_header.length,
    };
}

/// Decodes a bidirectional association prefix without retaining `input`.
pub fn decode_bidirectional_header(input: []const u8) StreamHeaderError!StreamHeader {
    const signal = varint.decode_varint(input) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (signal.value != bidirectional_stream_signal) return error.InvalidSignal;
    const session_header = varint.decode_varint(input[signal.length..]) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (!session.valid_session_id(session_header.value)) return error.InvalidSessionId;
    return .{
        .session_id = session_header.value,
        .length = signal.length + session_header.length,
    };
}

/// Encodes a unidirectional association prefix into caller-owned `output`.
///
/// Returns the initialized prefix length. A short buffer can contain the
/// stream-type varint before `BufferTooSmall` is returned.
pub fn encode_unidirectional_header(session_id: u64, output: []u8) StreamHeaderError!usize {
    if (!session.valid_session_id(session_id)) return error.InvalidSessionId;
    return encode_stream_header(unidirectional_stream_type, session_id, output);
}

/// Encodes a bidirectional association prefix into caller-owned `output`.
///
/// Returns the initialized prefix length. A short buffer can contain the
/// signal varint before `BufferTooSmall` is returned.
pub fn encode_bidirectional_header(session_id: u64, output: []u8) StreamHeaderError!usize {
    if (!session.valid_session_id(session_id)) return error.InvalidSessionId;
    return encode_stream_header(bidirectional_stream_signal, session_id, output);
}

fn encode_stream_header(prefix: u64, session_id: u64, output: []u8) StreamHeaderError!usize {
    const prefix_length = varint.encode_varint(prefix, output) catch |encode_error| {
        return map_varint_stream_error(encode_error);
    };
    const session_length = varint.encode_varint(session_id, output[prefix_length..]) catch |encode_error| {
        return map_varint_stream_error(encode_error);
    };
    return prefix_length + session_length;
}

fn map_varint_stream_error(varint_error: varint.VarintError) StreamHeaderError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}
