//! Linux ancillary ABI shared by receive validation and source-aware sends.

const std = @import("std");

/// Linux cmsghdr ABI, including its native size_t length.
pub const Header = extern struct {
    length: usize,
    level: i32,
    kind: i32,
};

/// Aligned offset of a Linux ancillary payload.
pub const header_size = std.mem.alignForward(usize, @sizeOf(Header), @alignOf(usize));

/// Linux IP_PKTINFO ABI; address bytes retain network order.
pub const PacketInfo4 = extern struct {
    interface: i32,
    specific_destination: [4]u8,
    destination: [4]u8,
};

/// Linux IPV6_PKTINFO ABI; interface identifies the IPv6 scope.
pub const PacketInfo6 = extern struct {
    destination: [16]u8,
    interface: u32,
};

/// Appends one aligned control record within fixed caller-owned storage.
pub fn append(storage: []u8, offset: usize, level: i32, kind: i32, payload: []const u8) error{BufferTooSmall}!usize {
    if (offset > storage.len or offset % @alignOf(usize) != 0) return error.BufferTooSmall;
    const length = std.math.add(usize, header_size, payload.len) catch return error.BufferTooSmall;
    const padded = std.math.add(usize, length, @alignOf(usize) - 1) catch return error.BufferTooSmall;
    const aligned = padded & ~@as(usize, @alignOf(usize) - 1);
    if (aligned > storage.len - offset) return error.BufferTooSmall;
    const header = Header{ .length = length, .level = level, .kind = kind };
    @memcpy(storage[offset..][0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(storage[offset + header_size ..][0..payload.len], payload);
    @memset(storage[offset + length .. offset + aligned], 0);
    return offset + aligned;
}
