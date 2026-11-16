const std = @import("std");
const child = @import("test_support").webtransport_child_ledger;
const testing = std.testing;
const max_varint: u64 = (1 << 62) - 1;

test "WebTransport child ledger validates complete receive snapshots" {
    try testing.expect(child.snapshot_valid(.{}));
    try testing.expect(child.snapshot_valid(.{ .read_cancelled = true, .stop_error = max_varint }));
    try testing.expect(child.snapshot_valid(.{ .final_size = max_varint, .reliable_size = max_varint, .fin_received = true }));
    try testing.expect(child.snapshot_valid(.{ .final_size = 10, .reliable_size = 2, .reset_error = 7, .fin_received = true }));
    const invalid = [_]child.ReceiveSnapshot{
        .{ .final_size = 0 },
        .{ .reliable_size = 0 },
        .{ .final_size = 1, .reliable_size = 2 },
        .{ .final_size = max_varint + 1, .reliable_size = 0 },
        .{ .stop_error = max_varint + 1 },
        .{ .reset_error = 1 },
        .{ .reset_visible = true },
        .{ .fin_received = true },
        .{ .final_size = 10, .reliable_size = 2, .fin_received = true },
    };
    for (invalid) |snapshot| try testing.expect(!child.snapshot_valid(snapshot));
}

test "WebTransport child ledger requires an actual receive prefix length" {
    for ([_]u8{ 1, 2, 17, 255 }) |prefix| try testing.expectError(error.InvalidPrefix, child.Ledger.init(prefix));
    for ([_]u8{ 0, 3, 16 }) |prefix| {
        const ledger = try child.Ledger.init(prefix);
        try testing.expectEqual(prefix, ledger.receive_prefix_size);
    }
}

test "WebTransport child ledger accounts final payload gap once" {
    var ledger = try child.Ledger.init(16);
    try testing.expectEqual(child.AccountingDelta{ .accounted_bytes = 4 }, try ledger.record_read(4));
    const snapshot: child.ReceiveSnapshot = .{ .final_size = 25, .reliable_size = 25, .fin_received = true };
    try testing.expectEqual(child.AccountingDelta{ .accounted_bytes = 5, .final_gap_bytes = 5 }, try ledger.observe(snapshot));
    try testing.expectEqual(@as(?u64, 25), ledger.final_size);
    try testing.expectEqual(@as(?u64, 9), ledger.final_payload_size);
    try testing.expectEqual(child.AccountingDelta{}, try ledger.observe(snapshot));
    try testing.expectEqual(child.AccountingDelta{}, try ledger.record_read(5));
    try testing.expectEqual(@as(u64, 9), ledger.payload_read);
    try testing.expectEqual(@as(u64, 9), ledger.accounted_bytes);
}

test "WebTransport child ledger local receive half excludes no send prefix" {
    var ledger = try child.Ledger.init(0);
    try testing.expectEqual(child.AccountingDelta{ .accounted_bytes = 9, .final_gap_bytes = 9 }, try ledger.observe(.{
        .final_size = 9,
        .reliable_size = 9,
        .fin_received = true,
    }));
    try testing.expectEqual(@as(?u64, 9), ledger.final_payload_size);
}

test "WebTransport child ledger unknown final and local cancellation remain distinct from close" {
    var ledger = try child.Ledger.init(3);
    _ = try ledger.record_read(2);
    try testing.expectEqual(child.AccountingDelta{}, try ledger.observe(.{ .read_cancelled = true }));
    try testing.expectEqual(@as(?u64, null), ledger.final_size);
    try testing.expect(!ledger.closed);
    try testing.expectEqual(child.CloseState.abandoned, ledger.close());
    try testing.expectEqual(child.CloseState.abandoned, ledger.close());
    try testing.expectEqual(@as(?u64, null), ledger.final_payload_size);
    try testing.expectError(error.Closed, ledger.observe(.{}));
    try testing.expectError(error.Closed, ledger.record_read(0));
    try testing.expectError(error.Closed, ledger.record_eof());
}

test "WebTransport child ledger invalid final observations preserve all state" {
    var ledger = try child.Ledger.init(3);
    _ = try ledger.record_read(4);
    const before = ledger;
    try testing.expectError(error.FinalSizeBelowPrefix, ledger.observe(.{ .final_size = 2, .reliable_size = 2 }));
    try testing.expectEqualDeep(before, ledger);
    try testing.expectError(error.FinalSizeBelowRead, ledger.observe(.{ .final_size = 6, .reliable_size = 6 }));
    try testing.expectEqualDeep(before, ledger);
    try testing.expectError(error.InvalidSnapshot, ledger.observe(.{ .reset_visible = true }));
    try testing.expectEqualDeep(before, ledger);
    _ = try ledger.observe(.{ .final_size = 9, .reliable_size = 9 });
    const known = ledger;
    try testing.expectError(error.FinalSizeChanged, ledger.observe(.{ .final_size = 10, .reliable_size = 10 }));
    try testing.expectEqualDeep(known, ledger);
    try testing.expectError(error.FinalSizeBelowRead, ledger.record_read(3));
    try testing.expectEqualDeep(known, ledger);
}

