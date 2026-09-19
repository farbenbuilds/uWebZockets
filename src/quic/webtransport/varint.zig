/// Largest value representable by a QUIC variable-length integer.
pub const max_quic_varint: u64 = (1 << 62) - 1;

/// Decoded QUIC variable-length integer and its encoded byte count.
pub const Varint = struct {
    /// Decoded integer value.
    value: u64,
    /// Number of input bytes consumed.
    length: usize,
};

/// Failures from QUIC variable-length integer coding.
pub const VarintError = error{
    /// The input does not contain a complete integer.
    NeedMoreData,
    /// The requested value exceeds `max_quic_varint`.
    ValueTooLarge,
    /// The caller-owned output cannot hold the encoded integer.
    BufferTooSmall,
};

/// Decodes one QUIC variable-length integer without retaining `input`.
///
/// Non-minimal encodings are accepted. `NeedMoreData` leaves no parser state;
/// callers should retry with the complete prefix.
pub fn decode_varint(input: []const u8) VarintError!Varint {
    if (input.len == 0) return error.NeedMoreData;
    const length: usize = @as(usize, 1) << @intCast(input[0] >> 6);
    if (input.len < length) return error.NeedMoreData;

    var value: u64 = input[0] & 0x3f;
    var index: usize = 1;
    while (index < length) : (index += 1) {
        value = (value << 8) | input[index];
    }
    return .{ .value = value, .length = length };
}

/// Encodes one integer minimally into caller-owned `output`.
///
/// Returns the number of initialized bytes. Both errors are detected before
/// writing, so `output` remains unchanged on failure.
pub fn encode_varint(value: u64, output: []u8) VarintError!usize {
    if (value > max_quic_varint) return error.ValueTooLarge;
    const length: usize = if (value < (1 << 6))
        1
    else if (value < (1 << 14))
        2
    else if (value < (1 << 30))
        4
    else
        8;
    if (output.len < length) return error.BufferTooSmall;

    var remaining = value;
    var index = length;
    while (index != 0) {
        index -= 1;
        output[index] = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
    output[0] |= switch (length) {
        1 => 0x00,
        2 => 0x40,
        4 => 0x80,
        8 => 0xc0,
        else => unreachable,
    };
    return length;
}
