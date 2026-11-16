const std = @import("std");
const support = @import("test_support");
const pending = support.webtransport_pending_datagrams;
const Storage = support.webtransport_runtime.PendingDatagramStorage;

const policy = pending.Policy{
    .payload_stride = 2048,
    .per_connection_limit = 4,
    .lifetime_us = 1_000_000,
};

test "WebTransport stream-only storage owns terminals without payload allocations" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var storage = try Storage.init_terminal_only(tracking.allocator(), 4);
    try std.testing.expectEqual(@as(usize, 0), storage.store.storage.entries.len);
    try std.testing.expectEqual(@as(usize, 0), storage.store.storage.payloads.len);
    try std.testing.expectEqual(@as(usize, 4), storage.store.storage.terminals.len);
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(pending.Terminal)), tracking.allocated_bytes);
    const key = pending.SessionKey{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 0 };
    try std.testing.expectError(error.Full, storage.store.enqueue(key, "", 0));
    try std.testing.expectEqual(pending.RetireResult.remembered, storage.store.retire(key));
    try std.testing.expect(storage.store.is_retired(key));
    try std.testing.expectError(error.RetiredSession, storage.store.enqueue(key, "", 0));
    for (1..4) |index| {
        var other = key;
        other.session_id = index * 4;
        try std.testing.expectEqual(pending.RetireResult.remembered, storage.store.retire(other));
    }
    var exhausted = key;
    exhausted.session_id = 16;
    try std.testing.expectEqual(pending.RetireResult.exhausted, storage.store.retire(exhausted));
    var reused = key;
    reused.connection.generation += 1;
    try std.testing.expect(!storage.store.is_retired(reused));
    storage.store.clear_connection(key.connection);
    storage.deinit(tracking.allocator());
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}

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
