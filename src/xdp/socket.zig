const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;

pub const af_xdp = 44;
pub const sol_xdp = 283;
pub const xdp_mmap_offsets = 1;
pub const xdp_rx_ring = 2;
pub const xdp_tx_ring = 3;
pub const xdp_umem_reg = 4;
pub const xdp_umem_fill_ring = 5;
pub const xdp_umem_completion_ring = 6;
pub const xdp_zerocopy = 1 << 2;
pub const xdp_use_need_wakeup = 1 << 3;

const xdp_pgoff_rx_ring: i64 = 0;
const xdp_pgoff_tx_ring: i64 = 0x80000000;
const xdp_umem_pgoff_fill_ring: i64 = 0x100000000;
const xdp_umem_pgoff_completion_ring: i64 = 0x180000000;

pub const Descriptor = extern struct {
    address: u64,
    length: u32,
    options: u32,
};

pub const RingOffset = extern struct {
    producer: u64,
    consumer: u64,
    descriptor: u64,
    flags: u64,
};

pub const MmapOffsets = extern struct {
    receive: RingOffset,
    transmit: RingOffset,
    fill: RingOffset,
    completion: RingOffset,
};

pub const UmemRegistration = extern struct {
    address: u64,
    length: u64,
    chunk_size: u32,
    headroom: u32,
    flags: u32,
};

pub const SocketAddress = extern struct {
    family: u16 = af_xdp,
    flags: u16,
    interface_index: u32,
    queue_id: u32,
    shared_umem_fd: u32 = 0,
};

pub const Error = error{
    AddressInUse,
    InvalidArgument,
    InvalidFileDescriptor,
    KernelSupportUnavailable,
    MappingFailed,
    PermissionDenied,
    RingEmpty,
    RingFull,
    SyscallFailed,
};

pub const Ring = struct {
    mapping: []align(std.heap.page_size_min) u8,
    producer: *u32,
    consumer: *u32,
    descriptors: [*]Descriptor,
    mask: u32,
    cached_consumer: u32 = 0,

    /// Returns one raw frame view directly into registered UMEM.
    pub fn receive(self: *Ring, umem: []u8) Error![]u8 {
        const producer = @atomicLoad(u32, self.producer, .acquire);
        if (self.cached_consumer == producer) return error.RingEmpty;
        const descriptor = self.descriptors[self.cached_consumer & self.mask];
        const start: usize = @intCast(descriptor.address);
        const length: usize = descriptor.length;
        if (start > umem.len or length > umem.len - start) return error.InvalidArgument;
        return umem[start .. start + length];
    }

    pub fn release(self: *Ring) void {
        self.cached_consumer +%= 1;
        @atomicStore(u32, self.consumer, self.cached_consumer, .release);
    }
};

pub const AddressRing = struct {
    mapping: []align(std.heap.page_size_min) u8,
    producer: *u32,
    consumer: *u32,
    addresses: [*]u64,
    mask: u32,
    cached_producer: u32,
    cached_consumer: u32,

    /// Publishes a UMEM frame to a kernel-consumed ring.
    pub fn submit(self: *AddressRing, address: u64) Error!void {
        const consumer = @atomicLoad(u32, self.consumer, .acquire);
        const capacity = self.mask + 1;
        if (self.cached_producer -% consumer >= capacity) return error.RingFull;
        self.addresses[self.cached_producer & self.mask] = address;
        self.cached_producer +%= 1;
        @atomicStore(u32, self.producer, self.cached_producer, .release);
    }

    /// Reclaims one address from a kernel-produced completion ring.
    pub fn consume(self: *AddressRing) Error!u64 {
        const producer = @atomicLoad(u32, self.producer, .acquire);
        if (self.cached_consumer == producer) return error.RingEmpty;
        const address = self.addresses[self.cached_consumer & self.mask];
        self.cached_consumer +%= 1;
        @atomicStore(u32, self.consumer, self.cached_consumer, .release);
        return address;
    }
};

