//! Pure Linux ancillary validation and bounded GRO datagram views.

const std = @import("std");
const control_abi = @import("udp_control.zig");

/// Existing per-datagram QUIC input bound.
pub const max_datagram_bytes = @import("../quic/lsquic_api.zig").max_udp_payload_size;
/// Project receive budget; larger kernel aggregates fail closed.
pub const max_segments = 64;
/// Fixed storage required for one bounded aggregate.
pub const aggregate_bytes = max_segments * max_datagram_bytes;
pub const udp_level = 17;
pub const gro_type = 104;
pub const ip4_level = 0;
pub const ip4_packet_info = 8;
pub const ip6_level = 41;
pub const ip6_packet_info = 50;
pub const message_truncated = 0x20;
pub const control_truncated = 0x08;

/// Linux cmsghdr ABI, including its native size_t length.
pub const ControlHeader = control_abi.Header;

/// Aligned offset of a Linux ancillary payload.
pub const control_header_size = control_abi.header_size;

/// Linux IP_PKTINFO ABI; address bytes retain network order.
pub const PacketInfo4 = control_abi.PacketInfo4;

/// Linux IPV6_PKTINFO ABI; interface identifies the IPv6 scope.
pub const PacketInfo6 = control_abi.PacketInfo6;

/// Invalid kernel metadata is rejected before exposing any datagram.
pub const ReceiveError = error{
    EmptyDatagram,
    TruncatedDatagram,
    TruncatedControl,
    MalformedControl,
    DuplicateControl,
    InvalidSegmentSize,
    TooManySegments,
    DatagramTooLarge,
    MissingDestination,
    InvalidDestination,
    InvalidPeer,
};

/// Borrowed, prevalidated datagrams sharing one peer and local destination.
pub const Batch = struct {
    data: []const u8,
    local_address: std.Io.net.IpAddress,
    segment_size: usize,
    gro: bool,
    offset: usize = 0,

    /// Advances within the borrowed aggregate, permitting a shorter final packet.
    pub fn next(self: *Batch) ?[]const u8 {
        if (self.offset == self.data.len) return null;
        const end = self.offset + @min(self.segment_size, self.data.len - self.offset);
        const packet = self.data[self.offset..end];
        self.offset = end;
        return packet;
    }
};

/// Validates Linux control records and every segment before returning views.
pub fn decode(
    data: []const u8,
    control: []const u8,
    flags: c_int,
    bound_address: std.Io.net.IpAddress,
) ReceiveError!Batch {
    if (flags & message_truncated != 0) return error.TruncatedDatagram;
    if (flags & control_truncated != 0) return error.TruncatedControl;
    if (data.len == 0) return error.EmptyDatagram;
    if (data.len > aggregate_bytes) return error.DatagramTooLarge;

    var segment_size: ?usize = null;
    var destination: ?std.Io.net.IpAddress = null;
    var offset: usize = 0;
    while (offset < control.len) {
        const remaining = control.len - offset;
        if (remaining < control_header_size) return error.MalformedControl;
        const header = std.mem.bytesToValue(ControlHeader, control[offset..][0..@sizeOf(ControlHeader)]);
        if (header.length < control_header_size or header.length > remaining) return error.MalformedControl;
        const payload = control[offset + control_header_size .. offset + header.length];
        try decode_control(header, payload, bound_address, &segment_size, &destination);
        if (header.length == remaining) break;
        const aligned = std.math.add(usize, header.length, @alignOf(usize) - 1) catch return error.MalformedControl;
        const advance = aligned & ~@as(usize, @alignOf(usize) - 1);
        if (advance > remaining) return error.MalformedControl;
        offset += advance;
    }

    if (segment_size == null and data.len > max_datagram_bytes) return error.DatagramTooLarge;
    const size = segment_size orelse data.len;
    if (size == 0 or size > max_datagram_bytes or size > data.len) return error.InvalidSegmentSize;
    const count = std.math.divCeil(usize, data.len, size) catch return error.InvalidSegmentSize;
    if (count > max_segments) return error.TooManySegments;
    const local = destination orelse blk: {
        if (unspecified(bound_address)) return error.MissingDestination;
        break :blk bound_address;
    };
    return .{ .data = data, .local_address = local, .segment_size = size, .gro = segment_size != null };
}

fn decode_control(
    header: ControlHeader,
    payload: []const u8,
    bound: std.Io.net.IpAddress,
    segment_size: *?usize,
    destination: *?std.Io.net.IpAddress,
) ReceiveError!void {
    if (header.level == udp_level and header.kind == gro_type) {
        if (segment_size.* != null) return error.DuplicateControl;
        if (payload.len != @sizeOf(c_int)) return error.MalformedControl;
        // Linux udp_cmsg_recv emits sizeof(int), unlike transmit UDP_SEGMENT.
        const size = std.mem.readInt(i32, payload[0..4], @import("builtin").cpu.arch.endian());
        if (size <= 0 or size > max_datagram_bytes) return error.InvalidSegmentSize;
        segment_size.* = @intCast(size);
        return;
    }
    if (header.level == ip4_level and header.kind == ip4_packet_info) {
        if (destination.* != null) return error.DuplicateControl;
        if (payload.len != @sizeOf(PacketInfo4)) return error.MalformedControl;
        if (bound != .ip4) return error.InvalidDestination;
        const info = std.mem.bytesToValue(PacketInfo4, payload[0..@sizeOf(PacketInfo4)]);
        destination.* = .{ .ip4 = .{ .bytes = info.destination, .port = bound.ip4.port } };
        return;
    }
    if (header.level != ip6_level or header.kind != ip6_packet_info) return;
    if (destination.* != null) return error.DuplicateControl;
    if (payload.len != @sizeOf(PacketInfo6)) return error.MalformedControl;
    if (bound != .ip6) return error.InvalidDestination;
    const info = std.mem.bytesToValue(PacketInfo6, payload[0..@sizeOf(PacketInfo6)]);
    destination.* = .{ .ip6 = .{
        .bytes = info.destination,
        .port = bound.ip6.port,
        .flow = bound.ip6.flow,
        .interface = .{ .index = info.interface },
    } };
}

fn unspecified(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |value| std.mem.allEqual(u8, &value.bytes, 0),
        .ip6 => |value| std.mem.allEqual(u8, &value.bytes, 0),
    };
}
