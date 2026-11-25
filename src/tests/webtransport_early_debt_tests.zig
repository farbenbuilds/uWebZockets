const std = @import("std");
const testing = std.testing;
const early = @import("test_support").webtransport_early_debt;
const flow = @import("test_support").webtransport_session_flow;
const max_data: u64 = (1 << 62) - 1;
const max_streams: u64 = 1 << 60;

test "WebTransport early debt validates slab geometry before mutation" {
    var entries = [_]early.Entry{.{}} ** 4;
    entries[0].key.session_id = 12;
    const before = entries;
    try testing.expectError(error.InvalidConnectionLimit, early.Store.init(&entries, 0));
    try testing.expectError(error.InvalidCapacity, early.Store.init(entries[0..3], 2));
    try testing.expectError(error.InvalidCapacity, early.Store.init(&.{}, 2));
    try testing.expectError(error.InvalidCapacity, early.Store.init(&entries, 5));
    try testing.expectEqualDeep(before, entries);
}

test "WebTransport early debt scopes full IDs by connection index and generation" {
    var entries: [8]early.Entry = undefined;
    var store = try early.Store.init(&entries, 4);
    const keys = [_]early.SessionKey{
        .{ .connection = .{ .index = 0, .generation = 1 }, .session_id = max_data & ~@as(u64, 3) },
        .{ .connection = .{ .index = 1, .generation = 1 }, .session_id = max_data & ~@as(u64, 3) },
        .{ .connection = .{ .index = 0, .generation = 2 }, .session_id = max_data & ~@as(u64, 3) },
        .{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 0xffff_fffc },
    };
    for (keys, 1..) |key, bytes| try store.add(key, .{ .used = .{ .data = bytes } });
    for (keys, 1..) |key, bytes| try testing.expectEqual(@as(u64, bytes), store.find(key).?.used.data);
    store.clear_connection(keys[0].connection);
    try testing.expectEqual(@as(?early.Debt, null), store.find(keys[0]));
    try testing.expectEqual(@as(?early.Debt, null), store.find(keys[3]));
    try testing.expectEqual(@as(u64, 2), store.find(keys[1]).?.used.data);
    try testing.expectEqual(@as(u64, 3), store.find(keys[2]).?.used.data);
    try testing.expectEqual(@as(usize, 2), store.active_count);
}

test "WebTransport early debt partitions capacity and updates a full key" {
    var entries: [4]early.Entry = undefined;
    var store = try early.Store.init(&entries, 2);
    const first = early.SessionKey{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 0 };
    const second = early.SessionKey{ .connection = first.connection, .session_id = 4 };
    const third = early.SessionKey{ .connection = first.connection, .session_id = 8 };
    try store.add(first, .{ .used = .{ .data = 5, .streams_bidi = 1 } });
    try store.add(second, .{ .used = .{ .data = 2 } });
    const before = entries;
    try testing.expectError(error.CapacityExceeded, store.add(third, .{ .used = .{ .data = 1 } }));
    try testing.expectEqualDeep(before, entries);
    try store.add(first, .{ .used = .{ .data = 3, .streams_uni = 1 }, .reclaimed = .{ .data = 5 } });
    try testing.expectEqualDeep(early.Debt{ .used = .{ .data = 8, .streams_bidi = 1, .streams_uni = 1 }, .reclaimed = .{ .data = 5 } }, store.find(first).?);
    const other = early.SessionKey{ .connection = .{ .index = 1, .generation = 1 }, .session_id = 0 };
    try store.add(other, .{ .used = .{ .data = 9 } });
    try testing.expectEqual(@as(usize, 3), store.active_count);
}

test "WebTransport early debt invalid identities preserve storage and counts" {
    var entries: [2]early.Entry = undefined;
    var store = try early.Store.init(&entries, 2);
    const invalid = [_]early.SessionKey{
        .{ .connection = .{ .generation = 0 }, .session_id = 0 },
        .{ .connection = .{ .generation = 1 }, .session_id = 2 },
        .{ .connection = .{ .generation = 1 }, .session_id = max_data + 1 },
        .{ .connection = .{ .index = 1, .generation = 1 }, .session_id = 0 },
    };
    const before = entries;
    for (invalid) |key| {
        try testing.expectError(error.InvalidKey, store.add(key, .{ .used = .{ .data = 1 } }));
        try testing.expectEqual(@as(?early.Debt, null), store.find(key));
        try testing.expectEqual(@as(?early.Debt, null), store.take(key));
        try testing.expect(!store.forget(key));
    }
    try testing.expectEqualDeep(before, entries);
    try testing.expectEqual(@as(usize, 0), store.active_count);
}

