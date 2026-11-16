const std = @import("std");
const pending = @import("test_support").webtransport_pending_datagrams;

const Fixture = struct {
    entries: [4]pending.Entry = undefined,
    payloads: [32]u8 = .{0xcc} ** 32,
    terminals: [2]pending.Terminal = undefined,

    fn init(fixture: *Fixture, limit: usize, lifetime_us: u64) !pending.Store {
        return pending.Store.init(.{
            .entries = &fixture.entries,
            .payloads = &fixture.payloads,
            .terminals = &fixture.terminals,
        }, .{ .payload_stride = 8, .per_connection_limit = limit, .lifetime_us = lifetime_us });
    }
};

fn session(index: usize, generation: u64, session_id: u64) pending.SessionKey {
    return .{ .connection = .{ .index = index, .generation = generation }, .session_id = session_id };
}

fn expect_payload(store: *pending.Store, key: pending.SessionKey, now_us: u64, expected: []const u8) !void {
    var output: [8]u8 = undefined;
    const taken = (try store.take_into(key, now_us, &output)) orelse return error.MissingDatagram;
    try std.testing.expectEqual(expected.len, taken.payload_length);
    try std.testing.expectEqualStrings(expected, output[0..taken.payload_length]);
}

test "WebTransport pending terminal lookup preserves full identity across reuse" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const retired = session(0, 7, @as(u64, 1) << 40);
    try std.testing.expect(!store.is_retired(retired));
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(retired));
    try std.testing.expect(store.is_retired(retired));
    try std.testing.expect(!store.is_retired(session(0, 8, retired.session_id)));
    try std.testing.expect(!store.is_retired(session(1, 7, retired.session_id)));
    try std.testing.expect(!store.is_retired(session(0, 7, 0)));
    store.clear_connection(retired.connection);
    try std.testing.expect(!store.is_retired(retired));
}

test "WebTransport pending datagrams copy input and retain matching FIFO across other keys" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const first = session(0, 1, 0);
    const other = session(1, 1, 0);
    var bytes = [_]u8{ 'o', 'n', 'e' };
    try store.enqueue(first, &bytes, 10);
    @memset(&bytes, 'x');
    try store.enqueue(other, "other", 11);
    try store.enqueue(first, "two", 12);
    try expect_payload(&store, first, 13, "one");
    try expect_payload(&store, first, 13, "two");
    try expect_payload(&store, other, 13, "other");
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
    try std.testing.expect(store.next_deadline() == null);
}

test "WebTransport pending datagrams enforce connection quota across session keys" {
    var fixture = Fixture{};
    var store = try fixture.init(2, 100);
    const first = session(0, 1, 0);
    const second = session(0, 1, 4);
    const other = session(1, 1, 0);
    try store.enqueue(first, "one", 0);
    try store.enqueue(second, "two", 0);
    try store.enqueue(other, "other", 0);
    try std.testing.expectError(error.ConnectionLimit, store.enqueue(session(0, 1, 8), "denied", 0));
    try std.testing.expectEqual(@as(usize, 3), store.pending_count);
    try expect_payload(&store, first, 1, "one");
    try expect_payload(&store, second, 1, "two");
    try expect_payload(&store, other, 1, "other");
}

test "WebTransport pending datagrams reject global exhaustion without eviction" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    for (0..4) |index| try store.enqueue(session(index, 1, 0), "kept", 0);
    try std.testing.expectError(error.Full, store.enqueue(session(4, 1, 0), "denied", 0));
    try std.testing.expectEqual(@as(usize, 4), store.pending_count);
    for (0..4) |index| try expect_payload(&store, session(index, 1, 0), 1, "kept");
}

test "WebTransport pending datagrams size failure expires old entries and preserves retained bytes" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const expired = session(0, 1, 0);
    const kept = session(1, 1, 0);
    try store.enqueue(expired, "expired", 100);
    try store.enqueue(kept, "kept", 150);
    try std.testing.expectEqual(@as(usize, 2), store.pending_count);
    try std.testing.expectError(error.PayloadTooLarge, store.enqueue(session(2, 1, 0), "oversized", 200));
    try std.testing.expectEqual(@as(usize, 1), store.pending_count);
    try std.testing.expectEqual(@as(?u64, 250), store.next_deadline());
    try expect_payload(&store, kept, 200, "kept");
}

test "WebTransport pending datagrams expire at equality and recover capacity before enqueue" {
    var fixture = Fixture{};
    var store = try pending.Store.init(.{
        .entries = fixture.entries[0..1],
        .payloads = fixture.payloads[0..8],
        .terminals = &fixture.terminals,
    }, .{ .payload_stride = 8, .per_connection_limit = 1, .lifetime_us = 5 });
    const first = session(0, 1, 0);
    const second = session(1, 1, 0);
    try store.enqueue(first, "old", 10);
    try std.testing.expectEqual(@as(?u64, 15), store.next_deadline());
    try std.testing.expectError(error.ConnectionLimit, store.enqueue(first, "denied", 14));
    try store.enqueue(second, "new", 15);
    try std.testing.expectEqual(@as(usize, 1), store.pending_count);
    try std.testing.expectEqual(@as(?u64, 20), store.next_deadline());
    store.expire(20);
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
    try std.testing.expect(store.next_deadline() == null);
}

