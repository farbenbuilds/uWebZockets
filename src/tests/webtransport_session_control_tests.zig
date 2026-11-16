const std = @import("std");
const testing = std.testing;
const control = @import("test_support").webtransport_session_control;
const flow = @import("test_support").webtransport_session_flow;
const early = @import("test_support").webtransport_early_debt;
const max_data: u64 = (1 << 62) - 1;
const max_streams: u64 = 1 << 60;

test "WebTransport session control negotiation needs bilateral nonzero intent" {
    const limits = [_]flow.Limits{ .{}, .{ .data = 1 }, .{ .streams_bidi = 1 }, .{ .streams_uni = 1 } };
    for (limits, 0..) |local, local_index| {
        for (limits, 0..) |peer, peer_index| {
            try testing.expectEqual(local_index != 0 and peer_index != 0, control.negotiated(local, peer));
        }
    }
}

test "WebTransport session control initializes independent directional budgets" {
    const local = flow.Limits{ .data = 10, .streams_bidi = 2, .streams_uni = 3 };
    const peer = flow.Limits{ .data = 5, .streams_bidi = 4, .streams_uni = 1 };
    const state = try control.State.init(local, peer, .{});
    try testing.expectEqualDeep(local, state.receive.budget.limits);
    try testing.expectEqualDeep(local, state.receive.desired);
    try testing.expectEqualDeep(peer, state.send.limits);
    try testing.expectEqualDeep(flow.Limits{}, state.send.used);
    try testing.expectEqualDeep(flow.Limits{}, state.receive.budget.used);
}

test "WebTransport session control validates both initial limit sets" {
    try testing.expectError(error.InvalidLimit, control.State.init(.{ .data = max_data + 1 }, .{}, .{}));
    try testing.expectError(error.InvalidLimit, control.State.init(.{}, .{ .data = max_data + 1 }, .{}));
    try testing.expectError(error.InvalidLimit, control.State.init(.{ .streams_bidi = max_streams + 1 }, .{}, .{}));
    try testing.expectError(error.InvalidLimit, control.State.init(.{}, .{ .streams_uni = max_streams + 1 }, .{}));
}

test "WebTransport session control imports used and reclaimed debt before admission" {
    const debt = early.Debt{
        .used = .{ .data = 7, .streams_bidi = 2, .streams_uni = 1 },
        .reclaimed = .{ .data = 3, .streams_bidi = 1, .streams_uni = 1 },
    };
    const state = try control.State.init(.{ .data = 10, .streams_bidi = 2, .streams_uni = 2 }, .{ .data = 5 }, debt);
    try testing.expectEqualDeep(debt.used, state.receive.budget.used);
    try testing.expectEqualDeep(debt.reclaimed, state.receive.reclaimed);
    try testing.expectEqualDeep(flow.Limits{ .data = 13, .streams_bidi = 3, .streams_uni = 3 }, state.receive.desired);
    try testing.expectEqual(@as(u64, 10), state.receive.budget.limits.data);
    try testing.expectEqualDeep(flow.Limits{}, state.send.used);
}

test "WebTransport session control rejects initial debt above advertised limits even if reclaimed" {
    const debt = early.Debt{ .used = .{ .data = 9 }, .reclaimed = .{ .data = 9 } };
    try testing.expectError(error.FlowControlViolation, control.State.init(.{ .data = 8 }, .{}, debt));
    try testing.expectError(error.FlowControlViolation, control.State.init(.{ .streams_uni = 1 }, .{}, .{ .used = .{ .streams_uni = 2 } }));
    try testing.expectError(error.InvalidReclamation, control.State.init(.{ .data = 10 }, .{}, .{ .reclaimed = .{ .data = 1 } }));
    try testing.expectError(error.SizeOverflow, control.State.init(.{ .data = max_data }, .{}, .{ .used = .{ .data = max_data + 1 } }));
}

