const std = @import("std");
const receive = @import("test_support").udp.receive;

const native_endian = @import("builtin").cpu.arch.endian();

fn gro_control(storage: []u8, size: i32) []const u8 {
    const length = receive.control_header_size + @sizeOf(i32);
    @memset(storage, 0);
    const header = receive.ControlHeader{ .length = length, .level = receive.udp_level, .kind = receive.gro_type };
    @memcpy(storage[0..@sizeOf(receive.ControlHeader)], std.mem.asBytes(&header));
    std.mem.writeInt(i32, storage[receive.control_header_size..][0..4], size, native_endian);
    return storage[0..length];
}

fn append_control(storage: []u8, offset: usize, level: i32, kind: i32, payload: []const u8) usize {
    const length = receive.control_header_size + payload.len;
    const header = receive.ControlHeader{ .length = length, .level = level, .kind = kind };
    @memcpy(storage[offset..][0..@sizeOf(receive.ControlHeader)], std.mem.asBytes(&header));
    @memcpy(storage[offset + receive.control_header_size ..][0..payload.len], payload);
    const end = offset + std.mem.alignForward(usize, length, @alignOf(usize));
    @memset(storage[offset + length .. end], 0);
    return end;
}

test "udp receive: GRO native integer splits a shorter final segment" {
    var control: [64]u8 = undefined;
    var batch = try receive.decode("aaaabbbbcc", gro_control(&control, 4), 0, .{ .ip4 = .loopback(8443) });
    try std.testing.expect(batch.gro);
    try std.testing.expectEqualStrings("aaaa", batch.next().?);
    try std.testing.expectEqualStrings("bbbb", batch.next().?);
    try std.testing.expectEqualStrings("cc", batch.next().?);
    try std.testing.expect(batch.next() == null);
}

test "udp receive: absent GRO never invents datagram boundaries" {
    var batch = try receive.decode("abcdefgh", &.{}, 0, .{ .ip4 = .loopback(8443) });
    try std.testing.expect(!batch.gro);
    try std.testing.expectEqualStrings("abcdefgh", batch.next().?);
    try std.testing.expect(batch.next() == null);
    var oversized: [receive.max_datagram_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.DatagramTooLarge, receive.decode(&oversized, &.{}, 0, .{ .ip4 = .loopback(8443) }));
}

test "udp receive: truncated and malformed aggregates fail before dispatch" {
    var control: [64]u8 = undefined;
    const local: std.Io.net.IpAddress = .{ .ip4 = .loopback(8443) };
    try std.testing.expectError(error.TruncatedDatagram, receive.decode("data", &.{}, receive.message_truncated, local));
    try std.testing.expectError(error.TruncatedControl, receive.decode("data", &.{}, receive.control_truncated, local));
    try std.testing.expectError(error.MalformedControl, receive.decode("data", &.{1}, 0, local));
    for ([_]i32{ 0, -1, receive.max_datagram_bytes + 1 }) |size| {
        try std.testing.expectError(error.InvalidSegmentSize, receive.decode("data", gro_control(&control, size), 0, local));
    }
    var oversized: [receive.max_segments + 1]u8 = undefined;
    try std.testing.expectError(error.TooManySegments, receive.decode(&oversized, gro_control(&control, 1), 0, local));
}

test "udp receive: Linux ancillary records allow unknown controls and unaligned input" {
    var storage: [129]u8 = undefined;
    const control = storage[1..];
    var end = append_control(control, 0, 999, 1, "unknown");
    var size: [4]u8 = undefined;
    std.mem.writeInt(i32, &size, 4, native_endian);
    end = append_control(control, end, receive.udp_level, receive.gro_type, &size);
    var batch = try receive.decode("aaaabb", control[0..end], 0, .{ .ip4 = .loopback(8443) });
    try std.testing.expectEqualStrings("aaaa", batch.next().?);
    try std.testing.expectEqualStrings("bb", batch.next().?);
}

