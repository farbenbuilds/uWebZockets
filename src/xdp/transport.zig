const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;
const socket = @import("socket.zig");

/// Upper bound on UMEM frames one transport tracks. The free stack lives in
/// the transport so no caller-owned descriptor region layout is assumed.
pub const max_frames = 4096;

/// Selected data path: AF_XDP kernel bypass or the standard socket path.
pub const Mode = enum {
    standard,
    kernel_bypass,
};

/// Why kernel bypass is not active.
pub const FallbackReason = enum {
    none,
    unsupported_platform,
    kernel_unavailable,
    permission_denied,
    invalid_configuration,
};

/// Result of an AF_XDP availability probe.
pub const Availability = struct {
    mode: Mode,
    reason: FallbackReason,
};

/// UMEM and ring sizing for one transport instance.
pub const XdpConfig = struct {
    chunk_size: u32 = 2048,
    frame_count: u32 = 1024,
    zero_copy: bool = false,
    interface_index: u32 = 0,
    queue_id: u32 = 0,
};

pub const Error = socket.Error || error{
    InvalidConfiguration,
    NoFrames,
    PayloadTooLarge,
};

/// Returns .standard where AF_XDP cannot exist, otherwise the requested mode.
pub fn resolve_mode(comptime requested: Mode) Mode {
    if (builtin.os.tag != .linux) return .standard;
    return requested;
}

/// Probes AF_XDP socket creation and releases the probe descriptor. Never
/// fails and never panics so startup can always fall back to .standard.
pub fn probe() Availability {
    if (builtin.os.tag != .linux) {
        return .{ .mode = .standard, .reason = .unsupported_platform };
    }
    return probe_linux();
}

fn probe_linux() Availability {
    const result = linux.socket(socket.af_xdp, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => blk: {
            _ = linux.close(@intCast(result));
            break :blk .{ .mode = .kernel_bypass, .reason = .none };
        },
        .PERM, .ACCES => .{ .mode = .standard, .reason = .permission_denied },
        .AFNOSUPPORT, .PROTONOSUPPORT, .NOPROTOOPT => .{
            .mode = .standard,
            .reason = .kernel_unavailable,
        },
        else => .{ .mode = .standard, .reason = .kernel_unavailable },
    };
}

/// Validates a UMEM region and returns its frame count.
pub fn validate_umem(umem: []align(std.heap.page_size_min) u8, chunk_size: u32) Error!u32 {
    if (chunk_size == 0) return error.InvalidConfiguration;
    if (!std.math.isPowerOfTwo(chunk_size)) return error.InvalidConfiguration;
    if (umem.len == 0 or umem.len % chunk_size != 0) return error.InvalidConfiguration;
    if (@intFromPtr(umem.ptr) % std.heap.page_size_min != 0) return error.InvalidConfiguration;
    if (umem.len % std.heap.page_size_min != 0) return error.InvalidConfiguration;
    const frames = umem.len / chunk_size;
    if (frames == 0 or frames > std.math.maxInt(u32)) return error.InvalidConfiguration;
    return @intCast(frames);
}

/// Maps a frame index to its UMEM byte offset. Chunk and index are bounded at
/// validation time, so the u64 product cannot overflow.
pub fn frame_address(index: u32, chunk_size: u32) u64 {
    return @as(u64, index) * @as(u64, chunk_size);
}

/// Maps a UMEM byte offset back to its frame index with alignment checks.
pub fn frame_index(address: u64, chunk_size: u32) Error!u32 {
    if (chunk_size == 0) return error.InvalidConfiguration;
    if (address % chunk_size != 0) return error.InvalidArgument;
    const index = address / chunk_size;
    if (index > std.math.maxInt(u32)) return error.InvalidArgument;
    return @intCast(index);
}

