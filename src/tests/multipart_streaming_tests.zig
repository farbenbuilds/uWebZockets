const std = @import("std");
const multipart = @import("test_support").public_api.multipart;
const Parser = multipart.StreamingParser;
const limits = multipart.StreamingLimits{ .max_body_bytes = 4096, .max_parts = 4, .max_part_headers = 4 };
const header = "Content-Disposition: form-data; name=\"upload\"";
const entity = "--abc\r\n" ++ header ++ "\r\n\r\nhello\r\n--abc--";

/// Captures each event before its borrow expires.
const Capture = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    replays: usize = 0,

    fn consume(self: *Capture, parser: *Parser, input: []const u8, acknowledge: usize) !usize {
        const step = try parser.next(input);
        var consumed = step.consumed;
        const event = step.event orelse return consumed;
        switch (event) {
            .part_begin => |meta| {
                try std.testing.expectEqualStrings("upload", meta.name);
                self.begins += 1;
            },
            .part_end => self.ends += 1,
            .part_data => |data| {
                try std.testing.expect(data.len > 0);
                const accepted = @min(data.len, acknowledge);
                @memcpy(self.bytes[self.len..][0..accepted], data[0..accepted]);
                self.len += accepted;
                const advanced = try parser.accept_data(accepted);
                if (advanced == 0 and accepted > 0) self.replays += 1;
                consumed += advanced;
            },
        }
        return consumed;
    }
};

fn run_split(boundary: []const u8, body: []const u8, split: usize, expected: []const u8) !void {
    var headers: [1024]u8 = undefined;
    var carry: [76]u8 = @splat(0xa5);
    var parser = try Parser.init(boundary, limits, .{ .headers = &headers, .carry = carry[1..][0 .. boundary.len + 4] });
    var capture = Capture{};
    var offset: usize = 0;
    var turns: usize = 0;
    while (offset < body.len) : (turns += 1) {
        try std.testing.expect(turns < body.len * 8 + 8);
        const end = if (offset < split) split else body.len;
        offset += try capture.consume(&parser, body[offset..end], 1);
    }
    try parser.finish();
    try std.testing.expectEqualStrings(expected, capture.bytes[0..capture.len]);
    try std.testing.expectEqual(@as(usize, 1), capture.begins);
    try std.testing.expectEqual(capture.begins, capture.ends);
    try std.testing.expectEqual(@as(u8, 0xa5), carry[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), carry[boundary.len + 5]);
    try std.testing.expectEqual(@as(u64, body.len), parser.total_bytes);
}

test "multipart streaming: every split borrows exact data with minimum carry" {
    for (0..entity.len + 1) |split| try run_split("abc", entity, split, "hello");
}

test "multipart streaming: boundary lengths one and seventy" {
    const one = "--x\r\n" ++ header ++ "\r\n\r\nx\r\n--x--";
    for (0..one.len + 1) |split| try run_split("x", one, split, "x");
    const boundary = "0123456789012345678901234567890123456789012345678901234567890123456789";
    const long = "--" ++ boundary ++ "\r\n" ++ header ++ "\r\n\r\nz\r\n--" ++ boundary ++ "--";
    for (0..long.len + 1) |split| try run_split(boundary, long, split, "z");
}

test "multipart streaming: false delimiter prefixes and overlapping CRLF stay payload" {
    const payload = "a\r\n--abcX\r\r\n--abc\rX\r\n--abc-X\r\n--ab\r\n--abXz";
    const body = "--abc\r\n" ++ header ++ "\r\n\r\n" ++ payload ++ "\r\n--abc--";
    for (0..body.len + 1) |split| try run_split("abc", body, split, payload);
}

test "multipart streaming: storage and configuration fail before input" {
    var headers: [1]u8 = undefined;
    var carry: [7]u8 = undefined;
    try std.testing.expectError(error.InvalidMultipartStorage, Parser.init("abc", limits, .{ .headers = &headers, .carry = carry[0..6] }));
    try std.testing.expectError(error.InvalidMultipartStorage, Parser.init("abc", limits, .{ .headers = headers[0..0], .carry = &carry }));
    try std.testing.expectError(error.InvalidMultipartBoundary, Parser.init("", limits, .{ .headers = &headers, .carry = &carry }));
    try std.testing.expectError(error.InvalidMultipartBoundary, Parser.init("abc ", limits, .{ .headers = &headers, .carry = &carry }));
    var invalid = limits;
    invalid.max_parts = 0;
    try std.testing.expectError(error.InvalidMultipartLimits, Parser.init("abc", invalid, .{ .headers = &headers, .carry = &carry }));
    invalid = limits;
    invalid.max_part_headers = 0;
    try std.testing.expectError(error.InvalidMultipartLimits, Parser.init("abc", invalid, .{ .headers = &headers, .carry = &carry }));
}

