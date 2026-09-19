const builtin = @import("builtin");
const std = @import("std");

const support = @import("test_support");
const ebpf = support.ebpf;
const transport = support.xdp_transport;
const xdp = support.xdp;

test "kernel: resolve_mode falls back to standard off Linux" {
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(transport.Mode.kernel_bypass, transport.resolve_mode(.kernel_bypass));
        try std.testing.expectEqual(transport.Mode.standard, transport.resolve_mode(.standard));
        return;
    }
    try std.testing.expectEqual(transport.Mode.standard, transport.resolve_mode(.kernel_bypass));
    try std.testing.expectEqual(transport.Mode.standard, transport.resolve_mode(.standard));
}

test "kernel: validate_umem accepts page-aligned power-of-two regions" {
    const umem = try std.heap.page_allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        6 * 4096,
    );
    defer std.heap.page_allocator.free(umem);

    try std.testing.expectEqual(@as(u32, 12), try transport.validate_umem(umem, 2048));
    try std.testing.expectEqual(@as(u32, 6), try transport.validate_umem(umem, 4096));
    try std.testing.expectError(error.InvalidConfiguration, transport.validate_umem(umem, 0));
    try std.testing.expectError(error.InvalidConfiguration, transport.validate_umem(umem, 3000));
}

test "kernel: frame addresses round trip with alignment checks" {
    try std.testing.expectEqual(@as(u64, 0), transport.frame_address(0, 2048));
    try std.testing.expectEqual(@as(u64, 6 * 4096), transport.frame_address(6, 4096));
    try std.testing.expectEqual(@as(u32, 6), try transport.frame_index(6 * 4096, 4096));
    try std.testing.expectError(error.InvalidConfiguration, transport.frame_index(4096, 0));
    try std.testing.expectError(error.InvalidArgument, transport.frame_index(4097, 4096));
    const overflow = (@as(u64, std.math.maxInt(u32)) + 1) * 4096;
    try std.testing.expectError(error.InvalidArgument, transport.frame_index(overflow, 4096));
}

test "kernel: probe always reports a coherent availability" {
    const availability = transport.probe();
    switch (availability.mode) {
        .standard => try std.testing.expect(availability.reason != .none),
        .kernel_bypass => try std.testing.expectEqual(
            transport.FallbackReason.none,
            availability.reason,
        ),
    }
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqual(
            transport.FallbackReason.unsupported_platform,
            availability.reason,
        );
    }
}

test "kernel: descriptor rings produce bounded frames" {
    var producer: u32 = 0;
    var consumer: u32 = 0;
    var descriptors: [2]xdp.Descriptor = undefined;
    var page: [std.heap.page_size_min]u8 align(std.heap.page_size_min) = undefined;
    var ring = xdp.Ring{
        .mapping = &page,
        .producer = &producer,
        .consumer = &consumer,
        .descriptors = &descriptors,
        .mask = 1,
    };

    try ring.produce(0, 1);
    try ring.produce(2048, 2);
    try std.testing.expectError(error.RingFull, ring.produce(4096, 3));
    try std.testing.expectEqual(@as(u32, 2), producer);
    try std.testing.expectEqual(@as(u32, 2), ring.pending());
    try std.testing.expectEqual(@as(u64, 0), descriptors[0].address);
    try std.testing.expectEqual(@as(u32, 1), descriptors[0].length);
    try std.testing.expectEqual(@as(u64, 2048), descriptors[1].address);

    ring.release();
    try std.testing.expectEqual(@as(u32, 1), consumer);
    try std.testing.expectEqual(@as(u32, 1), ring.pending());
}

test "kernel: XskSocket frame helpers fail bounded without rings" {
    var page: [std.heap.page_size_min]u8 align(std.heap.page_size_min) = undefined;
    var socket = xdp.XskSocket{
        .fd = -1,
        .umem = &page,
        .chunk_size = 2048,
    };

    try std.testing.expectEqual(@as(?[]u8, null), try socket.receive_frame());
    socket.release_frame();
    try std.testing.expectEqual(@as(?u64, null), try socket.reclaim_tx());
    try std.testing.expectError(error.InvalidArgument, socket.transmit_frame(1, 8));
    try std.testing.expectError(error.InvalidArgument, socket.transmit_frame(4096, 8));
    try std.testing.expectError(error.InvalidArgument, socket.transmit_frame(0, 4096));
}

test "kernel: ebpf availability matches the platform" {
    try std.testing.expectEqual(builtin.os.tag == .linux, ebpf.available());
}

test "kernel: ebpf histogram defaults to unobserved zeros" {
    const histogram = ebpf.Histogram{};
    try std.testing.expect(!histogram.observed);
    try std.testing.expectEqual(@as(u64, 0), histogram.total);
    for (histogram.buckets) |bucket| try std.testing.expectEqual(@as(u64, 0), bucket);
}

test "kernel: ebpf map reads fail closed without a descriptor" {
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(error.Unsupported, ebpf.read_latency_histogram(-1));
        try std.testing.expectError(error.Unsupported, ebpf.open_pinned("/sys/fs/bpf/uwz_latency"));
        return;
    }
    if (ebpf.read_latency_histogram(-1)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.InvalidArgument or err == error.Unsupported);
    }
    try std.testing.expectError(error.NotFound, ebpf.open_pinned("/nonexistent/uwz_latency_map"));
    ebpf.close(-1);
}
