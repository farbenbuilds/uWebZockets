const std = @import("std");
const testing = std.testing;
const flow = @import("test_support").webtransport_session_flow;
const wt = @import("test_support").webtransport;

test "WebTransport session flow validates initial wire bounds" {
    const maximum = flow.Limits{ .data = wt.max_quic_varint, .streams_bidi = wt.max_stream_count, .streams_uni = wt.max_stream_count };
    const budget = try flow.Budget.init(maximum);
    try testing.expectEqualDeep(maximum, budget.limits);
    try testing.expectEqualDeep(flow.Limits{}, budget.used);
    try testing.expectError(error.InvalidLimit, flow.Budget.init(.{ .data = wt.max_quic_varint + 1 }));
    try testing.expectError(error.InvalidLimit, flow.Receiver.init(.{ .streams_bidi = wt.max_stream_count + 1 }));
    try testing.expectError(error.InvalidLimit, flow.Receiver.init(.{ .streams_uni = wt.max_stream_count + 1 }));
}

test "WebTransport session flow zero budgets reject debit atomically" {
    var budget = try flow.Budget.init(.{});
    const before = budget;
    try testing.expect(!budget.can_open(.bidi));
    try testing.expect(!budget.can_open(.uni));
    try testing.expectEqual(@as(usize, 0), budget.allowance(100));
    try testing.expectError(error.FlowControlViolation, budget.commit_open(.bidi));
    try testing.expectError(error.FlowControlViolation, budget.commit_open(.uni));
    try testing.expectError(error.FlowControlViolation, budget.commit_data(1));
    try budget.commit_data(0);
    try testing.expectEqualDeep(before, budget);
}

test "WebTransport session flow successful creation consumes independent cumulative counts" {
    var budget = try flow.Budget.init(.{ .streams_bidi = 1, .streams_uni = 2 });
    const before = budget;
    try testing.expect(budget.can_open(.bidi));
    try testing.expect(budget.can_open(.uni));
    try testing.expectEqualDeep(before, budget);
    try budget.commit_open(.bidi);
    try testing.expect(!budget.can_open(.bidi));
    try testing.expect(budget.can_open(.uni));
    try budget.commit_open(.uni);
    try budget.commit_open(.uni);
    const full = budget;
    try testing.expectError(error.FlowControlViolation, budget.commit_open(.uni));
    try testing.expectEqualDeep(full, budget);
    try budget.grant(.streams_bidi, 2);
    try budget.commit_open(.bidi);
    try testing.expectEqualDeep(flow.Limits{ .streams_bidi = 2, .streams_uni = 2 }, budget.used);
}

test "WebTransport session flow commits only the accepted payload prefix" {
    var budget = try flow.Budget.init(.{ .data = 10 });
    try testing.expectEqual(@as(usize, 10), budget.allowance(20));
    try budget.commit_data(3);
    try testing.expectEqual(@as(usize, 4), budget.allowance(4));
    try testing.expectEqual(@as(usize, 7), budget.allowance(20));
    const partial = budget;
    try budget.commit_data(0);
    try testing.expectEqualDeep(partial, budget);
    try budget.commit_data(7);
    const full = budget;
    try testing.expectError(error.FlowControlViolation, budget.commit_data(std.math.maxInt(u64)));
    try testing.expectEqualDeep(full, budget);
    try budget.grant(.data, 11);
    try budget.commit_data(1);
    try testing.expectEqual(@as(u64, 11), budget.used.data);
}

test "WebTransport session flow grants must strictly increase within their own wire bound" {
    var budget = try flow.Budget.init(.{ .data = 5, .streams_bidi = 5, .streams_uni = 5 });
    const kinds = [_]flow.Credit{ .data, .streams_bidi, .streams_uni };
    for (kinds) |kind| {
        const before = budget;
        try testing.expectError(error.FlowControlViolation, budget.grant(kind, 5));
        try testing.expectError(error.FlowControlViolation, budget.grant(kind, 4));
        const limit = if (kind == .data) wt.max_quic_varint else wt.max_stream_count;
        try testing.expectError(error.FlowControlViolation, budget.grant(kind, limit + 1));
        try testing.expectEqualDeep(before, budget);
        try budget.grant(kind, limit);
    }
    try testing.expectEqualDeep(flow.Limits{ .data = wt.max_quic_varint, .streams_bidi = wt.max_stream_count, .streams_uni = wt.max_stream_count }, budget.limits);
}