fn drain(parser: *Parser, input: []const u8) !void {
    var offset: usize = 0;
    var turns: usize = 0;
    while (offset < input.len) : (turns += 1) {
        try std.testing.expect(turns < input.len * 8 + 8);
        const step = try parser.next(input[offset..]);
        offset += step.consumed;
        const event = step.event orelse continue;
        switch (event) {
            .part_data => |data| offset += try parser.accept_data(data.len),
            .part_begin, .part_end => {},
        }
    }
}

fn expect_terminal(parser: *Parser) !void {
    try std.testing.expectError(error.InvalidMultipartState, parser.next(""));
    try std.testing.expectError(error.InvalidMultipartState, parser.accept_data(0));
    try std.testing.expectError(error.InvalidMultipartState, parser.finish());
}

test "multipart streaming: every incomplete prefix fails closed exactly once" {
    for (0..entity.len) |end| {
        var headers: [256]u8 = undefined;
        var carry: [7]u8 = undefined;
        var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
        try drain(&parser, entity[0..end]);
        try std.testing.expectError(error.IncompleteMultipartBody, parser.finish());
        try expect_terminal(&parser);
    }
    var headers: [256]u8 = undefined;
    var carry: [7]u8 = undefined;
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    try drain(&parser, entity);
    try parser.finish();
    try expect_terminal(&parser);
}

test "multipart streaming: present empty names and quoted metadata decode within header storage" {
    const body = "--abc\r\nContent-Disposition: form-data; name=\"\"; filename=\"a;b\\\"c\\\\d\"\r\nContent-Type: application/octet-stream\r\nX-Ignored: yes\r\n\r\n\r\n--abc--";
    for (0..body.len + 1) |split| {
        var headers: [256]u8 = undefined;
        var carry: [7]u8 = undefined;
        var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
        var offset: usize = 0;
        var began = false;
        var ended = false;
        while (offset < body.len) {
            const step = try parser.next(body[offset..if (offset < split) split else body.len]);
            offset += step.consumed;
            const event = step.event orelse continue;
            switch (event) {
                .part_begin => |meta| {
                    try std.testing.expect(!began);
                    began = true;
                    try std.testing.expectEqualStrings("", meta.name);
                    try std.testing.expectEqualStrings("a;b\"c\\d", meta.filename.?);
                    try std.testing.expectEqualStrings("application/octet-stream", meta.content_type.?);
                    const pointer = @intFromPtr(meta.filename.?.ptr);
                    try std.testing.expect(pointer >= @intFromPtr(&headers) and pointer < @intFromPtr(&headers) + headers.len);
                },
                .part_end => ended = true,
                .part_data => return error.UnexpectedEmptyPartData,
            }
        }
        try parser.finish();
        try std.testing.expect(began and ended);
    }
}

/// A malformed metadata fixture and its specific closed parser error.
const BadHeader = struct { content: []const u8, expected: multipart.StreamingError };

test "multipart streaming: malformed metadata rejects before begin at every split" {
    const cases = [_]BadHeader{
        .{ .content = "X: ignored", .expected = error.MissingContentDisposition },
        .{ .content = "Content-Disposition: attachment; name=x", .expected = error.InvalidContentDisposition },
        .{ .content = "Content-Disposition: form-data", .expected = error.MissingPartName },
        .{ .content = "Content-Disposition: form-data; filename=x", .expected = error.MissingPartName },
        .{ .content = "Content-Disposition: form-data; name=x; NAME=y", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=x; filename=\"\"; filename=y", .expected = error.InvalidMultipartHeaders },
        .{ .content = header ++ "\r\nContent-Disposition: form-data; name=x", .expected = error.InvalidMultipartHeaders },
        .{ .content = header ++ "\r\nContent-Type: text/plain\r\ncontent-type: text/plain", .expected = error.InvalidMultipartHeaders },
        .{ .content = " Content-Disposition: form-data; name=x", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition : form-data; name=x", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition form-data; name=x", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=x\r\n folded", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=x\nX: injected", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"x\rX\"", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"x\x00y\"", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"x\x7fy\"", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"unclosed", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"x\\", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=\"x\"y", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=x;", .expected = error.InvalidMultipartHeaders },
        .{ .content = "Content-Disposition: form-data; name=x; unknown=\"unterminated", .expected = error.InvalidMultipartHeaders },
    };
    for (cases) |case| {
        var body_buffer: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "--abc\r\n{s}\r\n\r\n\r\n--abc--", .{case.content});
        for (0..body.len + 1) |split| try reject_header(body, split, case.expected);
    }
}