test "udp receive: malformed lengths duplicate GRO and transmit-width metadata fail closed" {
    var control: [128]u8 = undefined;
    const local: std.Io.net.IpAddress = .{ .ip4 = .loopback(8443) };
    var size: [4]u8 = undefined;
    std.mem.writeInt(i32, &size, 4, native_endian);
    var end = append_control(&control, 0, receive.udp_level, receive.gro_type, &size);
    end = append_control(&control, end, receive.udp_level, receive.gro_type, &size);
    try std.testing.expectError(error.DuplicateControl, receive.decode("aaaabbbb", control[0..end], 0, local));
    end = append_control(&control, 0, receive.udp_level, receive.gro_type, size[0..2]);
    try std.testing.expectError(error.MalformedControl, receive.decode("aaaabbbb", control[0..end], 0, local));
    for ([_]usize{ 0, receive.control_header_size - 1, control.len + 1, std.math.maxInt(usize) }) |length| {
        const header = receive.ControlHeader{ .length = length, .level = 999, .kind = 1 };
        @memcpy(control[0..@sizeOf(receive.ControlHeader)], std.mem.asBytes(&header));
        try std.testing.expectError(error.MalformedControl, receive.decode("data", &control, 0, local));
    }
}

test "udp receive: exact segment and aggregate bounds are enforced" {
    var control: [64]u8 = undefined;
    var data: [receive.aggregate_bytes + 1]u8 = undefined;
    const local: std.Io.net.IpAddress = .{ .ip4 = .loopback(8443) };
    var batch = try receive.decode(data[0..receive.aggregate_bytes], gro_control(&control, receive.max_datagram_bytes), 0, local);
    var count: usize = 0;
    while (batch.next()) |packet| {
        try std.testing.expectEqual(receive.max_datagram_bytes, packet.len);
        count += 1;
    }
    try std.testing.expectEqual(receive.max_segments, count);
    try std.testing.expectError(error.DatagramTooLarge, receive.decode(&data, gro_control(&control, receive.max_datagram_bytes), 0, local));
    try std.testing.expectError(error.EmptyDatagram, receive.decode(&.{}, &.{}, 0, local));
}

test "udp receive: IPv4 packet info retains wildcard destination and port" {
    var control: [128]u8 = undefined;
    const info = receive.PacketInfo4{ .interface = 1, .specific_destination = .{ 127, 0, 0, 1 }, .destination = .{ 127, 0, 0, 2 } };
    const end = append_control(&control, 0, receive.ip4_level, receive.ip4_packet_info, std.mem.asBytes(&info));
    const batch = try receive.decode("data", control[0..end], 0, .{ .ip4 = .unspecified(8443) });
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 2 }, &batch.local_address.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 8443), batch.local_address.ip4.port);
    try std.testing.expectError(error.MissingDestination, receive.decode("data", &.{}, 0, .{ .ip4 = .unspecified(8443) }));
}

test "udp receive: IPv6 packet info retains scope flow and family" {
    var control: [128]u8 = undefined;
    var bound: std.Io.net.IpAddress = .{ .ip6 = .unspecified(8443) };
    bound.ip6.flow = 42;
    const info = receive.PacketInfo6{ .interface = 7, .destination = std.Io.net.Ip6Address.loopback(0).bytes };
    const end = append_control(&control, 0, receive.ip6_level, receive.ip6_packet_info, std.mem.asBytes(&info));
    const batch = try receive.decode("data", control[0..end], 0, bound);
    try std.testing.expectEqualSlices(u8, &info.destination, &batch.local_address.ip6.bytes);
    try std.testing.expectEqual(@as(u16, 8443), batch.local_address.ip6.port);
    try std.testing.expectEqual(@as(u32, 7), batch.local_address.ip6.interface.index);
    try std.testing.expectEqual(@as(u32, 42), batch.local_address.ip6.flow);
    try std.testing.expectError(error.InvalidDestination, receive.decode("data", control[0..end], 0, .{ .ip4 = .loopback(8443) }));
}

test "udp receive: duplicate and shortened packet info is rejected" {
    var control: [128]u8 = undefined;
    const local: std.Io.net.IpAddress = .{ .ip4 = .loopback(8443) };
    const info = receive.PacketInfo4{ .interface = 1, .specific_destination = .{ 127, 0, 0, 1 }, .destination = .{ 127, 0, 0, 2 } };
    var end = append_control(&control, 0, receive.ip4_level, receive.ip4_packet_info, std.mem.asBytes(&info));
    end = append_control(&control, end, receive.ip4_level, receive.ip4_packet_info, std.mem.asBytes(&info));
    try std.testing.expectError(error.DuplicateControl, receive.decode("data", control[0..end], 0, local));
    end = append_control(&control, 0, receive.ip4_level, receive.ip4_packet_info, std.mem.asBytes(&info)[0..4]);
    try std.testing.expectError(error.MalformedControl, receive.decode("data", control[0..end], 0, local));
}
