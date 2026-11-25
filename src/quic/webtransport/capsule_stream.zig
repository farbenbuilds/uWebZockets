const capsule = @import("capsule.zig");
const varint = @import("varint.zig");

const carry_capacity = 16 + 4 + capsule.max_close_message_size;

/// Negotiated capsule policy; the zero value preserves strict codec validation.
pub const Options = struct {
    ignore_flow_control: bool = false,
};

/// Known values borrow decoder storage; skipped types precede payload skipping.
pub const Event = union(enum) {
    capsule: capsule.Capsule,
    unknown: u64,
};

/// At most one event; `consumed` advances within the supplied input only.
pub const ConsumeResult = struct {
    consumed: usize,
    event: ?Event = null,
};

/// Fragmentation is not an error; complete malformed capsules retain codec errors.
pub const Error = capsule.CapsuleError || error{
    TruncatedCapsule,
    DecoderFailed,
};

const Phase = enum(u8) { capsule_type, length, payload, skip, failed };

/// Allocation-free capsule carry; callers must not alter its parser fields.
///
/// Close text remains valid until the next `consume`. Unknown payload is never
/// retained, irrespective of its declared size. A `consume` error is terminal.
pub const Decoder = struct {
    carry: [carry_capacity]u8 = undefined,
    skip_remaining: u64 = 0,
    capsule_type: u64 = 0,
    carry_used: usize = 0,
    integer_start: usize = 0,
    payload_remaining: usize = 0,
    options: Options = .{},
    phase: Phase = .capsule_type,

    /// Binds negotiated policy before consuming any stream bytes.
    pub fn init(options: Options) Decoder {
        return .{ .options = options };
    }

    /// Consumes bytes through one event, retaining only a bounded known capsule.
    pub fn consume(decoder: *Decoder, input: []const u8) Error!ConsumeResult {
        errdefer decoder.phase = .failed;
        var offset: usize = 0;
        while (true) {
            switch (decoder.phase) {
                .capsule_type => {
                    if (offset == input.len) return .{ .consumed = offset };
                    const complete = decoder.append_header_byte(input[offset]);
                    offset += 1;
                    if (!complete) continue;
                    decoder.capsule_type = (try varint.decode_varint(decoder.carry[0..decoder.carry_used])).value;
                    decoder.integer_start = decoder.carry_used;
                    decoder.phase = .length;
                },
                .length => {
                    if (offset == input.len) return .{ .consumed = offset };
                    const complete = decoder.append_header_byte(input[offset]);
                    offset += 1;
                    if (!complete) continue;
                    const length = (try varint.decode_varint(decoder.carry[decoder.integer_start..decoder.carry_used])).value;
                    if (try known_payload_size(decoder.capsule_type, length, decoder.options)) |size| {
                        decoder.payload_remaining = size;
                        decoder.phase = .payload;
                        continue;
                    }
                    decoder.skip_remaining = length;
                    decoder.carry_used = 0;
                    decoder.integer_start = 0;
                    decoder.phase = if (length == 0) .capsule_type else .skip;
                    return .{ .consumed = offset, .event = .{ .unknown = decoder.capsule_type } };
                },
                .payload => {
                    if (decoder.payload_remaining == 0) {
                        const decoded = try capsule.decode_capsule(decoder.carry[0..decoder.carry_used]);
                        decoder.carry_used = 0;
                        decoder.integer_start = 0;
                        decoder.phase = .capsule_type;
                        return .{ .consumed = offset, .event = .{ .capsule = decoded.capsule } };
                    }
                    if (offset == input.len) return .{ .consumed = offset };
                    const size = @min(decoder.payload_remaining, input.len - offset);
                    @memcpy(decoder.carry[decoder.carry_used..][0..size], input[offset..][0..size]);
                    decoder.carry_used += size;
                    decoder.payload_remaining -= size;
                    offset += size;
                },
                .skip => {
                    if (offset == input.len) return .{ .consumed = offset };
                    const size: usize = @intCast(@min(decoder.skip_remaining, @as(u64, input.len - offset)));
                    decoder.skip_remaining -= size;
                    offset += size;
                    if (decoder.skip_remaining == 0) decoder.phase = .capsule_type;
                },
                .failed => return error.DecoderFailed,
            }
        }
    }

    /// Checks EOF without changing state, including an unfinished unknown skip.
    pub fn finish(decoder: *const Decoder) Error!void {
        if (decoder.phase == .failed) return error.DecoderFailed;
        if (decoder.phase != .capsule_type or decoder.carry_used != 0) return error.TruncatedCapsule;
    }

    fn append_header_byte(decoder: *Decoder, byte: u8) bool {
        decoder.carry[decoder.carry_used] = byte;
        decoder.carry_used += 1;
        const encoded_size = @as(usize, 1) << @intCast(decoder.carry[decoder.integer_start] >> 6);
        return decoder.carry_used - decoder.integer_start == encoded_size;
    }
};

fn known_payload_size(capsule_type: u64, length: u64, options: Options) Error!?usize {
    if (options.ignore_flow_control and flow_control_capsule(capsule_type)) return null;
    switch (capsule_type) {
        capsule.wt_close_session => if (length < 4 or length > 4 + capsule.max_close_message_size) return error.InvalidLength,
        capsule.wt_drain_session => if (length != 0) return error.InvalidLength,
        capsule.wt_max_data,
        capsule.wt_max_streams_bidi,
        capsule.wt_max_streams_uni,
        capsule.wt_data_blocked,
        capsule.wt_streams_blocked_bidi,
        capsule.wt_streams_blocked_uni,
        => if (length > 8) return error.InvalidLength,
        else => return null,
    }
    return @intCast(length);
}

fn flow_control_capsule(capsule_type: u64) bool {
    return switch (capsule_type) {
        capsule.wt_max_data,
        capsule.wt_max_streams_bidi,
        capsule.wt_max_streams_uni,
        capsule.wt_data_blocked,
        capsule.wt_streams_blocked_bidi,
        capsule.wt_streams_blocked_uni,
        => true,
        else => false,
    };
}