fn reject_header(body: []const u8, split: usize, expected: multipart.StreamingError) !void {
    var headers: [256]u8 = undefined;
    var carry: [7]u8 = undefined;
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    var offset: usize = 0;
    while (offset < body.len) {
        const step = parser.next(body[offset..if (offset < split) split else body.len]) catch |err| {
            try std.testing.expectEqual(expected, err);
            try expect_terminal(&parser);
            return;
        };
        offset += step.consumed;
        try std.testing.expect(step.event == null);
    }
    return error.ExpectedMetadataFailure;
}

test "multipart streaming: exact body header field and part limits" {
    var headers: [header.len]u8 = undefined;
    var carry: [7]u8 = undefined;
    var exact = limits;
    exact.max_body_bytes = entity.len;
    exact.max_parts = 1;
    exact.max_part_headers = 1;
    var parser = try Parser.init("abc", exact, .{ .headers = &headers, .carry = &carry });
    try drain(&parser, entity);
    try parser.finish();

    parser = try Parser.init("abc", exact, .{ .headers = headers[0 .. headers.len - 1], .carry = &carry });
    try std.testing.expectError(error.MultipartHeadersTooLarge, drain(&parser, entity));
    try expect_terminal(&parser);

    exact.max_body_bytes -= 1;
    parser = try Parser.init("abc", exact, .{ .headers = &headers, .carry = &carry });
    try std.testing.expectError(error.MultipartBodyTooLarge, drain(&parser, entity));
    try std.testing.expectEqual(exact.max_body_bytes, parser.total_bytes);
    try expect_terminal(&parser);

    exact.max_body_bytes = 0;
    parser = try Parser.init("abc", exact, .{ .headers = &headers, .carry = &carry });
    try std.testing.expectError(error.MultipartBodyTooLarge, parser.next("-"));
    try std.testing.expectEqual(@as(u64, 0), parser.total_bytes);
    try expect_terminal(&parser);

    var larger_headers: [128]u8 = undefined;
    parser = try Parser.init("abc", .{ .max_body_bytes = 4096, .max_parts = 1, .max_part_headers = 1 }, .{ .headers = &larger_headers, .carry = &carry });
    const extra_field = "--abc\r\n" ++ header ++ "\r\nX: y\r\n\r\n\r\n--abc--";
    try std.testing.expectError(error.TooManyPartHeaders, drain(&parser, extra_field));
    try std.testing.expectEqual(@as(u32, 0), parser.parts);
    try expect_terminal(&parser);

    parser = try Parser.init("abc", limits, .{ .headers = &larger_headers, .carry = &carry });
    parser.limits.max_parts = 1;
    const two_parts = "--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc--";
    try std.testing.expectError(error.TooManyMultipartParts, drain(&parser, two_parts));
    try std.testing.expectEqual(@as(u32, 1), parser.parts);
    try expect_terminal(&parser);
}

test "multipart streaming: zero parts empty parts line starts and epilogue accounting" {
    const zero = "ignored--abc\nxx\n--abc--\x00epilogue\r\n--abc";
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = undefined;
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    for (zero) |byte| {
        const step = try parser.next(&.{byte});
        try std.testing.expectEqual(@as(usize, 1), step.consumed);
        try std.testing.expect(step.event == null);
    }
    try parser.finish();
    try std.testing.expectEqual(@as(u64, zero.len), parser.total_bytes);
    try std.testing.expectEqual(@as(u32, 0), parser.parts);
    const empty = "--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc--";
    for (0..empty.len + 1) |split| try run_split("abc", empty, split, "");
    const preamble = "prefix--abc\r\nline\n" ++ empty ++ "epilogue";
    for (0..preamble.len + 1) |split| try run_split("abc", preamble, split, "");
}

