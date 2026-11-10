const std = @import("std");
const multipart = @import("test_support").multipart;

const logical_length = 100_000_000;
const opening = "--large\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"big.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n";
const closing = "\r\n--large--\r\n";
const payload_length = logical_length - opening.len - closing.len;
const hash_offset = 0xcbf29ce484222325;
const hash_prime = 0x100000001b3;

const Proof = struct {
    sink: [127]u8 = undefined,
    payload_count: usize = 0,
    begin_count: usize = 0,
    end_count: usize = 0,
    hash: u64 = hash_offset,
    calls: usize = 0,
};

test "multipart: 100000000 logical bytes use fixed small blocks and bounded slow sink" {
    var headers: [258]u8 = @splat(0xab);
    var carry: [11]u8 = @splat(0xcd);
    var parser = try multipart.StreamingParser.init("large", .{
        .max_body_bytes = logical_length,
        .max_parts = 1,
        .max_part_headers = 2,
    }, .{ .headers = headers[1..257], .carry = carry[1..10] });
    var proof = Proof{};
    try feed(&parser, opening, &proof);
    var block: [4096]u8 = undefined;
    var generated: usize = 0;
    var expected_hash: u64 = hash_offset;
    while (generated < payload_length) {
        const count = @min(block.len, payload_length - generated);
        for (block[0..count], generated..) |*byte, offset| {
            byte.* = expected_byte(offset);
            expected_hash = (expected_hash ^ byte.*) *% hash_prime;
        }
        try feed(&parser, block[0..count], &proof);
        @memset(&block, 0xee);
        generated += count;
    }
    try feed(&parser, closing, &proof);
    try parser.finish();
    try std.testing.expectEqual(@as(u64, logical_length), parser.total_bytes);
    try std.testing.expectEqual(@as(usize, payload_length), proof.payload_count);
    try std.testing.expectEqual(@as(usize, 1), proof.begin_count);
    try std.testing.expectEqual(@as(usize, 1), proof.end_count);
    try std.testing.expectEqual(expected_hash, proof.hash);
    try std.testing.expect(payload_length > 64 * 1024 * 1024);
    try std.testing.expectEqual(@as(u8, 0xab), headers[0]);
    try std.testing.expectEqual(@as(u8, 0xab), headers[257]);
    try std.testing.expectEqual(@as(u8, 0xcd), carry[0]);
    try std.testing.expectEqual(@as(u8, 0xcd), carry[10]);
    try std.testing.expectEqual(@as(usize, 9), parser.storage.carry.len);
    try std.testing.expectError(error.InvalidMultipartState, parser.next(""));
    try std.testing.expectError(error.InvalidMultipartState, parser.finish());
}

fn expected_byte(offset: usize) u8 {
    return @as(u8, @intCast(offset % 23)) + 'a';
}

fn feed(parser: *multipart.StreamingParser, input: []const u8, proof: *Proof) !void {
    var banks: [2][4096]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        proof.calls += 1;
        const current = &banks[proof.calls % banks.len];
        const remaining = input[offset..];
        try std.testing.expect(remaining.len <= current.len);
        @memcpy(current[0..remaining.len], remaining);
        const step = try parser.next(current[0..remaining.len]);
        try std.testing.expect(step.consumed <= remaining.len);
        offset += step.consumed;
        if (step.event) |event| try accept_event(parser, event, &offset, proof);
        @memset(current, 0xdd);
        try std.testing.expect(offset <= input.len);
        try std.testing.expect(parser.total_bytes <= logical_length);
        if (step.event != null) continue;
        try std.testing.expectEqual(input.len, offset);
        return;
    }
}

fn accept_event(parser: *multipart.StreamingParser, event: multipart.StreamingEvent, offset: *usize, proof: *Proof) !void {
    switch (event) {
        .part_begin => |metadata| {
            proof.begin_count += 1;
            try std.testing.expectEqual(@as(usize, 1), proof.begin_count);
            try std.testing.expectEqualStrings("upload", metadata.name);
            try std.testing.expectEqualStrings("big.bin", metadata.filename orelse return error.TestUnexpectedResult);
            try std.testing.expectEqualStrings("application/octet-stream", metadata.content_type orelse return error.TestUnexpectedResult);
        },
        .part_data => |payload| {
            try std.testing.expect(payload.len != 0);
            const count = if (proof.calls % 11 == 0) 0 else @min(payload.len, proof.sink.len);
            @memcpy(proof.sink[0..count], payload[0..count]);
            for (proof.sink[0..count]) |byte| {
                try std.testing.expectEqual(expected_byte(proof.payload_count), byte);
                proof.payload_count += 1;
                proof.hash = (proof.hash ^ byte) *% hash_prime;
            }
            offset.* += try parser.accept_data(count);
            @memset(&proof.sink, 0xff);
        },
        .part_end => {
            proof.end_count += 1;
            try std.testing.expectEqual(@as(usize, 1), proof.end_count);
            try std.testing.expectEqual(@as(usize, payload_length), proof.payload_count);
        },
    }
}
