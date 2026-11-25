const std = @import("std");
const capsule_stream = @import("test_support").webtransport_capsule_stream;

const close_capsule = "\x68\x43\x07\x01\x02\x03\x04bye";
const drain_capsule = "\x80\x00\x78\xae\x00";

fn expect_close(event: capsule_stream.Event) !void {
    switch (event) {
        .capsule => |capsule| switch (capsule) {
            .close_session => |close| {
                try std.testing.expectEqual(@as(u32, 0x01020304), close.application_error);
                try std.testing.expectEqualStrings("bye", close.message);
            },
            else => return error.UnexpectedCapsule,
        },
        else => return error.UnexpectedEvent,
    }
}

test "WebTransport capsule stream accepts every close capsule split" {
    for (0..close_capsule.len + 1) |split| {
        var decoder = capsule_stream.Decoder{};
        const first = try decoder.consume(close_capsule[0..split]);
        try std.testing.expectEqual(split, first.consumed);
        if (split == close_capsule.len) {
            try expect_close(first.event.?);
        } else {
            try std.testing.expect(first.event == null);
            const second = try decoder.consume(close_capsule[split..]);
            try std.testing.expectEqual(close_capsule.len - split, second.consumed);
            try expect_close(second.event.?);
        }
        try decoder.finish();
    }
}

test "WebTransport capsule stream preserves nonminimal field and payload varints" {
    const encoded = "\x99\x0b\x4d\x3d\x80\x00\x00\x08\xc0\x00\x00\x00\x00\x00\x00\x25";
    var decoder = capsule_stream.Decoder{};
    for (encoded, 0..) |byte, index| {
        const piece = [_]u8{byte};
        const result = try decoder.consume(&piece);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
        if (index + 1 != encoded.len) {
            try std.testing.expect(result.event == null);
            continue;
        }
        try std.testing.expectEqual(@as(u64, 37), result.event.?.capsule.max_data);
    }
    try decoder.finish();

    const nonminimal_close = "\xc0\x00\x00\x00\x00\x00\x28\x43\x80\x00\x00\x07\x01\x02\x03\x04bye";
    const close_result = try decoder.consume(nonminimal_close);
    try std.testing.expectEqual(nonminimal_close.len, close_result.consumed);
    try expect_close(close_result.event.?);
    try decoder.finish();
}

test "WebTransport capsule stream returns one event per concatenated capsule" {
    const bytes = drain_capsule ++ close_capsule ++ drain_capsule;
    var decoder = capsule_stream.Decoder{};
    const first = try decoder.consume(bytes);
    try std.testing.expectEqual(drain_capsule.len, first.consumed);
    try std.testing.expect(first.event.?.capsule == .drain_session);
    const second = try decoder.consume(bytes[first.consumed..]);
    try std.testing.expectEqual(close_capsule.len, second.consumed);
    try expect_close(second.event.?);
    const third = try decoder.consume(bytes[first.consumed + second.consumed ..]);
    try std.testing.expectEqual(drain_capsule.len, third.consumed);
    try std.testing.expect(third.event.?.capsule == .drain_session);
    const empty = try decoder.consume("");
    try std.testing.expectEqual(@as(usize, 0), empty.consumed);
    try std.testing.expect(empty.event == null);
    try decoder.finish();
}

test "WebTransport capsule stream reports unknown type before skipping payload" {
    var decoder = capsule_stream.Decoder{};
    const first = try decoder.consume("\x21\x03abc" ++ drain_capsule);
    try std.testing.expectEqual(@as(usize, 2), first.consumed);
    try std.testing.expectEqual(@as(u64, 0x21), first.event.?.unknown);
    try std.testing.expectError(error.TruncatedCapsule, decoder.finish());
    const second = try decoder.consume("ab");
    try std.testing.expectEqual(@as(usize, 2), second.consumed);
    try std.testing.expect(second.event == null);
    const third = try decoder.consume("c" ++ drain_capsule);
    try std.testing.expectEqual(@as(usize, 1 + drain_capsule.len), third.consumed);
    try std.testing.expect(third.event.?.capsule == .drain_session);
    try decoder.finish();
}

test "WebTransport capsule stream zero length unknown advances without another event" {
    var decoder = capsule_stream.Decoder{};
    const first = try decoder.consume("\x21\x00" ++ close_capsule);
    try std.testing.expectEqual(@as(usize, 2), first.consumed);
    try std.testing.expectEqual(@as(u64, 0x21), first.event.?.unknown);
    try decoder.finish();
    const second = try decoder.consume(close_capsule);
    try std.testing.expectEqual(close_capsule.len, second.consumed);
    try expect_close(second.event.?);
    try decoder.finish();
}

const GuardedDecoder = struct {
    before: [32]u8 = .{0xa5} ** 32,
    decoder: capsule_stream.Decoder = .{},
    after: [32]u8 = .{0x5a} ** 32,
};

