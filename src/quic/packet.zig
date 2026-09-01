const std = @import("std");

/// Maximum connection identifier length permitted by QUIC invariants.
pub const max_connection_id_length = 20;

/// Packet form identified without decrypting protected header bits.
pub const PacketKind = enum {
    version_negotiation,
    initial,
    zero_rtt,
    handshake,
    retry,
    unknown_long,
    short,
};

/// Borrowed invariant fields from one QUIC packet.
pub const PacketHeader = struct {
    /// Packet form determined from invariant and version-specific bits.
    kind: PacketKind,
    /// Long-header version, or zero for short and negotiation packets.
    version: u32,
    /// Destination connection identifier when encoded in a long header.
    destination_id: []const u8,
    /// Source connection identifier when encoded in a long header.
    source_id: []const u8,
    /// Initial or Retry token bytes when present.
    token: []const u8,
    /// Protected packet bytes after the invariant fields.
    payload: []const u8,
    /// Bytes occupied by this packet in its containing UDP datagram.
    packet_length: usize,
};

const quic_v1: u32 = 0x00000001;
const quic_v2: u32 = 0x6b3343cf;

/// Parses one QUIC packet's bounded wire framing without allocating.
pub fn inspect_packet(data: []const u8) !PacketHeader {
    if (data.len == 0) return error.TruncatedPacket;

    const first = data[0];
    if (first & 0x80 == 0) {
        if (first & 0x40 == 0) return error.InvalidFixedBit;
        return .{
            .kind = .short,
            .version = 0,
            .destination_id = "",
            .source_id = "",
            .token = "",
            .payload = data[1..],
            .packet_length = data.len,
        };
    }

    if (data.len < 7) return error.TruncatedPacket;
    const version = read_u32(data[1..5]);
    var cursor: usize = 5;
    const destination_id = try read_connection_id(data, &cursor);
    const source_id = try read_connection_id(data, &cursor);

    if (version == 0) {
        const versions = data[cursor..];
        if (versions.len == 0 or versions.len % @sizeOf(u32) != 0) {
            return error.InvalidVersionNegotiation;
        }
        var offset: usize = 0;
        while (offset < versions.len) : (offset += @sizeOf(u32)) {
            if (read_u32(versions[offset .. offset + @sizeOf(u32)]) == 0) {
                return error.InvalidVersionNegotiation;
            }
        }
        return .{
            .kind = .version_negotiation,
            .version = 0,
            .destination_id = destination_id,
            .source_id = source_id,
            .token = "",
            .payload = versions,
            .packet_length = data.len,
        };
    }

    if (first & 0x40 == 0) return error.InvalidFixedBit;
    const kind = long_packet_kind(version, @truncate((first >> 4) & 0x03)) orelse {
        return .{
            .kind = .unknown_long,
            .version = version,
            .destination_id = destination_id,
            .source_id = source_id,
            .token = "",
            .payload = data[cursor..],
            .packet_length = data.len,
        };
    };

    if (kind == .retry) {
        if (data.len - cursor < 16) return error.TruncatedPacket;
        const token_end = data.len - 16;
        return .{
            .kind = kind,
            .version = version,
            .destination_id = destination_id,
            .source_id = source_id,
            .token = data[cursor..token_end],
            .payload = data[token_end..],
            .packet_length = data.len,
        };
    }

    var token: []const u8 = "";
    if (kind == .initial) {
        const token_length = try decode_varint_at(data, &cursor);
        const token_size = std.math.cast(usize, token_length) orelse {
            return error.LengthOverflow;
        };
        if (token_size > data.len - cursor) return error.TruncatedPacket;
        token = data[cursor .. cursor + token_size];
        cursor += token_size;
    }

    const encoded_length = try decode_varint_at(data, &cursor);
    const payload_length = std.math.cast(usize, encoded_length) orelse {
        return error.LengthOverflow;
    };
    if (payload_length == 0) return error.InvalidPayloadLength;
    if (payload_length > data.len - cursor) return error.TruncatedPacket;
    const packet_end = cursor + payload_length;

    return .{
        .kind = kind,
        .version = version,
        .destination_id = destination_id,
        .source_id = source_id,
        .token = token,
        .payload = data[cursor..packet_end],
        .packet_length = packet_end,
    };
}

fn read_connection_id(data: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* == data.len) return error.TruncatedPacket;
    const length = data[cursor.*];
    cursor.* += 1;
    if (length > max_connection_id_length) return error.InvalidConnectionIdLength;
    if (length > data.len - cursor.*) return error.TruncatedPacket;
    const identifier = data[cursor.* .. cursor.* + length];
    cursor.* += length;
    return identifier;
}

fn decode_varint_at(data: []const u8, cursor: *usize) !u64 {
    if (cursor.* == data.len) return error.TruncatedPacket;
    const first = data[cursor.*];
    const length: usize = @as(usize, 1) << @intCast(first >> 6);
    if (length > data.len - cursor.*) return error.TruncatedPacket;

    var value: u64 = first & 0x3f;
    var index: usize = 1;
    while (index < length) : (index += 1) {
        value = (value << 8) | data[cursor.* + index];
    }
    cursor.* += length;
    return value;
}

fn read_u32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= @sizeOf(u32));
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn long_packet_kind(version: u32, encoded: u2) ?PacketKind {
    return switch (version) {
        quic_v1 => switch (encoded) {
            0 => .initial,
            1 => .zero_rtt,
            2 => .handshake,
            3 => .retry,
        },
        quic_v2 => switch (encoded) {
            0 => .retry,
            1 => .initial,
            2 => .zero_rtt,
            3 => .handshake,
        },
        else => null,
    };
}