fn reach_data(parser: *Parser, input: []const u8, offset: *usize) ![]const u8 {
    while (offset.* < input.len) {
        const step = try parser.next(input[offset.*..]);
        offset.* += step.consumed;
        const event = step.event orelse continue;
        switch (event) {
            .part_data => |data| return data,
            .part_begin, .part_end => {},
        }
    }
    return error.ExpectedDataEvent;
}

test "multipart streaming: every acknowledgement prefix including zero and full" {
    for (0..6) |prefix| {
        var headers: [128]u8 = undefined;
        var carry: [7]u8 = undefined;
        var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
        var offset: usize = 0;
        const data = try reach_data(&parser, entity, &offset);
        try std.testing.expectEqualStrings("hello", data);
        const before = parser.total_bytes;
        try std.testing.expectEqual(prefix, try parser.accept_data(prefix));
        try std.testing.expectEqual(before + prefix, parser.total_bytes);
        offset += prefix;
        var capture = Capture{};
        @memcpy(capture.bytes[0..prefix], "hello"[0..prefix]);
        capture.len = prefix;
        while (offset < entity.len) offset += try capture.consume(&parser, entity[offset..], 1);
        try parser.finish();
        try std.testing.expectEqualStrings("hello", capture.bytes[0..capture.len]);
        try std.testing.expectEqual(@as(u64, entity.len), parser.total_bytes);
    }
}

test "multipart streaming: replay every prefix retains real mismatch and advances zero" {
    const body = "--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc-XZ\r\n--abc--";
    const mismatch = std.mem.indexOfScalar(u8, body, 'X').?;
    for (0..8) |prefix| {
        var headers: [128]u8 = undefined;
        var carry: [7]u8 = undefined;
        var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
        var offset: usize = 0;
        const data = try reach_data(&parser, body, &offset);
        try std.testing.expectEqual(mismatch, offset);
        try std.testing.expectEqualStrings("\r\n--abc", data);
        const before = parser.total_bytes;
        try std.testing.expectEqual(@as(usize, 0), try parser.accept_data(prefix));
        try std.testing.expectEqual(before, parser.total_bytes);
        var capture = Capture{};
        @memcpy(capture.bytes[0..prefix], "\r\n--abc"[0..prefix]);
        capture.len = prefix;
        while (offset < body.len) offset += try capture.consume(&parser, body[offset..], 1);
        try parser.finish();
        try std.testing.expectEqualStrings("\r\n--abc-XZ", capture.bytes[0..capture.len]);
        try std.testing.expect(capture.replays > 0);
        try std.testing.expectEqual(@as(u64, body.len), parser.total_bytes);
    }
}

fn invalid_ack(replay: bool) !void {
    const replay_body = "--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc\rX\r\n--abc--";
    const body = if (replay) replay_body else entity;
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = @splat(0x91);
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    var offset: usize = 0;
    const data = try reach_data(&parser, body, &offset);
    const before = parser;
    const old_carry = carry;
    try std.testing.expectError(error.InvalidMultipartProgress, parser.accept_data(data.len + 1));
    try std.testing.expectEqual(before.total_bytes, parser.total_bytes);
    try std.testing.expectEqual(before.matched, parser.matched);
    try std.testing.expectEqual(before.suffix, parser.suffix);
    try std.testing.expectEqual(before.replay_len, parser.replay_len);
    try std.testing.expectEqual(before.replay_cursor, parser.replay_cursor);
    try std.testing.expectEqual(before.header_len, parser.header_len);
    try std.testing.expectEqual(before.pending_len, parser.pending_len);
    try std.testing.expectEqualSlices(u8, &old_carry, &carry);
    try expect_terminal(&parser);
}

test "multipart streaming: invalid ack accepts nothing preserves byte state and terminates" {
    try invalid_ack(false);
    try invalid_ack(true);
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = @splat(0x91);
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    try std.testing.expectError(error.InvalidMultipartProgress, parser.accept_data(0));
    try std.testing.expectEqual(@as(u64, 0), parser.total_bytes);
    try expect_terminal(&parser);
}