pub const XskSocket = struct {
    fd: i32,
    umem: []u8,
    chunk_size: u32,
    offsets: MmapOffsets = undefined,
    receive_ring: ?Ring = null,
    fill_ring: ?AddressRing = null,
    completion_ring: ?AddressRing = null,

    pub fn init(umem: []u8, chunk_size: u32, headroom: u32) Error!XskSocket {
        require_linux();
        if (umem.len == 0 or chunk_size == 0 or umem.len % chunk_size != 0) {
            return error.InvalidArgument;
        }
        const socket_result = linux.socket(af_xdp, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0);
        try check_result(socket_result);
        const fd: i32 = @intCast(socket_result);
        errdefer _ = linux.close(fd);

        var registration = UmemRegistration{
            .address = @intFromPtr(umem.ptr),
            .length = umem.len,
            .chunk_size = chunk_size,
            .headroom = headroom,
            .flags = 0,
        };
        try set_option(fd, xdp_umem_reg, std.mem.asBytes(&registration));

        var offsets: MmapOffsets = undefined;
        var offsets_length: linux.socklen_t = @sizeOf(MmapOffsets);
        const offsets_result = linux.getsockopt(
            fd,
            sol_xdp,
            xdp_mmap_offsets,
            std.mem.asBytes(&offsets).ptr,
            &offsets_length,
        );
        try check_result(offsets_result);
        if (offsets_length < @sizeOf(MmapOffsets)) return error.KernelSupportUnavailable;
        return .{
            .fd = fd,
            .umem = umem,
            .chunk_size = chunk_size,
            .offsets = offsets,
        };
    }

    pub fn configure_rings(self: *XskSocket, entries: u32) Error!void {
        if (entries == 0 or !std.math.isPowerOfTwo(entries)) return error.InvalidArgument;
        try set_u32_option(self.fd, xdp_rx_ring, entries);
        try set_u32_option(self.fd, xdp_tx_ring, entries);
        try set_u32_option(self.fd, xdp_umem_fill_ring, entries);
        try set_u32_option(self.fd, xdp_umem_completion_ring, entries);

        self.receive_ring = try map_descriptor_ring(
            self.fd,
            self.offsets.receive,
            entries,
            xdp_pgoff_rx_ring,
        );
        errdefer self.unmap_rings();
        self.fill_ring = try map_address_ring(
            self.fd,
            self.offsets.fill,
            entries,
            xdp_umem_pgoff_fill_ring,
        );
        self.completion_ring = try map_address_ring(
            self.fd,
            self.offsets.completion,
            entries,
            xdp_umem_pgoff_completion_ring,
        );
    }

    /// Gives one aligned UMEM frame to the kernel RX path without copying.
    pub fn provide_frame(self: *XskSocket, address: u64) Error!void {
        if (address > std.math.maxInt(usize)) return error.InvalidArgument;
        const start: usize = @intCast(address);
        if (start % self.chunk_size != 0) return error.InvalidArgument;
        if (start > self.umem.len or self.chunk_size > self.umem.len - start) {
            return error.InvalidArgument;
        }
        if (self.fill_ring) |*ring| return ring.submit(address);
        return error.InvalidArgument;
    }

    /// Returns one transmitted UMEM frame address to caller ownership.
    pub fn reclaim_frame(self: *XskSocket) Error!u64 {
        if (self.completion_ring) |*ring| return ring.consume();
        return error.InvalidArgument;
    }

    pub fn bind(self: *XskSocket, interface_index: u32, queue_id: u32, zero_copy: bool) Error!void {
        var address = SocketAddress{
            .flags = xdp_use_need_wakeup | if (zero_copy) xdp_zerocopy else 0,
            .interface_index = interface_index,
            .queue_id = queue_id,
        };
        const result = linux.bind(
            self.fd,
            @ptrCast(&address),
            @sizeOf(SocketAddress),
        );
        try check_result(result);
    }

    pub fn deinit(self: *XskSocket) void {
        self.unmap_rings();
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    fn unmap_rings(self: *XskSocket) void {
        if (self.receive_ring) |ring| {
            _ = linux.munmap(ring.mapping.ptr, ring.mapping.len);
            self.receive_ring = null;
        }
        if (self.fill_ring) |ring| {
            _ = linux.munmap(ring.mapping.ptr, ring.mapping.len);
            self.fill_ring = null;
        }
        if (self.completion_ring) |ring| {
            _ = linux.munmap(ring.mapping.ptr, ring.mapping.len);
            self.completion_ring = null;
        }
    }
};

fn map_descriptor_ring(fd: i32, offsets: RingOffset, entries: u32, offset: i64) Error!Ring {
    const descriptor_bytes = std.math.mul(usize, entries, @sizeOf(Descriptor)) catch {
        return error.InvalidArgument;
    };
    const map_length = std.math.add(usize, @intCast(offsets.descriptor), descriptor_bytes) catch {
        return error.InvalidArgument;
    };
    const mapping = try map_ring(fd, map_length, offset);
    return .{
        .mapping = mapping,
        .producer = @ptrCast(@alignCast(mapping.ptr + offsets.producer)),
        .consumer = @ptrCast(@alignCast(mapping.ptr + offsets.consumer)),
        .descriptors = @ptrCast(@alignCast(mapping.ptr + offsets.descriptor)),
        .mask = entries - 1,
    };
}

fn map_address_ring(fd: i32, offsets: RingOffset, entries: u32, offset: i64) Error!AddressRing {
    const descriptor_bytes = std.math.mul(usize, entries, @sizeOf(u64)) catch {
        return error.InvalidArgument;
    };
    const map_length = std.math.add(usize, @intCast(offsets.descriptor), descriptor_bytes) catch {
        return error.InvalidArgument;
    };
    const mapping = try map_ring(fd, map_length, offset);
    const producer: *u32 = @ptrCast(@alignCast(mapping.ptr + offsets.producer));
    const consumer: *u32 = @ptrCast(@alignCast(mapping.ptr + offsets.consumer));
    return .{
        .mapping = mapping,
        .producer = producer,
        .consumer = consumer,
        .addresses = @ptrCast(@alignCast(mapping.ptr + offsets.descriptor)),
        .mask = entries - 1,
        .cached_producer = @atomicLoad(u32, producer, .monotonic),
        .cached_consumer = @atomicLoad(u32, consumer, .monotonic),
    };
}

fn map_ring(fd: i32, length: usize, offset: i64) Error![]align(std.heap.page_size_min) u8 {
    const result = linux.mmap(
        null,
        length,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        offset,
    );
    if (linux.errno(result) != .SUCCESS) return error.MappingFailed;
    const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(result);
    return pointer[0..length];
}

fn set_u32_option(fd: i32, option: u32, value: u32) Error!void {
    var local = value;
    return set_option(fd, option, std.mem.asBytes(&local));
}

fn set_option(fd: i32, option: u32, value: []const u8) Error!void {
    try check_result(linux.setsockopt(fd, sol_xdp, option, value.ptr, @intCast(value.len)));
}

fn check_result(result: usize) Error!void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .BADF => error.InvalidFileDescriptor,
        .INVAL => error.InvalidArgument,
        .ADDRINUSE => error.AddressInUse,
        .PERM, .ACCES => error.PermissionDenied,
        .AFNOSUPPORT, .PROTONOSUPPORT, .NOPROTOOPT => error.KernelSupportUnavailable,
        else => error.SyscallFailed,
    };
}

inline fn require_linux() void {
    if (builtin.os.tag != .linux) @compileError("AF_XDP is available only on Linux");
}