test "WebTransport session flow receipt and reclamation remain separate" {
    var receiver = try flow.Receiver.init(.{ .data = 20, .streams_bidi = 1 });
    try receiver.budget.commit_open(.bidi);
    // Authoritative native deltas include the unseen final gap exactly once.
    try receiver.budget.commit_data(6);
    try receiver.budget.commit_data(14);
    try receiver.consume_data(6);
    try testing.expectEqual(@as(u64, 20), receiver.budget.used.data);
    try testing.expectEqual(@as(u64, 20), receiver.budget.limits.data);
    try testing.expectEqual(@as(u64, 26), receiver.desired.data);
    try testing.expectError(error.FlowControlViolation, receiver.budget.commit_data(1));
    try receiver.consume_data(14);
    try receiver.close_stream(.bidi);
    try testing.expectEqualDeep(flow.Limits{ .data = 40, .streams_bidi = 2 }, receiver.desired);
    try testing.expectEqualDeep(flow.Limits{ .data = 20, .streams_bidi = 1 }, receiver.budget.used);
}

test "WebTransport session flow incoming data on a local BIDI needs no peer stream count" {
    var receiver = try flow.Receiver.init(.{ .data = 8 });
    try receiver.budget.commit_data(8);
    try receiver.consume_data(8);
    try testing.expectEqual(@as(u64, 16), receiver.desired.data);
    try testing.expectEqual(@as(u64, 0), receiver.budget.used.streams_bidi);
    try testing.expectError(error.InvalidConsumption, receiver.close_stream(.bidi));
}

test "WebTransport session flow excessive reclamation preserves all receiver state" {
    var receiver = try flow.Receiver.init(.{ .data = 10, .streams_uni = 1 });
    try receiver.budget.commit_data(7);
    try receiver.budget.commit_open(.uni);
    try receiver.consume_data(4);
    try receiver.close_stream(.uni);
    const before = receiver;
    try testing.expectError(error.InvalidConsumption, receiver.consume_data(4));
    try testing.expectError(error.InvalidConsumption, receiver.consume_data(std.math.maxInt(u64)));
    try testing.expectError(error.InvalidConsumption, receiver.close_stream(.uni));
    try testing.expectEqualDeep(before, receiver);
}

test "WebTransport session flow replenishment saturates at protocol maxima" {
    var receiver = try flow.Receiver.init(.{ .data = wt.max_quic_varint, .streams_bidi = wt.max_stream_count, .streams_uni = wt.max_stream_count });
    try receiver.budget.commit_data(wt.max_quic_varint);
    try receiver.consume_data(wt.max_quic_varint);
    try receiver.budget.commit_open(.bidi);
    try receiver.budget.commit_open(.uni);
    try receiver.close_stream(.bidi);
    try receiver.close_stream(.uni);
    try testing.expectEqualDeep(receiver.budget.limits, receiver.desired);
    var output = flow.CreditOutput{};
    try testing.expectEqual(@as(?[]const u8, null), output.prepare(&receiver));
}

test "WebTransport session flow fragmented capsule advertises only its accepted suffix" {
    var receiver = try flow.Receiver.init(.{ .data = 64 });
    try receiver.budget.commit_data(64);
    try receiver.consume_data(64);
    var output = flow.CreditOutput{};
    const encoded = output.prepare(&receiver).?;
    var bytes: [13]u8 = undefined;
    @memcpy(bytes[0..encoded.len], encoded);
    const length = encoded.len;
    const before = output;
    try output.advance(&receiver, 0);
    try testing.expectEqual(before.offset, output.offset);
    try testing.expectEqualSlices(u8, bytes[0..length], output.prepare(&receiver).?);
    var offset: usize = 0;
    while (offset + 1 < length) : (offset += 1) {
        try output.advance(&receiver, 1);
        try testing.expectEqual(@as(u64, 64), receiver.budget.limits.data);
        try testing.expectEqualSlices(u8, bytes[offset + 1 .. length], output.prepare(&receiver).?);
    }
    try output.advance(&receiver, 1);
    try testing.expectEqual(@as(u64, 128), receiver.budget.limits.data);
    try testing.expectEqual(@as(?[]const u8, null), output.prepare(&receiver));
    const decoded = try wt.decode_capsule(bytes[0..length]);
    try testing.expectEqual(@as(u64, 128), decoded.capsule.max_data);
}

test "WebTransport session flow in flight grants stay immutable while desired credit coalesces" {
    var receiver = try flow.Receiver.init(.{ .data = 10 });
    try receiver.budget.commit_data(10);
    try receiver.consume_data(2);
    var output = flow.CreditOutput{};
    const first = output.prepare(&receiver).?;
    const first_length = first.len;
    try output.advance(&receiver, 1);
    try receiver.consume_data(3);
    try receiver.consume_data(5);
    const remainder = output.prepare(&receiver).?;
    try testing.expectEqual(first_length - 1, remainder.len);
    try testing.expectEqual(@as(u64, 12), (try wt.decode_capsule(output.buffer[0..first_length])).capsule.max_data);
    try output.advance(&receiver, remainder.len);
    try testing.expectEqual(@as(u64, 12), receiver.budget.limits.data);
    const next = output.prepare(&receiver).?;
    try testing.expectEqual(@as(u64, 20), (try wt.decode_capsule(next)).capsule.max_data);
    try output.advance(&receiver, next.len);
    try testing.expectEqual(@as(u64, 20), receiver.budget.limits.data);
    try testing.expectEqual(@as(?[]const u8, null), output.prepare(&receiver));
}