test "multipart streaming: next and finish while data pending terminate without acceptance" {
    for (0..2) |operation| {
        var headers: [128]u8 = undefined;
        var carry: [7]u8 = undefined;
        var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
        var offset: usize = 0;
        _ = try reach_data(&parser, entity, &offset);
        const total = parser.total_bytes;
        if (operation == 0) {
            try std.testing.expectError(error.InvalidMultipartState, parser.next(entity[offset..]));
        } else {
            try std.testing.expectError(error.InvalidMultipartState, parser.finish());
        }
        try std.testing.expectEqual(total, parser.total_bytes);
        try expect_terminal(&parser);
    }
}

test "multipart streaming: relocated unaccepted input and poisoned accepted storage" {
    const payload = "one\r\n--abcX\r\r\n--abc\rX\r\n--abc-Xtwo";
    const body = "--abc\r\n" ++ header ++ "\r\n\r\n" ++ payload ++ "\r\n--abc--epilogue";
    for (1..body.len + 1) |chunk| try relocated(body, payload, chunk);
}

fn relocated(body: []const u8, expected: []const u8, chunk: usize) !void {
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = undefined;
    var windows: [2][256]u8 = undefined;
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    var capture = Capture{};
    var offset: usize = 0;
    var turns: usize = 0;
    while (offset < body.len) : (turns += 1) {
        try std.testing.expect(turns < body.len * 8);
        const offered = @min(chunk, body.len - offset);
        const window = windows[turns % 2][0..offered];
        @memcpy(window, body[offset..][0..offered]);
        const advanced = try capture.consume(&parser, window, 1);
        @memset(window, 0xcc);
        offset += advanced;
    }
    const final = try parser.next("");
    try std.testing.expect(final.event == null);
    try std.testing.expectEqual(@as(usize, 0), final.consumed);
    try parser.finish();
    try std.testing.expectEqualStrings(expected, capture.bytes[0..capture.len]);
    try std.testing.expectEqual(@as(usize, 1), capture.begins);
    try std.testing.expectEqual(@as(usize, 1), capture.ends);
    try std.testing.expectEqual(@as(u64, body.len), parser.total_bytes);
}

test "multipart streaming: exact suffix subset preserves padded ordinary prefix as payload" {
    const payload = "\r\n--abc \t\r\nstill data";
    const body = "--abc\r\n" ++ header ++ "\r\n\r\n" ++ payload ++ "\r\n--abc--";
    for (0..body.len + 1) |split| try run_split("abc", body, split, payload);
}

test "multipart streaming: body budget rejects offered payload before external effects" {
    const prefix = "--abc\r\n" ++ header ++ "\r\n\r\n";
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = undefined;
    var parser = try Parser.init("abc", .{ .max_body_bytes = prefix.len + 4, .max_parts = 1, .max_part_headers = 1 }, .{ .headers = &headers, .carry = &carry });
    const begun = try parser.next(prefix);
    try std.testing.expect(begun.event.? == .part_begin);
    try std.testing.expectEqual(@as(u64, prefix.len), parser.total_bytes);
    try std.testing.expectError(error.MultipartBodyTooLarge, parser.next("hello"));
    try std.testing.expectEqual(@as(u64, prefix.len), parser.total_bytes);
    try expect_terminal(&parser);
}

test "multipart streaming: epilogue exact budget and u64 counter cannot overflow" {
    var headers: [128]u8 = undefined;
    var carry: [7]u8 = undefined;
    var parser = try Parser.init("abc", .{ .max_body_bytes = 8, .max_parts = 1, .max_part_headers = 1 }, .{ .headers = &headers, .carry = &carry });
    try drain(&parser, "--abc--x");
    try std.testing.expectEqual(@as(u64, 8), parser.total_bytes);
    try std.testing.expectError(error.MultipartBodyTooLarge, parser.next("y"));
    try std.testing.expectEqual(@as(u64, 8), parser.total_bytes);
    try expect_terminal(&parser);

    parser = try Parser.init("abc", .{ .max_body_bytes = std.math.maxInt(u64), .max_parts = 1, .max_part_headers = 1 }, .{ .headers = &headers, .carry = &carry });
    try drain(&parser, "--abc--");
    parser.total_bytes = std.math.maxInt(u64) - 1;
    try std.testing.expectError(error.MultipartBodyTooLarge, parser.next("xy"));
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, parser.total_bytes);
    try expect_terminal(&parser);
}