test "WebTransport early debt metadata-only zero deltas do not reserve a SID" {
    var entries: [1]early.Entry = undefined;
    var store = try early.Store.init(&entries, 1);
    const key = early.SessionKey{ .connection = .{ .generation = 1 }, .session_id = 0 };
    try store.add(key, .{});
    try testing.expectEqual(@as(usize, 0), store.active_count);
    try testing.expectEqual(@as(?early.Debt, null), store.find(key));
    try store.add(key, .{ .used = .{ .streams_uni = 1 } });
    const before = store.find(key).?;
    try store.add(key, .{});
    try testing.expectEqualDeep(before, store.find(key).?);
}

test "WebTransport early debt later reclamation needs no duplicate receipt debit" {
    var debt = early.Debt{};
    try debt.add(.{ .used = .{ .data = 9, .streams_uni = 1 } });
    try debt.add(.{ .reclaimed = .{ .data = 9, .streams_uni = 1 } });
    try testing.expectEqualDeep(debt.used, debt.reclaimed);
    const before = debt;
    try testing.expectError(error.InvalidReclamation, debt.add(.{ .reclaimed = .{ .data = 1 } }));
    try testing.expectError(error.InvalidReclamation, debt.add(.{ .reclaimed = .{ .streams_uni = 1 } }));
    try testing.expectEqualDeep(before, debt);
}

test "WebTransport early debt aggregate bounds reject partial updates atomically" {
    var debt = early.Debt{ .used = .{ .data = max_data, .streams_bidi = max_streams, .streams_uni = max_streams } };
    const before = debt;
    try testing.expectError(error.SizeOverflow, debt.add(.{ .used = .{ .data = 1 }, .reclaimed = .{ .streams_uni = 1 } }));
    try testing.expectError(error.SizeOverflow, debt.add(.{ .used = .{ .streams_bidi = 1 } }));
    try testing.expectError(error.SizeOverflow, debt.add(.{ .used = .{ .streams_uni = 1 } }));
    try testing.expectError(error.SizeOverflow, debt.add(.{ .used = .{ .data = std.math.maxInt(u64) } }));
    try testing.expectEqualDeep(before, debt);
}

test "WebTransport early debt bad additions never consume a free slot" {
    var entries: [1]early.Entry = undefined;
    var store = try early.Store.init(&entries, 1);
    const key = early.SessionKey{ .connection = .{ .generation = 1 }, .session_id = 0 };
    const before = entries;
    try testing.expectError(error.InvalidReclamation, store.add(key, .{ .reclaimed = .{ .data = 1 } }));
    try testing.expectError(error.SizeOverflow, store.add(key, .{ .used = .{ .streams_uni = max_streams + 1 } }));
    try testing.expectEqualDeep(before, entries);
    try testing.expectEqual(@as(usize, 0), store.active_count);
}

test "WebTransport early debt survives child lifetime and transfers exactly once" {
    var entries: [1]early.Entry = undefined;
    var store = try early.Store.init(&entries, 1);
    const key = early.SessionKey{ .connection = .{ .generation = 1 }, .session_id = 0 };
    try store.add(key, .{ .used = .{ .data = 4, .streams_bidi = 1 } });
    try store.add(key, .{ .used = .{ .data = 7 }, .reclaimed = .{ .data = 11, .streams_bidi = 1 } });
    var receiver = try flow.Receiver.init(.{ .data = 11, .streams_bidi = 1 });
    try store.find(key).?.import_into(&receiver);
    const transferred = store.take(key).?;
    try testing.expectEqual(@as(u64, 11), transferred.used.data);
    try testing.expectEqualDeep(flow.Limits{ .data = 11, .streams_bidi = 1 }, receiver.budget.used);
    try testing.expectEqualDeep(receiver.budget.used, receiver.reclaimed);
    try testing.expectEqualDeep(flow.Limits{ .data = 22, .streams_bidi = 2 }, receiver.desired);
    try testing.expectEqual(@as(?early.Debt, null), store.take(key));
    try testing.expectEqual(@as(usize, 0), store.active_count);
}

test "WebTransport early debt receiver limit failures preserve debt for later policy" {
    var entries: [1]early.Entry = undefined;
    var store = try early.Store.init(&entries, 1);
    const key = early.SessionKey{ .connection = .{ .generation = 1 }, .session_id = 0 };
    const debt = early.Debt{ .used = .{ .data = 7, .streams_uni = 2 }, .reclaimed = .{ .data = 7, .streams_uni = 1 } };
    try store.add(key, debt);
    var receiver = try flow.Receiver.init(.{ .data = 6, .streams_uni = 2 });
    const before = receiver;
    try testing.expectError(error.FlowControlViolation, store.find(key).?.import_into(&receiver));
    try testing.expectEqualDeep(before, receiver);
    try testing.expectEqualDeep(debt, store.find(key).?);
    receiver = try flow.Receiver.init(.{ .data = 7, .streams_uni = 1 });
    const before_stream = receiver;
    try testing.expectError(error.FlowControlViolation, debt.import_into(&receiver));
    try testing.expectEqualDeep(before_stream, receiver);
}

