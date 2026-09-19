const std = @import("std");
const support = @import("test_support");
const ring_module = support.datagram_ring;

const Datagram = ring_module.Datagram;
const DatagramRing = ring_module.DatagramRing;
const max_u32 = std.math.maxInt(u32);

test "datagram ring: fifo ordering survives cursor wraparound" {
    const capacity = 4;
    const stride = 4;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    var pushed: u64 = 0;
    var expected: u64 = 0;
    var step: usize = 0;
    // More total items than slots, so every slot is reused.
    while (step < capacity * 3 + 2) : (step += 1) {
        while (ring.is_full()) {
            const view = ring.pop().?;
            try std.testing.expectEqual(expected, view.sequence_number);
            try std.testing.expectEqual(expected + 1000, view.session_id);
            try std.testing.expectEqual(@as(usize, 2), view.payload.len);
            try std.testing.expectEqual(@as(u8, @truncate(expected)), view.payload[0]);
            expected += 1;
        }
        const payload = [2]u8{ @as(u8, @truncate(pushed)), 0xAB };
        try ring.push(Datagram{
            .session_id = pushed + 1000,
            .sequence_number = pushed,
            .payload = &payload,
        });
        pushed += 1;
    }

    while (ring.pop()) |view| {
        try std.testing.expectEqual(expected, view.sequence_number);
        try std.testing.expectEqual(@as(u8, @truncate(expected)), view.payload[0]);
        expected += 1;
    }

    try std.testing.expectEqual(pushed, expected);
    try std.testing.expect(ring.is_empty());
}

test "datagram ring: non-power-of-two capacity uses modulo indexing" {
    const capacity = 3;
    const stride = 2;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    var pushed: u64 = 0;
    var expected: u64 = 0;
    var step: usize = 0;
    while (step < 10) : (step += 1) {
        if (ring.is_full()) {
            const view = ring.pop().?;
            try std.testing.expectEqual(expected, view.sequence_number);
            try std.testing.expectEqual(@as(u8, @truncate(expected)), view.payload[1]);
            expected += 1;
        }
        const payload = [2]u8{ 0x5A, @as(u8, @truncate(pushed)) };
        try ring.push(.{
            .session_id = pushed + 7,
            .sequence_number = pushed,
            .payload = &payload,
        });
        pushed += 1;
    }

    while (ring.pop()) |view| {
        try std.testing.expectEqual(expected, view.sequence_number);
        try std.testing.expectEqual(@as(u8, @truncate(expected)), view.payload[1]);
        expected += 1;
    }

    try std.testing.expectEqual(pushed, expected);
    try std.testing.expect(ring.is_empty());
}

test "datagram ring: full rejection and drop-oldest policy track dropped" {
    const capacity = 3;
    const stride = 4;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    try ring.push(.{ .session_id = 10, .sequence_number = 0, .payload = "a" });
    try ring.push(.{ .session_id = 11, .sequence_number = 1, .payload = "b" });
    try ring.push(.{ .session_id = 12, .sequence_number = 2, .payload = "c" });

    try std.testing.expect(ring.is_full());
    try std.testing.expectEqual(@as(usize, capacity), ring.len());
    try std.testing.expectEqual(@as(u64, 0), ring.dropped);

    // Plain push never evicts and never counts a drop.
    try std.testing.expectError(
        error.Full,
        ring.push(.{ .session_id = 13, .sequence_number = 3, .payload = "d" }),
    );
    try std.testing.expectEqual(@as(u64, 0), ring.dropped);
    try std.testing.expectEqual(@as(u64, 0), ring.peek().?.sequence_number);

    // The caller may count a datagram it chose to discard.
    ring.note_dropped();
    try std.testing.expectEqual(@as(u64, 1), ring.dropped);

    // Drop-oldest makes room and counts the eviction separately.
    try ring.push_dropping_oldest(.{ .session_id = 13, .sequence_number = 3, .payload = "d" });
    try std.testing.expectEqual(@as(u64, 2), ring.dropped);
    try std.testing.expectEqual(@as(usize, capacity), ring.len());
    try std.testing.expectEqual(@as(u64, 1), ring.peek().?.sequence_number);

    try std.testing.expectEqual(@as(u64, 1), ring.pop().?.sequence_number);
    try std.testing.expectEqual(@as(u64, 2), ring.pop().?.sequence_number);
    try std.testing.expectEqual(@as(u64, 3), ring.pop().?.sequence_number);
    try std.testing.expect(ring.is_empty());
}