/// Owns one AF_XDP socket plus its UMEM and a fixed free-frame stack. No
/// method allocates; a frame is recycled only after the completion ring
/// reports the kernel finished with it.
pub const XdpTransport = struct {
    socket: socket.XskSocket,
    umem: []align(std.heap.page_size_min) u8,
    free_stack: [max_frames]u32 = undefined,
    free_top: u32 = 0,
    config: XdpConfig = .{},
    availability: Availability = .{ .mode = .standard, .reason = .none },

    pub fn init(umem: []align(std.heap.page_size_min) u8, config: XdpConfig) Error!XdpTransport {
        const available_frames = try validate_umem(umem, config.chunk_size);
        if (config.frame_count == 0 or !std.math.isPowerOfTwo(config.frame_count)) {
            return error.InvalidConfiguration;
        }
        if (config.frame_count > available_frames or config.frame_count > max_frames) {
            return error.InvalidConfiguration;
        }

        // AF_XDP exists only on Linux. Keep the socket setup inside a comptime
        // branch so non-Linux targets reject the request without analyzing the
        // Linux syscall path (which carries a compile error by design).
        if (builtin.os.tag == .linux) {
            var transport = XdpTransport{
                .socket = try socket.XskSocket.init(umem, config.chunk_size, 0),
                .umem = umem,
                .config = config,
                .availability = .{ .mode = .kernel_bypass, .reason = .none },
            };
            errdefer transport.socket.deinit();
            try transport.socket.configure_rings(config.frame_count);
            transport.fill_free_stack(config.frame_count);
            return transport;
        }
        return error.KernelSupportUnavailable;
    }

    pub fn deinit(self: *XdpTransport) void {
        self.socket.deinit();
        self.* = undefined;
    }

    pub fn bind(self: *XdpTransport, config: XdpConfig) Error!void {
        if (config.chunk_size != self.config.chunk_size or
            config.frame_count != self.config.frame_count)
        {
            return error.InvalidConfiguration;
        }
        try self.socket.bind(config.interface_index, config.queue_id, config.zero_copy);
        self.config = config;
    }

    /// Returns one received frame without advancing the RX consumer.
    pub fn receive(self: *XdpTransport) Error!?[]u8 {
        return self.socket.receive_frame();
    }

    /// The frame slice returned by receive() is invalid after this call.
    pub fn release(self: *XdpTransport) void {
        self.socket.release_frame();
    }

    /// Copies payload into a free UMEM frame and queues it for transmission.
    /// The frame returns to the free stack only after reclaim() observes its
    /// completion, so the kernel cannot still read recycled storage.
    pub fn transmit(self: *XdpTransport, payload: []const u8) Error!void {
        if (self.free_top == 0) return error.NoFrames;
        if (payload.len > self.config.chunk_size) return error.PayloadTooLarge;
        const index = self.free_stack[self.free_top - 1];
        self.free_top -= 1;
        errdefer self.push_frame(index);
        const address = frame_address(index, self.config.chunk_size);
        const start: usize = @intCast(address);
        @memcpy(self.umem[start .. start + payload.len], payload);
        try self.socket.transmit_frame(address, @intCast(payload.len));
    }

    /// Returns every completed TX frame to the free stack.
    pub fn reclaim(self: *XdpTransport) Error!void {
        while (true) {
            const maybe_address = try self.socket.reclaim_tx();
            const address = maybe_address orelse return;
            const index = try frame_index(address, self.config.chunk_size);
            if (index >= self.config.frame_count) return error.InvalidArgument;
            self.push_frame(index);
        }
    }

    pub fn status(self: *const XdpTransport) Availability {
        return self.availability;
    }

    pub fn frame_count(self: *const XdpTransport) u32 {
        return self.config.frame_count;
    }

    fn fill_free_stack(self: *XdpTransport, count: u32) void {
        var index: u32 = 0;
        while (index < count) : (index += 1) self.free_stack[index] = index;
        self.free_top = count;
    }

    fn push_frame(self: *XdpTransport, index: u32) void {
        std.debug.assert(self.free_top < max_frames);
        self.free_stack[self.free_top] = index;
        self.free_top += 1;
    }
};
