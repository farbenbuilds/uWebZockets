const std = @import("std");
const sessions = @import("test_support").webtransport_session_index;
const Handle = @import("test_support").webtransport.SessionHandle;
const testing = std.testing;
const max_session_id: u64 = ((@as(u64, 1) << 62) - 1) & ~@as(u64, 3);

test "WebTransport session index scopes full IDs to connection generations" {
    var index = try sessions.Index.init(testing.allocator, 4);
    defer index.deinit(testing.allocator);
    const keys = [_]sessions.Key{
        .{ .connection = .{ .index = 0, .generation = 1 }, .session_id = max_session_id },
        .{ .connection = .{ .index = 1, .generation = 1 }, .session_id = max_session_id },
        .{ .connection = .{ .index = 0, .generation = 2 }, .session_id = max_session_id },
    };
    const handles = [_]Handle{
        .{ .index = 0, .generation = 3 },
        .{ .index = 1, .generation = 5 },
        .{ .index = 2, .generation = std.math.maxInt(u64) },
    };
    for (keys, handles) |key, handle| try index.insert(key, handle);
    try testing.expectEqual(@as(usize, 3), index.count());
    for (keys, handles) |key, handle| try testing.expectEqualDeep(handle, index.find(key).?);
    for (keys, handles) |key, handle| try testing.expect(index.remove(key, handle));
    try testing.expectEqual(@as(usize, 0), index.count());
}

test "WebTransport session index stale removal cannot erase a replacement" {
    var index = try sessions.Index.init(testing.allocator, 2);
    defer index.deinit(testing.allocator);
    const key = sessions.Key{ .connection = .{ .index = 4, .generation = 7 }, .session_id = 0 };
    const first = Handle{ .index = 0, .generation = 11 };
    const replacement = Handle{ .index = 0, .generation = 12 };
    try index.insert(key, first);
    try testing.expect(!index.remove(key, replacement));
    try testing.expectEqualDeep(first, index.find(key).?);
    try testing.expect(index.remove(key, first));
    try testing.expectEqual(@as(?Handle, null), index.find(key));
    try index.insert(key, replacement);
    try testing.expect(!index.remove(key, first));
    try testing.expectEqualDeep(replacement, index.find(key).?);
    try testing.expect(index.remove(key, replacement));
}

/// Invalid requests must preserve the two occupied mappings.
const InvalidInsert = struct { key: sessions.Key, handle: Handle };

test "WebTransport session index rejects invalid duplicate and full insertions atomically" {
    var index = try sessions.Index.init(testing.allocator, 2);
    defer index.deinit(testing.allocator);
    const first_key = sessions.Key{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 0 };
    const second_key = sessions.Key{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 4 };
    const first = Handle{ .index = 0, .generation = 1 };
    const second = Handle{ .index = 1, .generation = 2 };
    try index.insert(first_key, first);
    try index.insert(second_key, second);
    try testing.expectError(error.DuplicateSession, index.insert(first_key, second));
    const third_key = sessions.Key{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 8 };
    try testing.expectError(error.CapacityExceeded, index.insert(third_key, first));
    const invalid = [_]InvalidInsert{
        .{ .key = .{ .connection = .{ .index = 0, .generation = 0 }, .session_id = 8 }, .handle = first },
        .{ .key = .{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 2 }, .handle = first },
        .{ .key = .{ .connection = .{ .index = 0, .generation = 1 }, .session_id = @as(u64, 1) << 62 }, .handle = first },
        .{ .key = third_key, .handle = .{ .index = 0, .generation = 0 } },
        .{ .key = third_key, .handle = .{ .index = 2, .generation = 1 } },
    };
    for (invalid) |request| {
        try testing.expectError(error.InvalidIdentity, index.insert(request.key, request.handle));
        try testing.expectEqualDeep(first, index.find(first_key).?);
        try testing.expectEqualDeep(second, index.find(second_key).?);
        try testing.expectEqual(@as(usize, 2), index.count());
    }
    try testing.expectEqual(@as(?Handle, null), index.find(third_key));
    try testing.expect(index.remove(first_key, first));
    try testing.expect(index.remove(second_key, second));
}

/// Cleanup must still retire all entries when a churn assertion fails.
fn drain_index(index: *sessions.Index) void {
    while (index.count() != 0) {
        var entries = index.map.iterator();
        const entry = entries.next().?;
        const key = entry.key_ptr.*;
        const handle = entry.value_ptr.*;
        if (!index.remove(key, handle)) @panic("session index cleanup lost its mapping");
    }
}

test "WebTransport session index churn retains empty lookup slots without allocation" {
    var storage: [4096]u8 = undefined;
    var buffer = std.heap.FixedBufferAllocator.init(&storage);
    var allocator = std.testing.FailingAllocator.init(buffer.allocator(), .{});
    const limit = 12;
    var index = try sessions.Index.init(allocator.allocator(), limit);
    defer index.deinit(allocator.allocator());
    defer drain_index(&index);
    const allocated = allocator.allocated_bytes;
    const allocation_count = allocator.allocations;
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    var keys: [limit]sessions.Key = undefined;
    var handles: [limit]Handle = undefined;
    for (0..limit) |slot| {
        keys[slot] = .{ .connection = .{ .index = slot, .generation = 1 }, .session_id = @as(u64, @intCast(slot)) * 4 };
        handles[slot] = .{ .index = slot, .generation = 1 };
        try index.insert(keys[slot], handles[slot]);
    }
    for (0..1024) |round| {
        const slot = round % keys.len;
        const previous = handles[slot];
        try testing.expect(index.remove(keys[slot], previous));
        keys[slot].session_id = (@as(u64, @intCast(round)) + limit) * 4;
        handles[slot].generation += 1;
        try index.insert(keys[slot], handles[slot]);
        try testing.expect(!index.remove(keys[slot], previous));
        try testing.expectEqualDeep(handles[slot], index.find(keys[slot]).?);
        var empty_slots: usize = 0;
        for (index.map.metadata.?[0..index.map.capacity()]) |metadata| {
            if (metadata.isFree()) empty_slots += 1;
        }
        try testing.expect(empty_slots >= (index.map.capacity() - limit) / 2);
    }
    try testing.expectEqual(@as(usize, limit), index.count());
    try testing.expectEqual(allocated, allocator.allocated_bytes);
    try testing.expectEqual(allocation_count, allocator.allocations);
    try testing.expect(!allocator.has_induced_failure);
    for (keys, handles) |key, handle| try testing.expect(index.remove(key, handle));
}

test "WebTransport session index validates geometry before allocation" {
    var allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    for ([_]usize{ 0, std.math.maxInt(u32), std.math.maxInt(usize) }) |limit| {
        try testing.expectError(error.InvalidCapacity, sessions.Index.init(allocator.allocator(), limit));
    }
    try testing.expectEqual(@as(usize, 0), allocator.allocations);
    try testing.expect(!allocator.has_induced_failure);
    try testing.expectError(error.OutOfMemory, sessions.Index.init(allocator.allocator(), 8));
    try testing.expect(allocator.has_induced_failure);
    try testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

fn initialize_index(allocator: std.mem.Allocator) !void {
    var index = try sessions.Index.init(allocator, 8);
    defer index.deinit(allocator);
}

test "WebTransport session index startup allocation failures do not leak" {
    try testing.checkAllAllocationFailures(testing.allocator, initialize_index, .{});
}