test "WebTransport child ledger bounds reads including receive prefix without wrapping" {
    var ledger = try child.Ledger.init(3);
    _ = try ledger.record_read(max_varint - 3);
    const before = ledger;
    try testing.expectError(error.SizeOverflow, ledger.record_read(1));
    try testing.expectEqualDeep(before, ledger);
    try testing.expectEqual(child.AccountingDelta{}, try ledger.observe(.{ .final_size = max_varint, .reliable_size = max_varint }));
}

test "WebTransport child ledger reset visibility is separate from final accounting" {
    var ledger = try child.Ledger.init(3);
    _ = try ledger.record_read(2);
    const known: child.ReceiveSnapshot = .{ .final_size = 13, .reliable_size = 7, .reset_error = max_varint };
    try testing.expectEqual(child.AccountingDelta{ .accounted_bytes = 8, .final_gap_bytes = 8 }, try ledger.observe(known));
    try testing.expectEqual(@as(?u64, null), ledger.take_reset());
    _ = try ledger.observe(.{ .final_size = 13, .reliable_size = 4, .reset_error = max_varint, .reset_visible = true });
    try testing.expectEqual(@as(?u64, 4), ledger.reliable_size);
    try testing.expectEqual(@as(?u64, max_varint), ledger.take_reset());
    try testing.expectEqual(@as(?u64, null), ledger.take_reset());
    try testing.expectError(error.IncompleteEof, ledger.record_eof());
    try testing.expectEqual(child.CloseState.final_known, ledger.close());
}

test "WebTransport child ledger FIN alone does not deliver EOF" {
    var ledger = try child.Ledger.init(0);
    _ = try ledger.observe(.{ .final_size = 3, .reliable_size = 3, .fin_received = true });
    try testing.expectEqual(child.ReceiveTerminal.none, ledger.receive_terminal);
    try testing.expectError(error.IncompleteEof, ledger.record_eof());
    _ = try ledger.record_read(3);
    try testing.expect(try ledger.record_eof());
    try testing.expect(!try ledger.record_eof());
    _ = try ledger.observe(.{ .final_size = 3, .reliable_size = 0, .reset_error = 5, .reset_visible = true, .stop_error = 9 });
    try testing.expectEqual(@as(?u64, null), ledger.take_reset());
    try testing.expectEqual(@as(?u64, 9), ledger.take_stop());
    try testing.expectEqual(@as(?u64, null), ledger.take_stop());
    try testing.expectError(error.ReceiveComplete, ledger.record_read(1));
}

test "WebTransport child ledger reset terminal prevents a second EOF notification" {
    var ledger = try child.Ledger.init(0);
    _ = try ledger.record_read(3);
    _ = try ledger.observe(.{ .final_size = 3, .reliable_size = 3, .reset_error = 12, .reset_visible = true });
    try testing.expectEqual(@as(?u64, 12), ledger.take_reset());
    try testing.expect(!try ledger.record_eof());
    _ = try ledger.observe(.{ .stop_error = 0 });
    try testing.expectEqual(@as(?u64, 0), ledger.take_stop());
}

test "WebTransport child ledger STOP can arrive while final remains unknown" {
    var ledger = try child.Ledger.init(0);
    _ = try ledger.observe(.{ .stop_error = max_varint });
    try testing.expectEqual(@as(?u64, max_varint), ledger.take_stop());
    _ = try ledger.observe(.{ .stop_error = max_varint });
    try testing.expectEqual(@as(?u64, null), ledger.take_stop());
    try testing.expectEqual(@as(?u64, null), ledger.final_size);
    try testing.expectEqual(child.ReceiveTerminal.none, ledger.receive_terminal);
}

test "WebTransport child ledger conflicting error codes preserve state" {
    var ledger = try child.Ledger.init(0);
    _ = try ledger.observe(.{ .final_size = 8, .reliable_size = 7, .reset_error = 2, .stop_error = 3 });
    const before = ledger;
    try testing.expectError(error.ErrorCodeChanged, ledger.observe(.{ .final_size = 8, .reliable_size = 1, .reset_error = 4 }));
    try testing.expectEqualDeep(before, ledger);
    try testing.expectError(error.ErrorCodeChanged, ledger.observe(.{ .stop_error = 5 }));
    try testing.expectEqualDeep(before, ledger);
    _ = try ledger.observe(.{ .final_size = 8, .reliable_size = 1, .reset_error = 2 });
    _ = try ledger.observe(.{ .final_size = 8, .reliable_size = 6, .reset_error = 2 });
    try testing.expectEqual(@as(?u64, 1), ledger.reliable_size);
}
