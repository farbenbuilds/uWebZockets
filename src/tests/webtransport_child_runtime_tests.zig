const std = @import("std");
const child = @import("test_support").webtransport_child_runtime;
const testing = std.testing;
const max_varint: u64 = (1 << 62) - 1;
const metadata = child.Metadata{
    .connection = .{ .index = 7, .generation = 9 },
    .session_id = 0,
    .stream_id = 4,
    .receive_prefix_size = 3,
    .direction = .bidi,
};

test "WebTransport child runtime captures full IDs and both generations" {
    var full = metadata;
    full.connection = .{ .index = std.math.maxInt(usize), .generation = std.math.maxInt(u64) };
    full.session_id = max_varint & ~@as(u64, 3);
    full.stream_id = max_varint;
    full.receive_prefix_size = 16;
    full.direction = .uni;
    full.location = .{ .index = 17, .generation = std.math.maxInt(u64) };
    var state = try child.State.init(full, std.math.maxInt(u64));
    const info = try state.begin_open(.{ .index = 23, .generation = std.math.maxInt(u64) - 1 }, @enumFromInt(15));
    try testing.expectEqualDeep(full.connection, info.key.connection);
    try testing.expectEqual(full.session_id, info.key.session_id);
    try testing.expectEqual(full.stream_id, info.key.stream_id);
    try testing.expectEqualDeep(full.location, info.key.location);
    try testing.expectEqual(@as(u8, 15), @intFromEnum(info.key.route));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), info.key.session.generation);
    try testing.expectEqual(@as(usize, 23), info.key.session.index);
    try testing.expectEqual(full.direction, info.direction);
    try testing.expectEqual(@as(u8, 16), info.receive_prefix_size);
    try testing.expectEqual(@as(u8, 15), @intFromEnum(info.route));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), state.deadline_us);
    try testing.expectEqual(@as(u8, 16), state.ledger.receive_prefix_size);
}

test "WebTransport child runtime validates incoming metadata without fixing endpoint role" {
    var invalid = metadata;
    invalid.connection.generation = 0;
    try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    invalid = metadata;
    invalid.session_id = 2;
    try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    invalid = metadata;
    invalid.session_id = max_varint + 1;
    try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    invalid = metadata;
    invalid.stream_id = max_varint + 1;
    try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    invalid = metadata;
    invalid.direction = .uni;
    try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    for ([_]u8{ 0, 1, 2, 17, 255 }) |prefix| {
        invalid = metadata;
        invalid.receive_prefix_size = prefix;
        try testing.expectError(error.InvalidMetadata, child.State.init(invalid, 0));
    }
    var other_role = metadata;
    other_role.stream_id = 5;
    _ = try child.State.init(other_role, 0);
}

test "WebTransport child runtime receive reset keeps active phase and survives independent send finish" {
    var state = try child.State.init(metadata, 0);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try state.complete_open(true);
    const code: u64 = (1 << 61) + 37;
    _ = try state.ledger.observe(.{ .final_size = 8, .reliable_size = 3, .reset_error = code, .reset_visible = true });
    try testing.expectEqual(code, state.ledger.take_reset().?);
    try testing.expectEqual(child.Phase.active, state.phase);
    const closed = (try state.finish_close()).?;
    try testing.expectEqual(child.CloseReason.peer_reset, closed.reason);
    try testing.expectEqual(code, closed.code.?);
    try testing.expectEqual(@as(u64, 5), closed.final_payload_size.?);
    try testing.expectEqual(@as(u64, 5), closed.accounted_bytes);
    try testing.expect((try state.finish_close()) == null);
}

test "WebTransport child runtime pending reservation transfers once" {
    var state = try child.State.init(metadata, 100);
    try testing.expect(state.reserve_pending());
    try testing.expect(!state.reserve_pending());
    try testing.expect(state.take_pending());
    try testing.expect(!state.take_pending());
    try testing.expect(!state.reserve_pending());
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try testing.expect(!state.reserve_pending());
}

test "WebTransport child runtime rejected transitions are atomic" {
    var state = try child.State.init(metadata, 100);
    const before = state;
    try testing.expectError(error.InvalidParent, state.begin_open(.{ .index = 0, .generation = 0 }, @enumFromInt(0)));
    try testing.expectEqualDeep(before, state);
    try testing.expectError(error.InvalidTransition, state.complete_open(true));
    try testing.expectEqualDeep(before, state);
    const info = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(2));
    const opening = state;
    try testing.expectError(error.InvalidTransition, state.begin_open(.{ .index = 0, .generation = 2 }, @enumFromInt(3)));
    try testing.expectEqualDeep(opening, state);
    try testing.expectEqualDeep(info.key, state.key.?);
    try state.complete_open(true);
    const active = state;
    try testing.expectError(error.InvalidTransition, state.complete_open(false));
    try testing.expectEqualDeep(active, state);
}