test "WebTransport capsule stream skips unbounded unknown payload with fixed storage" {
    try std.testing.expect(@sizeOf(capsule_stream.Decoder) <= 1280);
    var guarded = GuardedDecoder{};
    const header = try guarded.decoder.consume("\x21\xff\xff\xff\xff\xff\xff\xff\xff");
    try std.testing.expectEqual(@as(usize, 9), header.consumed);
    try std.testing.expectEqual(@as(u64, 0x21), header.event.?.unknown);
    const bytes = [_]u8{0xcc} ** 64;
    for (0..4096) |_| {
        const chunk = try guarded.decoder.consume(&bytes);
        try std.testing.expectEqual(bytes.len, chunk.consumed);
        try std.testing.expect(chunk.event == null);
    }
    try std.testing.expectError(error.TruncatedCapsule, guarded.decoder.finish());
    try std.testing.expectEqualSlices(u8, &(.{0xa5} ** 32), &guarded.before);
    try std.testing.expectEqualSlices(u8, &(.{0x5a} ** 32), &guarded.after);
}

test "WebTransport capsule stream detects EOF in every incomplete close prefix" {
    for (1..close_capsule.len) |length| {
        var decoder = capsule_stream.Decoder{};
        const result = try decoder.consume(close_capsule[0..length]);
        try std.testing.expectEqual(length, result.consumed);
        try std.testing.expect(result.event == null);
        try std.testing.expectError(error.TruncatedCapsule, decoder.finish());
    }
    var empty = capsule_stream.Decoder{};
    try empty.finish();
}

const InvalidCapsule = struct {
    bytes: []const u8,
    expected: capsule_stream.Error,
};

test "WebTransport capsule stream rejects oversized known payload from its header" {
    const cases = [_][]const u8{
        "\x68\x43\x44\x05",
        "\x80\x00\x78\xae\x01",
        "\x99\x0b\x4d\x3d\x09",
    };
    for (cases) |bytes| {
        var decoder = capsule_stream.Decoder{};
        try std.testing.expectError(error.InvalidLength, decoder.consume(bytes));
        try std.testing.expectError(error.DecoderFailed, decoder.consume(drain_capsule));
        try std.testing.expectError(error.DecoderFailed, decoder.finish());
    }
}

test "WebTransport capsule stream preserves complete known codec validation errors" {
    const cases = [_]InvalidCapsule{
        .{ .bytes = "\x68\x43\x05\x00\x00\x00\x00\xff", .expected = error.InvalidUtf8 },
        .{ .bytes = "\x99\x0b\x4d\x3d\x02\x00\x01", .expected = error.InvalidLength },
        .{ .bytes = "\x99\x0b\x4d\x3d\x01\x40", .expected = error.NeedMoreData },
        .{ .bytes = "\x99\x0b\x4d\x3f\x08\xd0\x00\x00\x00\x00\x00\x00\x01", .expected = error.InvalidStreamLimit },
    };
    for (cases) |case| {
        var decoder = capsule_stream.Decoder{};
        try std.testing.expectError(case.expected, decoder.consume(case.bytes));
        try std.testing.expectError(error.DecoderFailed, decoder.finish());
    }
}