test "WebTransport session control accepts live reclamation without duplicate receipt" {
    var state = try control.State.init(.{ .data = 10, .streams_bidi = 2, .streams_uni = 2 }, .{ .data = 4 }, .{});
    try state.apply_receive(.{ .used = .{ .data = 7, .streams_bidi = 1, .streams_uni = 2 } });
    const before_send = state.send;
    try state.apply_receive(.{ .reclaimed = .{ .data = 4, .streams_uni = 1 } });
    try testing.expectEqualDeep(flow.Limits{ .data = 7, .streams_bidi = 1, .streams_uni = 2 }, state.receive.budget.used);
    try testing.expectEqualDeep(flow.Limits{ .data = 4, .streams_uni = 1 }, state.receive.reclaimed);
    try testing.expectEqualDeep(flow.Limits{ .data = 14, .streams_bidi = 2, .streams_uni = 3 }, state.receive.desired);
    try testing.expectEqualDeep(before_send, state.send);
    const before = state;
    try state.apply_receive(.{});
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control mixed receive failures preserve all state" {
    var state = try control.State.init(.{ .data = 10, .streams_bidi = 1, .streams_uni = 1 }, .{ .data = 3 }, .{
        .used = .{ .data = 7, .streams_bidi = 1 },
    });
    const before = state;
    try testing.expectError(error.FlowControlViolation, state.apply_receive(.{ .used = .{ .data = 4 }, .reclaimed = .{ .data = 2 } }));
    try testing.expectError(error.FlowControlViolation, state.apply_receive(.{ .used = .{ .data = 1, .streams_bidi = 1 } }));
    try testing.expectError(error.FlowControlViolation, state.apply_receive(.{ .used = .{ .streams_uni = 2 } }));
    try testing.expectError(error.InvalidReclamation, state.apply_receive(.{ .used = .{ .data = 1 }, .reclaimed = .{ .data = 9 } }));
    try testing.expectError(error.InvalidReclamation, state.apply_receive(.{ .reclaimed = .{ .streams_uni = 1 } }));
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control desired credit is not spendable before full output acceptance" {
    var state = try control.State.init(.{ .data = 4 }, .{}, .{ .used = .{ .data = 4 } });
    try state.apply_receive(.{ .reclaimed = .{ .data = 4 } });
    const output = state.credits.prepare(&state.receive).?;
    const length = output.len;
    try state.credits.advance(&state.receive, length - 1);
    const before = state;
    try testing.expectError(error.FlowControlViolation, state.apply_receive(.{ .used = .{ .data = 1 } }));
    try testing.expectEqualDeep(before, state);
    try state.credits.advance(&state.receive, 1);
    try state.apply_receive(.{ .used = .{ .data = 4 } });
    try testing.expectEqual(@as(u64, 8), state.receive.budget.used.data);
    try testing.expectEqual(@as(u64, 8), state.receive.budget.limits.data);
    try testing.expectEqual(@as(u64, 4), state.receive.reclaimed.data);
}

test "WebTransport session control wire overflow and invalid reclamation remain atomic" {
    const maximum = flow.Limits{ .data = max_data, .streams_bidi = max_streams, .streams_uni = max_streams };
    var state = try control.State.init(maximum, maximum, .{ .used = maximum });
    const before = state;
    try testing.expectError(error.SizeOverflow, state.apply_receive(.{ .used = .{ .data = 1 } }));
    try testing.expectError(error.SizeOverflow, state.apply_receive(.{ .used = .{ .streams_bidi = 1 } }));
    try testing.expectError(error.SizeOverflow, state.apply_receive(.{ .used = .{ .streams_uni = 1 } }));
    try testing.expectError(error.SizeOverflow, state.apply_receive(.{ .reclaimed = .{ .data = max_data + 1 } }));
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control large cumulative reclamation saturates in one update" {
    const maximum = flow.Limits{ .data = max_data, .streams_bidi = max_streams, .streams_uni = max_streams };
    var state = try control.State.init(maximum, .{}, .{ .used = maximum });
    try state.apply_receive(.{ .reclaimed = maximum });
    try testing.expectEqualDeep(maximum, state.receive.reclaimed);
    try testing.expectEqualDeep(maximum, state.receive.desired);
    try testing.expectEqualDeep(maximum, state.receive.budget.used);
    try testing.expectEqual(@as(?[]const u8, null), state.credits.prepare(&state.receive));
}