test "datagram ring: oversized payload is rejected without eviction" {
    const capacity = 2;
    const stride = 4;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    // Exactly the stride is accepted.
    try ring.push(.{ .session_id = 0, .sequence_number = 0, .payload = "abcd" });
    try ring.push(.{ .session_id = 1, .sequence_number = 1, .payload = "efgh" });
    try std.testing.expect(ring.is_full());

    const before = ring.peek().?;
    try std.testing.expectError(
        error.PayloadTooLarge,
        ring.push(.{ .session_id = 2, .sequence_number = 2, .payload = "abcde" }),
    );
    try std.testing.expectError(
        error.PayloadTooLarge,
        ring.push_dropping_oldest(.{ .session_id = 2, .sequence_number = 2, .payload = "abcde" }),
    );

    // Failed pushes leave the cursors, contents, and drop count untouched.
    try std.testing.expectEqual(@as(usize, capacity), ring.len());
    try std.testing.expectEqual(@as(u64, 0), ring.dropped);
    try std.testing.expectEqual(before.sequence_number, ring.peek().?.sequence_number);
    try std.testing.expectEqualStrings("abcd", ring.peek().?.payload);
}

test "datagram ring: invalid init geometry is rejected" {
    var session_ids: [4]u64 = undefined;
    var sequence_numbers: [4]u64 = undefined;
    var payload_lengths: [4]u32 = undefined;
    var payload_storage: [32]u8 = undefined;

    var short_sequences: [3]u64 = undefined;
    try std.testing.expectError(
        error.InvalidCapacity,
        DatagramRing.init(&session_ids, &short_sequences, &payload_lengths, &payload_storage, 8),
    );
    try std.testing.expectError(
        error.InvalidCapacity,
        DatagramRing.init(&session_ids, &sequence_numbers, payload_lengths[0..3], &payload_storage, 8),
    );

    var no_sessions: [0]u64 = .{};
    var no_numbers: [0]u64 = .{};
    var no_lengths: [0]u32 = .{};
    var no_bytes: [0]u8 = .{};
    try std.testing.expectError(
        error.InvalidCapacity,
        DatagramRing.init(&no_sessions, &no_numbers, &no_lengths, &no_bytes, 1),
    );

    try std.testing.expectError(
        error.InvalidStride,
        DatagramRing.init(&session_ids, &sequence_numbers, &payload_lengths, &payload_storage, 0),
    );
    // Four slots of nine bytes need 36 bytes, not 32.
    try std.testing.expectError(
        error.InvalidStride,
        DatagramRing.init(&session_ids, &sequence_numbers, &payload_lengths, &payload_storage, 9),
    );

    if (comptime @bitSizeOf(usize) > @bitSizeOf(u32)) {
        // A stride wider than a u32 payload length cannot be stored.
        try std.testing.expectError(
            error.InvalidStride,
            DatagramRing.init(
                &session_ids,
                &sequence_numbers,
                &payload_lengths,
                &payload_storage,
                @as(usize, max_u32) + 1,
            ),
        );
    }
}

test "datagram ring: zero-length payloads keep their metadata" {
    const capacity = 1;
    const stride = 1;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    try ring.push(.{ .session_id = 42, .sequence_number = 7, .payload = "" });
    try std.testing.expect(ring.is_full());

    const view = ring.peek().?;
    try std.testing.expectEqual(@as(u64, 42), view.session_id);
    try std.testing.expectEqual(@as(u64, 7), view.sequence_number);
    try std.testing.expectEqual(@as(usize, 0), view.payload.len);

    const popped = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 42), popped.session_id);
    try std.testing.expectEqual(@as(u64, 7), popped.sequence_number);
    try std.testing.expectEqual(@as(usize, 0), popped.payload.len);
    try std.testing.expect(ring.peek() == null);
}