test "multipart streaming: long boundary every replay acknowledgement prefix" {
    const boundary = "0123456789012345678901234567890123456789012345678901234567890123456789";
    const payload = "\r\n--" ++ boundary ++ "-X\r\n--" ++ boundary ++ "\rX";
    const body = "--" ++ boundary ++ "\r\n" ++ header ++ "\r\n\r\n" ++ payload ++ "\r\n--" ++ boundary ++ "--";
    for (0..boundary.len + 5) |prefix| {
        var headers: [128]u8 = undefined;
        var carry: [74]u8 = undefined;
        var parser = try Parser.init(boundary, limits, .{ .headers = &headers, .carry = &carry });
        var capture = Capture{};
        var offset: usize = 0;
        var turns: usize = 0;
        while (offset < body.len) : (turns += 1) {
            try std.testing.expect(turns < body.len * 8);
            // Zero acknowledgement invalidates a borrow without advancing data.
            const pause_step = try parser.next(body[offset..]);
            offset += pause_step.consumed;
            const event = pause_step.event orelse continue;
            switch (event) {
                .part_begin => |meta| {
                    try std.testing.expectEqualStrings("upload", meta.name);
                    capture.begins += 1;
                },
                .part_end => capture.ends += 1,
                .part_data => {
                    try std.testing.expectEqual(@as(usize, 0), try parser.accept_data(0));
                    offset += try capture.consume(&parser, body[offset..], @max(1, prefix));
                },
            }
        }
        try parser.finish();
        try std.testing.expectEqualStrings(payload, capture.bytes[0..capture.len]);
        try std.testing.expectEqual(@as(u64, body.len), parser.total_bytes);
    }
}

test "multipart streaming: validates boundary grammar and storage nonoverlap" {
    var headers: [256]u8 = undefined;
    var carry: [80]u8 = undefined;
    const invalid_boundaries = [_][]const u8{ "a\r", "a\n", "a\x00", "a;", "a\\", "a\"", "a\xff", "01234567890123456789012345678901234567890123456789012345678901234567890" };
    for (invalid_boundaries) |boundary| {
        try std.testing.expectError(error.InvalidMultipartBoundary, Parser.init(boundary, limits, .{ .headers = &headers, .carry = &carry }));
    }
    const valid = "'()+_,-./:=? a";
    _ = try Parser.init(valid, limits, .{ .headers = &headers, .carry = &carry });
    try std.testing.expectError(error.InvalidMultipartStorage, Parser.init("abc", limits, .{ .headers = &headers, .carry = headers[1..8] }));
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    try std.testing.expectError(error.InvalidMultipartStorage, parser.next(headers[0..1]));
    try expect_terminal(&parser);
}

test "multipart streaming: excess caller carry remains untouched" {
    var headers: [256]u8 = undefined;
    var carry: [80]u8 = @splat(0x77);
    var parser = try Parser.init("abc", limits, .{ .headers = &headers, .carry = &carry });
    const body = "--abc\r\n" ++ header ++ "\r\n\r\n\r\n--abc-X\r\n--abc--";
    try drain(&parser, body);
    try parser.finish();
    for (carry[7..]) |byte| try std.testing.expectEqual(@as(u8, 0x77), byte);
}

test "multipart streaming: one-byte boundary reconstructs extra replay dash within minimum carry" {
    const payload = "\r\n--a-X\r\n--a\rX";
    const body = "--a\r\n" ++ header ++ "\r\n\r\n" ++ payload ++ "\r\n--a--";
    for (0..body.len + 1) |split| {
        for (0..6) |prefix| try one_byte_replay(body, payload, split, prefix);
    }
}