test "WebTransport pending datagrams choose earliest supplied deadline without insertion ordering assumptions" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 10);
    try store.enqueue(session(0, 1, 0), "later", 50);
    try store.enqueue(session(1, 1, 0), "earlier", 10);
    try std.testing.expectEqual(@as(?u64, 20), store.next_deadline());
    store.expire(20);
    try std.testing.expectEqual(@as(?u64, 60), store.next_deadline());
    try expect_payload(&store, session(0, 1, 0), 59, "later");
}

test "WebTransport pending datagrams saturate deadlines and expire at maximum equality" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 10);
    const key = session(0, 1, 0);
    const maximum = std.math.maxInt(u64);
    try store.enqueue(key, "last", maximum - 5);
    try std.testing.expectEqual(@as(?u64, maximum), store.next_deadline());
    try expect_payload(&store, key, maximum - 1, "last");
    try store.enqueue(key, "gone", maximum - 1);
    var output: [8]u8 = undefined;
    try std.testing.expect((try store.take_into(key, maximum, &output)) == null);
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
    try store.enqueue(key, "now", maximum);
    try std.testing.expect((try store.take_into(key, maximum, &output)) == null);
}

test "WebTransport pending datagrams permit zero payload and zero lifetime" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const key = session(0, 1, 0);
    try store.enqueue(key, "", 0);
    var output: [0]u8 = .{};
    const taken = (try store.take_into(key, 0, &output)).?;
    try std.testing.expectEqual(@as(usize, 0), taken.payload_length);
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);

    store = try fixture.init(1, 0);
    try store.enqueue(key, "brief", 55);
    try std.testing.expectEqual(@as(?u64, 55), store.next_deadline());
    store.expire(55);
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
}

test "WebTransport pending datagrams small output failure leaves payload and FIFO intact" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const key = session(0, 1, 0);
    try store.enqueue(key, "first", 0);
    try store.enqueue(key, "next", 0);
    var output = [_]u8{ 'x', 'x' };
    try std.testing.expectError(error.BufferTooSmall, store.take_into(key, 1, &output));
    try std.testing.expectEqualStrings("xx", &output);
    try std.testing.expectEqual(@as(usize, 2), store.pending_count);
    try expect_payload(&store, key, 1, "first");
    try expect_payload(&store, key, 1, "next");
}

test "WebTransport pending datagrams copy out and remove before caller mutates queue" {
    var fixture = Fixture{};
    var store = try pending.Store.init(.{
        .entries = fixture.entries[0..1],
        .payloads = fixture.payloads[0..8],
        .terminals = &fixture.terminals,
    }, .{ .payload_stride = 8, .per_connection_limit = 1, .lifetime_us = 100 });
    const first = session(0, 1, 0);
    const second = session(1, 1, 0);
    try store.enqueue(first, "before", 0);
    var output: [8]u8 = undefined;
    const taken = (try store.take_into(first, 1, &output)).?;
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
    try store.enqueue(second, "after", 1);
    try std.testing.expectEqualStrings("before", output[0..taken.payload_length]);
    @memset(&output, 'x');
    store.clear_connection(first.connection);
    try expect_payload(&store, second, 2, "after");
}

test "WebTransport pending datagrams retire exact keys and keep other sessions and generations" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const retired = session(0, 1, 0);
    const sibling = session(0, 1, 4);
    const reused = session(0, 2, 0);
    const other = session(1, 1, 0);
    for ([_]pending.SessionKey{ retired, sibling, reused, other }) |key| try store.enqueue(key, "kept", 0);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(retired));
    try std.testing.expectEqual(@as(usize, 3), store.pending_count);
    try std.testing.expectEqual(@as(usize, 1), store.terminal_count);
    try std.testing.expectError(error.RetiredSession, store.enqueue(retired, "denied", 1));
    try expect_payload(&store, sibling, 1, "kept");
    try expect_payload(&store, reused, 1, "kept");
    try expect_payload(&store, other, 1, "kept");
    store.expire(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 1), store.terminal_count);
    try std.testing.expectError(error.RetiredSession, store.enqueue(retired, "denied", std.math.maxInt(u64)));
}