test "datagram ring: metadata and payload storage stay disjoint" {
    const capacity = 2;
    const stride = 4;
    var session_ids: [capacity]u64 = .{ 0xDEAD, 0xBEEF };
    var sequence_numbers: [capacity]u64 = .{ 0xCAFE, 0xF00D };
    var payload_lengths: [capacity]u32 = .{ 0, 0 };
    var payload_storage: [capacity * stride]u8 = [_]u8{0xEE} ** (capacity * stride);

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    var source = [3]u8{ 0x11, 0x22, 0x33 };
    try ring.push(.{
        .session_id = 0x0123456789ABCDEF,
        .sequence_number = 0x7FEDCBA987654321,
        .payload = &source,
    });

    // Metadata lands in its own arrays.
    try std.testing.expectEqual(@as(u64, 0x0123456789ABCDEF), ring.session_ids[0]);
    try std.testing.expectEqual(@as(u64, 0x7FEDCBA987654321), ring.sequence_numbers[0]);
    try std.testing.expectEqual(@as(u32, 3), ring.payload_lengths[0]);

    // Payload bytes land only inside the stride region.
    try std.testing.expectEqualSlices(u8, &source, ring.payload_storage[0..3]);
    try std.testing.expectEqual(@as(u8, 0xEE), ring.payload_storage[3]);

    // Mutating the source buffer cannot change the queued copy.
    source[0] = 0x99;
    const view = ring.peek().?;
    try std.testing.expectEqual(@as(u8, 0x11), view.payload[0]);
    try std.testing.expectEqual(@intFromPtr(&payload_storage[0]), @intFromPtr(view.payload.ptr));

    // Mutating the payload slab cannot change metadata; the view still sees it.
    payload_storage[0] = 0x77;
    try std.testing.expectEqual(@as(u64, 0x0123456789ABCDEF), ring.session_ids[0]);
    try std.testing.expectEqual(@as(u64, 0x7FEDCBA987654321), ring.sequence_numbers[0]);
    try std.testing.expectEqual(@as(u8, 0x77), view.payload[0]);

    // Mutating metadata cannot change payload bytes.
    ring.session_ids[0] = 0;
    try std.testing.expectEqual(@as(u8, 0x77), ring.payload_storage[0]);
}

test "datagram ring: clear drains entries and keeps the drop counter" {
    const capacity = 2;
    const stride = 2;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    try ring.push(.{ .session_id = 0, .sequence_number = 0, .payload = "aa" });
    try ring.push(.{ .session_id = 1, .sequence_number = 1, .payload = "bb" });
    ring.note_dropped();

    ring.clear();
    try std.testing.expect(ring.is_empty());
    try std.testing.expectEqual(@as(usize, 0), ring.len());
    try std.testing.expectEqual(@as(u32, 0), ring.head);
    try std.testing.expectEqual(@as(u32, 0), ring.tail);
    try std.testing.expectEqual(@as(u64, 1), ring.dropped);
    try std.testing.expect(ring.pop() == null);

    // Slots are reusable after clear.
    try ring.push(.{ .session_id = 2, .sequence_number = 2, .payload = "cc" });
    try std.testing.expectEqual(@as(u64, 2), ring.pop().?.sequence_number);
}

test "datagram ring: u32 cursors wrap across maxInt(u32)" {
    const capacity = 2;
    const stride = 2;
    var session_ids: [capacity]u64 = undefined;
    var sequence_numbers: [capacity]u64 = undefined;
    var payload_lengths: [capacity]u32 = undefined;
    var payload_storage: [capacity * stride]u8 = undefined;

    var ring = try DatagramRing.init(
        &session_ids,
        &sequence_numbers,
        &payload_lengths,
        &payload_storage,
        stride,
    );

    // Position an empty ring one slot below the cursor wrap.
    ring.head = max_u32 - 1;
    ring.tail = max_u32 - 1;

    try ring.push(.{ .session_id = 0, .sequence_number = 0, .payload = "aa" });
    try ring.push(.{ .session_id = 1, .sequence_number = 1, .payload = "bb" });
    try std.testing.expect(ring.is_full());
    try std.testing.expectEqual(@as(u32, 0), ring.tail);

    const first = ring.peek().?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence_number);
    try std.testing.expectEqualStrings("aa", first.payload);

    const popped_first = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 0), popped_first.sequence_number);
    try std.testing.expectEqualStrings("aa", popped_first.payload);
    try std.testing.expectEqual(@as(u32, max_u32), ring.head);

    const popped_second = ring.pop().?;
    try std.testing.expectEqual(@as(u64, 1), popped_second.sequence_number);
    try std.testing.expectEqualStrings("bb", popped_second.payload);
    try std.testing.expectEqual(@as(u32, 0), ring.head);
    try std.testing.expect(ring.is_empty());
}