test "WebTransport child runtime cannot finalize during an open callback" {
    var state = try child.State.init(metadata, 100);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    const opening = state;
    try testing.expectError(error.OpenInProgress, state.finish_close());
    try testing.expectEqualDeep(opening, state);
    try testing.expect(state.begin_close(.session_closed, 17));
    const closing = state;
    try testing.expectError(error.OpenInProgress, state.finish_close());
    try testing.expectEqualDeep(closing, state);
}

test "WebTransport child runtime acceptance after reentrant cancel retains close ownership" {
    var state = try child.State.init(metadata, 100);
    const info = try state.begin_open(.{ .index = 0, .generation = 91 }, @enumFromInt(3));
    try testing.expect(state.begin_close(.session_closed, 17));
    try testing.expect(!state.begin_close(.shutdown, 99));
    try state.complete_open(true);
    try testing.expectEqual(child.Phase.closing, state.phase);
    try testing.expect(state.consumer_owned and !state.open_pending);
    const event = (try state.finish_close()).?;
    try testing.expectEqualDeep(info.key, event.key);
    try testing.expectEqual(@as(u64, 91), event.key.session.generation);
    try testing.expectEqual(child.CloseReason.session_closed, event.reason);
    try testing.expectEqual(@as(?u64, 17), event.code);
    try testing.expectEqual(@as(?u64, null), event.final_payload_size);
    try testing.expectEqual(@as(u64, 0), event.accounted_bytes);
    try testing.expect(state.close_delivered and state.ledger.closed);
    try testing.expectEqual(@as(?child.ClosedEvent, null), try state.finish_close());
    try testing.expect(!state.begin_close(.connection_closed, null));
}

test "WebTransport child runtime rejected open never owns a close callback" {
    var state = try child.State.init(metadata, 100);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try state.complete_open(false);
    try testing.expectEqual(child.Phase.closing, state.phase);
    try testing.expectEqual(@as(?child.CloseReason, .rejected), state.cancel_reason);
    try testing.expect(!state.consumer_owned);
    try testing.expectEqual(@as(?child.ClosedEvent, null), try state.finish_close());
    try testing.expectEqual(child.Phase.closed, state.phase);
    try testing.expect(state.ledger.closed);
}

test "WebTransport child runtime rejection preserves an earlier cancellation" {
    var state = try child.State.init(metadata, 100);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try testing.expect(state.begin_close(.expired, 37));
    try state.complete_open(false);
    try testing.expectEqual(@as(?child.CloseReason, .expired), state.cancel_reason);
    try testing.expectEqual(@as(?u64, 37), state.cancel_code);
    try testing.expectEqual(@as(?child.ClosedEvent, null), try state.finish_close());
}

test "WebTransport child runtime native close preserves ledger final accounting" {
    var state = try child.State.init(metadata, 100);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try state.complete_open(true);
    _ = try state.ledger.record_read(2);
    _ = try state.ledger.observe(.{ .final_size = 10, .reliable_size = 10, .fin_received = true });
    const event = (try state.finish_close()).?;
    try testing.expectEqual(child.CloseReason.completed, event.reason);
    try testing.expectEqual(@as(?u64, null), event.code);
    try testing.expectEqual(@as(?u64, 7), event.final_payload_size);
    try testing.expectEqual(@as(u64, 7), event.accounted_bytes);
    try testing.expectEqual(@as(u64, 2), state.ledger.payload_read);
    try testing.expectEqual(@as(?child.ClosedEvent, null), try state.finish_close());
}

test "WebTransport child runtime unknown final stays unknown at connection destruction" {
    var state = try child.State.init(metadata, 100);
    _ = try state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0));
    try state.complete_open(true);
    _ = try state.ledger.record_read(2);
    try testing.expect(state.begin_close(.connection_closed, null));
    const event = (try state.finish_close()).?;
    try testing.expectEqual(@as(?u64, null), event.final_payload_size);
    try testing.expectEqual(@as(u64, 2), event.accounted_bytes);
    try testing.expectEqual(@as(?u64, null), state.ledger.final_size);
    try testing.expect(state.ledger.closed);
}

test "WebTransport child runtime waiting cancellation releases pending ownership after close" {
    var state = try child.State.init(metadata, 100);
    try testing.expect(state.reserve_pending());
    try testing.expect(state.begin_close(.expired, 0));
    try testing.expectEqual(@as(?child.ClosedEvent, null), try state.finish_close());
    try testing.expect(state.pending_reserved);
    try testing.expect(state.take_pending());
    try testing.expect(!state.take_pending());
    try testing.expect(!state.reserve_pending());
    const closed = state;
    try testing.expectError(error.InvalidTransition, state.begin_open(.{ .index = 0, .generation = 1 }, @enumFromInt(0)));
    try testing.expectEqualDeep(closed, state);
}