test "WebTransport session flow invalid output progress leaves output and receiver unchanged" {
    var receiver = try flow.Receiver.init(.{ .data = 2 });
    try receiver.budget.commit_data(2);
    try receiver.consume_data(2);
    var output = flow.CreditOutput{};
    try testing.expectError(error.InvalidProgress, output.advance(&receiver, 1));
    const bytes = output.prepare(&receiver).?;
    const before_receiver = receiver;
    const before_output = output;
    try testing.expectError(error.InvalidProgress, output.advance(&receiver, bytes.len + 1));
    try testing.expectError(error.InvalidProgress, output.advance(&receiver, std.math.maxInt(usize)));
    try testing.expectEqualDeep(before_receiver, receiver);
    try testing.expectEqualDeep(before_output, output);
}

test "WebTransport session flow credit output fairly serves all kinds without BLOCKED" {
    var receiver = try flow.Receiver.init(.{ .data = 8, .streams_bidi = 1, .streams_uni = 1 });
    try receiver.budget.commit_open(.bidi);
    try receiver.budget.commit_open(.uni);
    try receiver.budget.commit_data(8);
    try receiver.consume_data(1);
    try receiver.close_stream(.bidi);
    try receiver.close_stream(.uni);
    var output = flow.CreditOutput{};
    const first = output.prepare(&receiver).?;
    try testing.expectEqual(@as(u64, 9), (try wt.decode_capsule(first)).capsule.max_data);
    try output.advance(&receiver, first.len);
    try receiver.consume_data(7);
    const second = output.prepare(&receiver).?;
    try testing.expectEqual(@as(u64, 2), (try wt.decode_capsule(second)).capsule.max_streams_bidi);
    try output.advance(&receiver, second.len);
    const third = output.prepare(&receiver).?;
    try testing.expectEqual(@as(u64, 2), (try wt.decode_capsule(third)).capsule.max_streams_uni);
    try output.advance(&receiver, third.len);
    const fourth = output.prepare(&receiver).?;
    try testing.expectEqual(@as(u64, 16), (try wt.decode_capsule(fourth)).capsule.max_data);
    try output.advance(&receiver, fourth.len);
    try testing.expectEqualDeep(receiver.desired, receiver.budget.limits);
    try testing.expectEqual(@as(?[]const u8, null), output.prepare(&receiver));
}

test "WebTransport session flow maximum grant fits the fixed capsule buffer" {
    var receiver = try flow.Receiver.init(.{ .data = wt.max_quic_varint - 1 });
    try receiver.budget.commit_data(1);
    try receiver.consume_data(1);
    var output = flow.CreditOutput{};
    const bytes = output.prepare(&receiver).?;
    try testing.expectEqual(@as(usize, 13), bytes.len);
    try testing.expectEqual(@as(u64, wt.max_quic_varint), (try wt.decode_capsule(bytes)).capsule.max_data);
    try output.advance(&receiver, bytes.len);
    try testing.expectEqual(@as(u64, wt.max_quic_varint), receiver.budget.limits.data);
}

test "WebTransport session flow serialized credit recovers a blocked sender" {
    var sender = try flow.Budget.init(.{ .data = 3, .streams_uni = 1 });
    var receiver = try flow.Receiver.init(sender.limits);
    try sender.commit_open(.uni);
    try receiver.budget.commit_open(.uni);
    try sender.commit_data(3);
    try receiver.budget.commit_data(3);
    try testing.expectEqual(@as(usize, 0), sender.allowance(1));
    try testing.expect(!sender.can_open(.uni));
    try receiver.consume_data(3);
    try receiver.close_stream(.uni);
    var output = flow.CreditOutput{};
    while (output.prepare(&receiver)) |bytes| {
        const decoded = (try wt.decode_capsule(bytes)).capsule;
        switch (decoded) {
            .max_data => |value| try sender.grant(.data, value),
            .max_streams_uni => |value| try sender.grant(.streams_uni, value),
            else => return error.UnexpectedCapsule,
        }
        try output.advance(&receiver, bytes.len);
    }
    try testing.expectEqual(@as(usize, 3), sender.allowance(100));
    try testing.expect(sender.can_open(.uni));
    try sender.commit_data(3);
    try sender.commit_open(.uni);
    try testing.expectEqualDeep(flow.Limits{ .data = 6, .streams_uni = 2 }, sender.used);
}