fn one_byte_replay(body: []const u8, expected: []const u8, split: usize, prefix: usize) !void {
    var headers: [128]u8 = undefined;
    var guarded_carry: [7]u8 = @splat(0xa5);
    var windows: [2][256]u8 = undefined;
    var parser = try Parser.init("a", limits, .{ .headers = &headers, .carry = guarded_carry[1..6] });
    var capture = Capture{};
    var offset: usize = 0;
    var turns: usize = 0;
    var zero_acknowledged = false;
    var extra_dash_seen = false;
    while (offset < body.len) : (turns += 1) {
        try std.testing.expect(turns < body.len * 16);
        const end = if (offset < split) split else body.len;
        const input = windows[turns % 2][0 .. end - offset];
        @memcpy(input, body[offset..end]);
        const step = try parser.next(input);
        offset += step.consumed;
        if (step.event) |event| try one_byte_event(&parser, event, &capture, prefix, &zero_acknowledged, &extra_dash_seen, &offset);
        @memset(input, 0xcc);
    }
    try parser.finish();
    try std.testing.expect(extra_dash_seen);
    try std.testing.expectEqualStrings(expected, capture.bytes[0..capture.len]);
    try std.testing.expectEqual(@as(usize, 1), capture.begins);
    try std.testing.expectEqual(@as(usize, 1), capture.ends);
    try std.testing.expectEqual(@as(u64, body.len), parser.total_bytes);
    try std.testing.expectEqual(@as(u8, 0xa5), guarded_carry[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), guarded_carry[6]);
}

fn one_byte_event(parser: *Parser, event: multipart.StreamingEvent, capture: *Capture, prefix: usize, zero_acknowledged: *bool, extra_dash_seen: *bool, offset: *usize) !void {
    switch (event) {
        .part_begin => |meta| {
            try std.testing.expectEqualStrings("upload", meta.name);
            capture.begins += 1;
        },
        .part_end => capture.ends += 1,
        .part_data => |data| {
            if (prefix == 0 and !zero_acknowledged.*) {
                zero_acknowledged.* = true;
                try std.testing.expectEqual(@as(usize, 0), try parser.accept_data(0));
                return;
            }
            zero_acknowledged.* = false;
            const accepted = @min(data.len, @max(1, prefix));
            @memcpy(capture.bytes[capture.len..][0..accepted], data[0..accepted]);
            capture.len += accepted;
            const total_before = parser.total_bytes;
            const is_extra_dash = parser.replay_len == 6 and parser.replay_cursor <= 5 and parser.replay_cursor + accepted > 5;
            if (is_extra_dash) try std.testing.expectEqual(@as(u8, '-'), data[5 - parser.replay_cursor]);
            const advanced = try parser.accept_data(accepted);
            if (is_extra_dash) {
                extra_dash_seen.* = true;
                try std.testing.expectEqual(@as(usize, 0), advanced);
                try std.testing.expectEqual(total_before, parser.total_bytes);
            }
            offset.* += advanced;
        },
    }
}

test "multipart streaming: invalid ack of one-byte extra replay dash preserves storage and counters" {
    const body = "--a\r\n" ++ header ++ "\r\n\r\n\r\n--a-X\r\n--a--";
    for (0..body.len + 1) |split| try invalid_one_byte_replay(body, split);
}

fn invalid_one_byte_replay(body: []const u8, split: usize) !void {
    var headers: [128]u8 = undefined;
    var carry: [5]u8 = @splat(0x91);
    var parser = try Parser.init("a", limits, .{ .headers = &headers, .carry = &carry });
    var offset: usize = 0;
    while (offset < body.len) {
        const step = try parser.next(body[offset..if (offset < split) split else body.len]);
        offset += step.consumed;
        const event = step.event orelse continue;
        if (event != .part_data) continue;
        const data = event.part_data;
        if (parser.replay_len != 6 or parser.replay_cursor != 5) {
            offset += try parser.accept_data(data.len);
            continue;
        }
        try std.testing.expectEqualStrings("-", data);
        const before = parser;
        const old_carry = carry;
        try std.testing.expectError(error.InvalidMultipartProgress, parser.accept_data(2));
        try std.testing.expectEqual(before.total_bytes, parser.total_bytes);
        try std.testing.expectEqual(before.matched, parser.matched);
        try std.testing.expectEqual(before.suffix, parser.suffix);
        try std.testing.expectEqual(before.replay_len, parser.replay_len);
        try std.testing.expectEqual(before.replay_cursor, parser.replay_cursor);
        try std.testing.expectEqual(before.pending_len, parser.pending_len);
        try std.testing.expectEqualSlices(u8, &old_carry, &carry);
        try expect_terminal(&parser);
        return;
    }
    return error.ExpectedExtraDashReplay;
}