test "WebTransport early debt imports add to existing usage and desired grants" {
    var receiver = try flow.Receiver.init(.{ .data = 20, .streams_bidi = 3, .streams_uni = 3 });
    try receiver.budget.commit_data(5);
    try receiver.budget.commit_open(.bidi);
    try receiver.consume_data(2);
    const debt = early.Debt{ .used = .{ .data = 9, .streams_bidi = 2, .streams_uni = 1 }, .reclaimed = .{ .data = 4, .streams_bidi = 1 } };
    try debt.import_into(&receiver);
    try testing.expectEqualDeep(flow.Limits{ .data = 14, .streams_bidi = 3, .streams_uni = 1 }, receiver.budget.used);
    try testing.expectEqualDeep(flow.Limits{ .data = 6, .streams_bidi = 1 }, receiver.reclaimed);
    try testing.expectEqualDeep(flow.Limits{ .data = 26, .streams_bidi = 4, .streams_uni = 3 }, receiver.desired);
    try testing.expectEqualDeep(flow.Limits{ .data = 20, .streams_bidi = 3, .streams_uni = 3 }, receiver.budget.limits);
}

test "WebTransport early debt import saturates wire maxima without overflow" {
    var receiver = try flow.Receiver.init(.{ .data = max_data, .streams_bidi = max_streams, .streams_uni = max_streams });
    const debt = early.Debt{ .used = receiver.budget.limits, .reclaimed = receiver.budget.limits };
    try debt.import_into(&receiver);
    try testing.expectEqualDeep(receiver.budget.limits, receiver.desired);
    try testing.expectEqualDeep(debt.used, receiver.budget.used);
    try testing.expectEqualDeep(debt.reclaimed, receiver.reclaimed);
}

test "WebTransport early debt invalid standalone debt cannot borrow receiver reclamation" {
    var receiver = try flow.Receiver.init(.{ .data = 10 });
    try receiver.budget.commit_data(10);
    const before = receiver;
    const invalid = early.Debt{ .reclaimed = .{ .data = 1 } };
    try testing.expectError(error.InvalidReclamation, invalid.import_into(&receiver));
    try testing.expectEqualDeep(before, receiver);
}

test "WebTransport early debt retirement and connection clear release exact entries" {
    var entries: [4]early.Entry = undefined;
    var store = try early.Store.init(&entries, 2);
    const first = early.SessionKey{ .connection = .{ .index = 0, .generation = 1 }, .session_id = 0 };
    const second = early.SessionKey{ .connection = .{ .index = 0, .generation = 2 }, .session_id = 0 };
    const third = early.SessionKey{ .connection = .{ .index = 1, .generation = 1 }, .session_id = 0 };
    for ([_]early.SessionKey{ first, second, third }) |key| try store.add(key, .{ .used = .{ .data = 1 } });
    try testing.expect(store.forget(first));
    try testing.expect(!store.forget(first));
    store.clear_connection(first.connection);
    try testing.expect(store.find(second) != null);
    try testing.expect(store.find(third) != null);
    store.clear_connection(second.connection);
    try testing.expect(store.find(second) == null);
    try testing.expectEqual(@as(usize, 1), store.active_count);
    store.clear_connection(third.connection);
    try testing.expectEqual(@as(usize, 0), store.active_count);
}

test "WebTransport early debt fixed storage handles repeated lifecycle churn without an allocator" {
    var entries: [2]early.Entry = undefined;
    var store = try early.Store.init(&entries, 2);
    const connection = (early.SessionKey{ .connection = .{ .generation = 1 } }).connection;
    for (0..1024) |index| {
        const key = early.SessionKey{ .connection = connection, .session_id = index * 4 };
        try store.add(key, .{ .used = .{ .data = 10, .streams_uni = 1 } });
        try store.add(key, .{ .reclaimed = .{ .data = 10, .streams_uni = 1 } });
        const taken = store.take(key).?;
        try testing.expectEqualDeep(taken.used, taken.reclaimed);
    }
    try testing.expectEqual(@as(usize, 0), store.active_count);
}

test "WebTransport early debt transitions remain evaluable without runtime effects" {
    comptime {
        @setEvalBranchQuota(10000);
        var entries: [2]early.Entry = undefined;
        var store = try early.Store.init(&entries, 2);
        const key = early.SessionKey{ .connection = .{ .generation = 1 }, .session_id = 4 };
        try store.add(key, .{ .used = .{ .data = 5, .streams_uni = 1 } });
        try store.add(key, .{ .reclaimed = .{ .data = 5, .streams_uni = 1 } });
        var receiver = try flow.Receiver.init(.{ .data = 5, .streams_uni = 1 });
        try store.find(key).?.import_into(&receiver);
        try testing.expect(store.take(key) != null);
        try testing.expectEqual(@as(usize, 0), store.active_count);
        try testing.expectEqual(@as(u64, 10), receiver.desired.data);
        try testing.expectEqual(@as(u64, 2), receiver.desired.streams_uni);
    }
}