test "WebTransport session control MAX capsules affect only sender credit" {
    var state = try control.State.init(.{ .data = 5, .streams_uni = 1 }, .{ .data = 2 }, .{
        .used = .{ .data = 3 },
        .reclaimed = .{ .data = 1 },
    });
    _ = state.credits.prepare(&state.receive).?;
    try state.credits.advance(&state.receive, 1);
    const receive = state.receive;
    const credits = state.credits;
    try state.send.commit_data(1);
    try testing.expectEqual(control.CapsuleAction.data_credit, try state.apply_capsule(.{ .max_data = 10 }));
    try testing.expectEqual(control.CapsuleAction.stream_credit, try state.apply_capsule(.{ .max_streams_bidi = 1 }));
    try testing.expectEqual(control.CapsuleAction.stream_credit, try state.apply_capsule(.{ .max_streams_uni = 2 }));
    try testing.expectEqualDeep(flow.Limits{ .data = 10, .streams_bidi = 1, .streams_uni = 2 }, state.send.limits);
    try testing.expectEqual(@as(u64, 1), state.send.used.data);
    try testing.expectEqualDeep(receive, state.receive);
    try testing.expectEqualDeep(credits, state.credits);
}

test "WebTransport session control nonincreasing and oversized MAX capsules are flow errors" {
    var state = try control.State.init(.{ .data = 5 }, .{ .data = 3, .streams_bidi = 2, .streams_uni = 1 }, .{});
    const before = state;
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .max_data = 3 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .max_data = 2 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .max_data = max_data + 1 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .max_streams_bidi = 2 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .max_streams_uni = max_streams + 1 }));
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control blocked capsules validate typed wire bounds without granting" {
    var state = try control.State.init(.{ .data = 5 }, .{ .data = 3 }, .{});
    const before = state;
    try testing.expectEqual(control.CapsuleAction.peer_blocked, try state.apply_capsule(.{ .data_blocked = max_data }));
    try testing.expectEqual(control.CapsuleAction.peer_blocked, try state.apply_capsule(.{ .streams_blocked_bidi = max_streams }));
    try testing.expectEqual(control.CapsuleAction.peer_blocked, try state.apply_capsule(.{ .streams_blocked_uni = max_streams }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .data_blocked = max_data + 1 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .streams_blocked_bidi = max_streams + 1 }));
    try testing.expectError(error.FlowControlViolation, state.apply_capsule(.{ .streams_blocked_uni = max_streams + 1 }));
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control lifecycle and extension capsules remain with CONNECT owner" {
    var state = try control.State.init(.{ .data = 5 }, .{ .data = 3 }, .{});
    const before = state;
    try testing.expectEqual(control.CapsuleAction.ignored, try state.apply_capsule(.drain_session));
    try testing.expectEqual(control.CapsuleAction.ignored, try state.apply_capsule(.{ .close_session = .{ .application_error = 7, .message = "closed" } }));
    try testing.expectEqual(control.CapsuleAction.ignored, try state.apply_capsule(.{ .unknown = .{ .capsule_type = 123, .payload = "extension" } }));
    try testing.expectEqualDeep(before, state);
}

test "WebTransport session control transitions are comptime pure" {
    comptime {
        var state = try control.State.init(.{ .data = 3, .streams_uni = 1 }, .{ .data = 4, .streams_bidi = 1 }, .{});
        try state.send.commit_open(.bidi);
        try state.send.commit_data(2);
        try state.apply_receive(.{ .used = .{ .data = 3, .streams_uni = 1 } });
        try state.apply_receive(.{ .reclaimed = .{ .data = 3, .streams_uni = 1 } });
        const bytes = state.credits.prepare(&state.receive).?;
        try state.credits.advance(&state.receive, bytes.len);
        try testing.expectEqual(@as(u64, 6), state.receive.budget.limits.data);
        try testing.expectEqual(control.CapsuleAction.data_credit, try state.apply_capsule(.{ .max_data = 5 }));
        try testing.expectEqual(@as(u64, 2), state.send.used.data);
    }
}