test "WebTransport pending datagrams exhausted retirement still purges and never evicts terminals" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const first = session(0, 1, 0);
    const second = session(1, 1, 0);
    const rejected = session(2, 1, 0);
    const kept = session(3, 1, 0);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(first));
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(first));
    try std.testing.expectEqual(@as(usize, 1), store.terminal_count);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(second));
    try store.enqueue(rejected, "remove", 0);
    try store.enqueue(kept, "keep", 0);
    try std.testing.expectEqual(pending.RetireResult.exhausted, store.retire(rejected));
    try std.testing.expectEqual(@as(usize, 1), store.pending_count);
    try std.testing.expectEqual(@as(usize, 2), store.terminal_count);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(first));
    try std.testing.expectError(error.RetiredSession, store.enqueue(first, "denied", 0));
    try std.testing.expectError(error.RetiredSession, store.enqueue(second, "denied", 0));
    try expect_payload(&store, kept, 1, "keep");
    store.clear_connection(second.connection);
    try std.testing.expectEqual(@as(usize, 1), store.terminal_count);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(rejected));
}

test "WebTransport pending datagrams zero terminal budget reports exhaustion after purge" {
    var fixture = Fixture{};
    var store = try pending.Store.init(.{
        .entries = &fixture.entries,
        .payloads = &fixture.payloads,
        .terminals = fixture.terminals[0..0],
    }, .{ .payload_stride = 8, .per_connection_limit = 4, .lifetime_us = 100 });
    const key = session(0, 1, 0);
    try store.enqueue(key, "remove", 0);
    try std.testing.expectEqual(pending.RetireResult.exhausted, store.retire(key));
    try std.testing.expectEqual(@as(usize, 0), store.pending_count);
    try std.testing.expectEqual(@as(usize, 0), store.terminal_count);
    try std.testing.expectEqual(pending.RetireResult.exhausted, store.retire(key));
}

test "WebTransport pending datagrams clear only exact connection generation and recover terminal slots" {
    var fixture = Fixture{};
    var store = try fixture.init(4, 100);
    const old = session(0, 1, 0);
    const old_sibling = session(0, 1, 4);
    const reused = session(0, 2, 0);
    const other = session(1, 1, 0);
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(old));
    try std.testing.expectEqual(pending.RetireResult.remembered, store.retire(reused));
    try store.enqueue(old_sibling, "old", 0);
    try store.enqueue(other, "other", 0);
    store.clear_connection(old.connection);
    store.clear_connection(old.connection);
    try std.testing.expectEqual(@as(usize, 1), store.pending_count);
    try std.testing.expectEqual(@as(usize, 1), store.terminal_count);
    try std.testing.expectError(error.RetiredSession, store.enqueue(reused, "denied", 1));
    try store.enqueue(old, "allowed", 1);
    try expect_payload(&store, old, 1, "allowed");
    try expect_payload(&store, other, 1, "other");
}

test "WebTransport pending datagrams isolate quotas and pending cleanup by connection generation" {
    var fixture = Fixture{};
    var store = try fixture.init(1, 100);
    const old = session(0, 1, 0);
    const reused = session(0, 2, 0);
    try store.enqueue(old, "old", 0);
    try store.enqueue(reused, "new", 0);
    try std.testing.expectEqual(@as(usize, 2), store.pending_count);
    store.clear_connection(old.connection);
    try std.testing.expectEqual(@as(usize, 1), store.pending_count);
    try expect_payload(&store, reused, 1, "new");
}

test "WebTransport pending datagrams validate storage geometry before mutation" {
    var fixture = Fixture{};
    for (&fixture.entries) |*entry| entry.* = .{};
    for (&fixture.terminals) |*terminal| terminal.* = .{};
    const original_entries = fixture.entries;
    const original_terminals = fixture.terminals;
    const storage = pending.Storage{ .entries = &fixture.entries, .payloads = &fixture.payloads, .terminals = &fixture.terminals };
    const policy = pending.Policy{ .payload_stride = 8, .per_connection_limit = 4, .lifetime_us = 100 };
    var invalid_storage = storage;
    invalid_storage.entries = fixture.entries[0..0];
    try std.testing.expectError(error.InvalidCapacity, pending.Store.init(invalid_storage, policy));
    invalid_storage = storage;
    invalid_storage.payloads = fixture.payloads[0..31];
    try std.testing.expectError(error.PayloadStorageTooSmall, pending.Store.init(invalid_storage, policy));
    var invalid_policy = policy;
    invalid_policy.payload_stride = 0;
    try std.testing.expectError(error.InvalidStride, pending.Store.init(storage, invalid_policy));
    invalid_policy = policy;
    invalid_policy.per_connection_limit = 0;
    try std.testing.expectError(error.InvalidConnectionLimit, pending.Store.init(storage, invalid_policy));
    invalid_policy = policy;
    invalid_policy.payload_stride = std.math.maxInt(usize);
    try std.testing.expectError(error.StorageOverflow, pending.Store.init(storage, invalid_policy));
    try std.testing.expectEqualDeep(original_entries, fixture.entries);
    try std.testing.expectEqualDeep(original_terminals, fixture.terminals);
    try std.testing.expectEqualSlices(u8, &(.{0xcc} ** 32), &fixture.payloads);
}
