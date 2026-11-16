const std = @import("std");
const support = @import("test_support");
const pending = support.webtransport_pending_datagrams;
const Storage = support.webtransport_runtime.PendingDatagramStorage;

const policy = pending.Policy{
    .payload_stride = 2048,
    .per_connection_limit = 4,
    .lifetime_us = 1_000_000,
};

test "WebTransport pending allocation failures release every earlier slab" {
    for (0..3) |failure_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        try std.testing.expectError(error.OutOfMemory, Storage.init(failing.allocator(), 4, policy));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "WebTransport pending startup geometry and successful ownership" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(error.StorageOverflow, Storage.init(tracking.allocator(), std.math.maxInt(usize), policy));
    try std.testing.expectEqual(@as(usize, 0), tracking.allocated_bytes);
    var storage = try Storage.init(tracking.allocator(), 4, policy);
    try std.testing.expectEqual(@as(usize, 4), storage.store.storage.entries.len);
    try std.testing.expectEqual(@as(usize, 4), storage.store.storage.terminals.len);
    try std.testing.expectEqual(@as(usize, 8192), storage.store.storage.payloads.len);
    storage.deinit(tracking.allocator());
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}
