const std = @import("std");
const receive = @import("test_support").udp.receive;

test "fuzz: UDP ancillary decoding preserves datagram bounds" {
    try std.testing.fuzz({}, fuzz_receive, .{ .corpus = &.{ "", "ordinary", "\x00" ** 32, "\xff" ** 64 } });
}

fn fuzz_receive(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var control: [512]u8 = undefined;
    const length: usize = @intCast(smith.sliceWeightedBytes(&control, &.{
        .rangeAtMost(u8, 0, 255, 4),
        .value(u8, 0, 8),
        .value(u8, 17, 2),
        .value(u8, 104, 2),
    }));
    var control_length = length;
    if (smith.index(2) == 0) {
        const header = receive.ControlHeader{
            .length = receive.control_header_size + @sizeOf(c_int),
            .level = receive.udp_level,
            .kind = receive.gro_type,
        };
        @memcpy(control[0..@sizeOf(receive.ControlHeader)], std.mem.asBytes(&header));
        const size: i32 = @intCast(smith.index(receive.max_datagram_bytes + 2));
        std.mem.writeInt(i32, control[receive.control_header_size..][0..4], size, @import("builtin").cpu.arch.endian());
        control_length = header.length;
    }
    const data: [4096]u8 = @splat(0x5a);
    const data_length = smith.index(data.len + 1);
    const flags: c_int = @intCast(smith.index(64));
    const bound = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 443 } };
    var batch = receive.decode(data[0..data_length], control[0..control_length], flags, bound) catch return;
    var offset: usize = 0;
    var count: usize = 0;
    while (batch.next()) |packet| {
        try std.testing.expect(packet.len != 0 and packet.len <= receive.max_datagram_bytes);
        try std.testing.expectEqual(@intFromPtr(data[offset..].ptr), @intFromPtr(packet.ptr));
        offset += packet.len;
        count += 1;
        try std.testing.expect(count <= receive.max_segments);
    }
    try std.testing.expectEqual(data_length, offset);
    try std.testing.expect(batch.next() == null);
}