test "WebTransport capsule stream preserves full width data and stream limits" {
    var decoder = capsule_stream.Decoder{};
    const data = try decoder.consume("\x99\x0b\x4d\x3d\x08\xff\xff\xff\xff\xff\xff\xff\xff");
    try std.testing.expectEqual((@as(u64, 1) << 62) - 1, data.event.?.capsule.max_data);
    const streams = try decoder.consume("\x99\x0b\x4d\x40\x08\xd0\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectEqual(@as(u64, 1) << 60, streams.event.?.capsule.max_streams_uni);
    try decoder.finish();
}

test "WebTransport capsule stream carries maximum close payload with two eight byte fields" {
    const header = "\xc0\x00\x00\x00\x00\x00\x28\x43\xc0\x00\x00\x00\x00\x00\x04\x04";
    var encoded = [_]u8{'x'} ** (16 + 4 + 1024);
    @memcpy(encoded[0..header.len], header);
    @memset(encoded[header.len..][0..4], 0);
    var decoder = capsule_stream.Decoder{};
    for (encoded, 0..) |byte, index| {
        const piece = [_]u8{byte};
        const result = try decoder.consume(&piece);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
        if (index + 1 != encoded.len) {
            try std.testing.expect(result.event == null);
            try std.testing.expectError(error.TruncatedCapsule, decoder.finish());
            continue;
        }
        const close = result.event.?.capsule.close_session;
        try std.testing.expectEqual(@as(u32, 0), close.application_error);
        try std.testing.expectEqualSlices(u8, &(.{'x'} ** 1024), close.message);
    }
    try decoder.finish();
}

const flow_capsule_types = [_][4]u8{
    .{ 0x99, 0x0b, 0x4d, 0x3d },
    .{ 0x99, 0x0b, 0x4d, 0x3f },
    .{ 0x99, 0x0b, 0x4d, 0x40 },
    .{ 0x99, 0x0b, 0x4d, 0x41 },
    .{ 0x99, 0x0b, 0x4d, 0x43 },
    .{ 0x99, 0x0b, 0x4d, 0x44 },
};

test "WebTransport capsule stream disabled flow control skips malformed payload semantics" {
    for (flow_capsule_types) |encoded_type| {
        const capsule_type = @as(u64, encoded_type[0] & 0x3f) << 24 |
            @as(u64, encoded_type[1]) << 16 | @as(u64, encoded_type[2]) << 8 | encoded_type[3];
        var decoder = capsule_stream.Decoder.init(.{ .ignore_flow_control = true });
        var malformed = [_]u8{0xff} ** 14;
        @memcpy(malformed[0..4], &encoded_type);
        malformed[4] = 9;
        const ignored = try decoder.consume(&malformed);
        try std.testing.expectEqual(@as(usize, 5), ignored.consumed);
        try std.testing.expectEqual(capsule_type, ignored.event.?.unknown);
        const payload = try decoder.consume(malformed[5..]);
        try std.testing.expectEqual(@as(usize, 9), payload.consumed);
        try std.testing.expect(payload.event == null);
        try decoder.finish();
        const close = try decoder.consume(close_capsule);
        try expect_close(close.event.?);
        try decoder.finish();
    }
}

test "WebTransport capsule stream ignored excessive stream limit preserves next capsule" {
    var decoder = capsule_stream.Decoder.init(.{ .ignore_flow_control = true });
    const excessive = "\x99\x0b\x4d\x3f\x08\xd0\x00\x00\x00\x00\x00\x00\x01";
    const bytes = excessive ++ close_capsule;
    const first = try decoder.consume(bytes);
    try std.testing.expectEqual(@as(usize, 5), first.consumed);
    try std.testing.expectEqual(@as(u64, 0x190b4d3f), first.event.?.unknown);
    const second = try decoder.consume(bytes[first.consumed..]);
    try std.testing.expectEqual(@as(usize, 8 + close_capsule.len), second.consumed);
    try expect_close(second.event.?);
    try decoder.finish();

    var strict = capsule_stream.Decoder.init(.{});
    try std.testing.expectError(error.InvalidStreamLimit, strict.consume(excessive));
}

test "WebTransport capsule stream ignored flow lengths remain unbounded and framed" {
    for (flow_capsule_types) |encoded_type| {
        var decoder = capsule_stream.Decoder.init(.{ .ignore_flow_control = true });
        const maximum_length = "\xff\xff\xff\xff\xff\xff\xff\xff";
        var header: [12]u8 = undefined;
        @memcpy(header[0..4], &encoded_type);
        @memcpy(header[4..], maximum_length);
        const ignored = try decoder.consume(&header);
        try std.testing.expectEqual(header.len, ignored.consumed);
        try std.testing.expect(ignored.event.? == .unknown);
        const payload = [_]u8{0xaa} ** 64;
        const skipped = try decoder.consume(&payload);
        try std.testing.expectEqual(payload.len, skipped.consumed);
        try std.testing.expect(skipped.event == null);
        try std.testing.expectError(error.TruncatedCapsule, decoder.finish());
    }
}

test "WebTransport capsule stream ignored flow accepts nonminimal framing and empty payload" {
    const ignored_capsule = "\xc0\x00\x00\x00\x19\x0b\x4d\x40\x80\x00\x00\x00";
    var decoder = capsule_stream.Decoder.init(.{ .ignore_flow_control = true });
    for (ignored_capsule, 0..) |byte, index| {
        const piece = [_]u8{byte};
        const result = try decoder.consume(&piece);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
        if (index + 1 != ignored_capsule.len) {
            try std.testing.expect(result.event == null);
            continue;
        }
        try std.testing.expectEqual(@as(u64, 0x190b4d40), result.event.?.unknown);
    }
    try decoder.finish();
    const close = try decoder.consume(close_capsule);
    try expect_close(close.event.?);
    try decoder.finish();
}

test "WebTransport capsule stream reports HTTP2 only capsule types in ignore mode" {
    const types = [_][4]u8{
        .{ 0x99, 0x0b, 0x4d, 0x3e },
        .{ 0x99, 0x0b, 0x4d, 0x42 },
    };
    for (types) |encoded_type| {
        var decoder = capsule_stream.Decoder.init(.{ .ignore_flow_control = true });
        var header: [5]u8 = undefined;
        @memcpy(header[0..4], &encoded_type);
        header[4] = 1;
        const result = try decoder.consume(&header);
        try std.testing.expectEqual(header.len, result.consumed);
        try std.testing.expectEqual(@as(u64, 0x190b4d00) | encoded_type[3], result.event.?.unknown);
        try std.testing.expectError(error.TruncatedCapsule, decoder.finish());
    }
}
