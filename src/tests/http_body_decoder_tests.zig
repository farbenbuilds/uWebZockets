const std = @import("std");
const support = @import("test_support");
const parser = support.http_parser;
const decoder = support.http_body_decoder;

test "http head: ready precedes complete same-read fixed body" {
    var state = parser.HttpParser{};
    var request = parser.Request{};
    var input = "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndataNEXT".*;
    const result = parser.consume_head(&state, &request, &input);
    const head = result.ready.?;
    try std.testing.expectEqual(@as(u64, 4), head.framing.content_length);
    try std.testing.expectEqualStrings("", request.body);
    try std.testing.expectEqualStrings("example.test", head.headers.get("Host").?);
    try std.testing.expect(parser.commit_head(&state, &request, result));
    try std.testing.expectEqual(head.header_end + 4, parser.consume(&state, &request, &input));
    try std.testing.expectEqualStrings("data", request.body);
}

test "http decoder: fixed payload advances only accepted prefix" {
    var state = decoder.init(.{ .content_length = 4 }, .{ .max_body_bytes = 10 });
    const offered = decoder.next(&state, "dataNEXT").data;
    try std.testing.expectEqualStrings("data", offered);
    try decoder.accept_payload(&state, 1);
    try std.testing.expectEqualStrings("ata", decoder.next(&state, "dataNEXT").data);
    try decoder.accept_payload(&state, 3);
    try std.testing.expectEqual(decoder.Event.end, decoder.next(&state, "dataNEXT"));
    try std.testing.expectEqual(@as(usize, 4), state.mark);
}

test "http head: large logical length is admitted before buffered policy" {
    var state = parser.HttpParser{};
    var request = parser.Request{};
    var input = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4294967296\r\n\r\npayload".*;
    const result = parser.consume_head(&state, &request, &input);
    try std.testing.expectEqual(@as(u64, 4294967296), result.ready.?.framing.content_length);
    try std.testing.expectEqual(parser.ParserState.headers, state.state);
    try std.testing.expectEqual(@as(usize, 0), state.content_length);
    try std.testing.expectEqualStrings("", request.body);
    try std.testing.expect(request.extra_header_names == null);
    try std.testing.expect(!parser.commit_head(&state, &request, result));
    const expected: parser.ParserState = if (@sizeOf(usize) == 4) .error_invalid else .error_too_large;
    try std.testing.expectEqual(expected, state.state);
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 4) 1 else 2), request.header_count);
}

test "http head: logical width rejection survives later structural error" {
    var state = parser.HttpParser{};
    var request = parser.Request{};
    var input = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4294967296\r\nX: v\r\nMalformed\r\n\r\n".*;
    const result = parser.consume_head(&state, &request, &input);
    try std.testing.expect(result.ready == null);
    try std.testing.expect(!parser.commit_head(&state, &request, result));
    try std.testing.expectEqual(parser.ParserState.error_invalid, state.state);
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 4) 1 else 3), request.header_count);
}

test "http head: cap rejection follows structural validation" {
    const inputs = [_][]const u8{
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 20000\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 20000\r\nMalformed\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 20000\r\n\r\n",
    };
    for (inputs) |input| {
        var storage: [128]u8 = undefined;
        @memcpy(storage[0..input.len], input);
        var state = parser.HttpParser{};
        var request = parser.Request{};
        const result = parser.consume_head(&state, &request, storage[0..input.len]);
        try std.testing.expect(result.ready == null);
        try std.testing.expect(!parser.commit_head(&state, &request, result));
        try std.testing.expectEqual(parser.ParserState.error_invalid, state.state);
    }
}

test "http head: chunked head returns before malformed same-read body" {
    var state = parser.HttpParser{};
    var request = parser.Request{};
    var input = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n".*;
    const result = parser.consume_head(&state, &request, &input);
    try std.testing.expectEqual(decoder.Framing.chunked, result.ready.?.framing);
    try std.testing.expectEqualStrings("", request.body);
    try std.testing.expect(parser.commit_head(&state, &request, result));
    _ = parser.consume(&state, &request, &input);
    try std.testing.expectEqual(parser.ParserState.error_invalid, state.state);
}

test "http head: overflow header view remains provisional until commit" {
    var state = parser.HttpParser{};
    var names: [2][]const u8 = undefined;
    var values: [2][]const u8 = undefined;
    state.extra_header_names = &names;
    state.extra_header_values = &values;
    var request = parser.Request{};
    var input: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    try writer.writeAll("GET / HTTP/1.1\r\nHost: a\r\n");
    for (0..64) |_| try writer.writeAll("X: v\r\n");
    try writer.writeAll("\r\n");
    const result = parser.consume_head(&state, &request, input[0..writer.end]);
    try std.testing.expectEqualStrings("v", result.ready.?.headers.extra_values[0]);
    try std.testing.expect(request.extra_header_names == null);
    try std.testing.expectEqual(@as(usize, 0), request.extra_header_count);
    try std.testing.expect(parser.commit_head(&state, &request, result));
    try std.testing.expectEqual(@as(usize, 1), request.extra_header_count);
}

test "http head: every head split retains exact fixed-body pipeline" {
    const text = "POST /upload?q HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\ndataPIPE";
    const head_end = std.mem.indexOf(u8, text, "\r\n\r\n").? + 4;
    for (0..head_end) |split| {
        var input: [text.len]u8 = text.*;
        var state = parser.HttpParser{};
        var request = parser.Request{};
        try std.testing.expect(parser.consume_head(&state, &request, input[0..split]).ready == null);
        const result = parser.consume_head(&state, &request, &input);
        try std.testing.expectEqual(head_end, result.consumed);
        try std.testing.expectEqualStrings("100-continue", result.ready.?.headers.get("Expect").?);
        try std.testing.expect(parser.commit_head(&state, &request, result));
        const consumed = parser.consume(&state, &request, &input);
        try std.testing.expectEqualStrings("PIPE", input[consumed..]);
        try std.testing.expectEqualStrings("data", request.body);
    }
}

test "http decoder: framing splits and partial payload keep pipeline bytes" {
    const input = "4;x=y\r\ndata\r\n1\r\nx\r\n0\r\nX: v\r\n\r\nPIPE";
    const body_end = input.len - 4;
    for (0..body_end) |split| {
        var state = decoder.init(.chunked, .{ .max_body_bytes = 5 });
        var delivered: [5]u8 = undefined;
        var delivered_count: usize = 0;
        var end = split;
        while (true) {
            switch (decoder.next(&state, input[0..end])) {
                .data => |bytes| {
                    try std.testing.expect(bytes.len != 0);
                    delivered[delivered_count] = bytes[0];
                    delivered_count += 1;
                    try decoder.accept_payload(&state, 1);
                },
                .need_more => {
                    try std.testing.expect(end != input.len);
                    end = input.len;
                },
                .end => break,
                else => return error.UnexpectedFramingFailure,
            }
        }
        try std.testing.expectEqualStrings("datax", &delivered);
        try std.testing.expectEqualStrings("PIPE", input[state.mark..]);
        try std.testing.expectEqual(@as(u64, 5), state.body_length);
    }
}

test "http decoder: logical lengths exceed machine width without truncation" {
    var fixed = decoder.init(.{ .content_length = 4294967296 }, .{});
    try std.testing.expectEqualStrings("abc", decoder.next(&fixed, "abc").data);
    try decoder.accept_payload(&fixed, 3);
    try std.testing.expectEqual(@as(u64, 4294967293), fixed.remaining);
    try decoder.discard_prefix(&fixed, fixed.mark);
    try std.testing.expectEqualStrings("def", decoder.next(&fixed, "def").data);
    var chunked = decoder.init(.chunked, .{});
    try std.testing.expectEqualStrings("abc", decoder.next(&chunked, "100000000\r\nabc").data);
    try decoder.accept_payload(&chunked, 3);
    try std.testing.expectEqual(@as(u64, 4294967293), chunked.remaining);
}

test "http decoder: invalid progress preserves counters" {
    var state = decoder.init(.{ .content_length = 3 }, .{});
    try std.testing.expectError(error.InvalidProgress, decoder.accept_payload(&state, 1));
    _ = decoder.next(&state, "abc");
    try std.testing.expectError(error.InvalidProgress, decoder.accept_payload(&state, 4));
    try std.testing.expectError(error.InvalidProgress, decoder.discard_prefix(&state, 1));
    try std.testing.expectEqual(@as(usize, 0), state.mark);
    try std.testing.expectEqual(@as(u64, 3), state.remaining);
    try decoder.accept_payload(&state, 0);
    try std.testing.expectEqualStrings("abc", decoder.next(&state, "abc").data);
}

test "http decoder: malformed chunk framing fails closed" {
    const inputs = [_][]const u8{
        "\r\n",    "Z\r\n",     "-1\r\n",    "10000000000000000\r\n", "1\rX",                    "1;x\n\r\n",         "1\r\nxXX",            "0\r\nHost: x\r\n\r\n",  "0\r\nTransfer-Encoding: chunked\r\n\r\n", "0\r\nContent-Length: 0\r\n\r\n", "0\r\nX : v\r\n\r\n", "0\r\nX: \x7f\r\n\r\n",
        "1;\r\nx", "1;=x\r\nx", "1;x=\r\nx", "1;x;=y\r\nx",           "1;x=\"unterminated\r\nx", "1;x=\"a\nb\"\r\nx", "1;x=\"a\\\nb\"\r\nx", "1;x=\"a\\\x00b\"\r\nx", "1;x=\"a\\\x7fb\"\r\nx",
    };
    for (inputs) |input| {
        var state = decoder.init(.chunked, .{});
        while (true) {
            switch (decoder.next(&state, input)) {
                .data => |bytes| try decoder.accept_payload(&state, bytes.len),
                .invalid => break,
                else => return error.MalformedFramingAccepted,
            }
        }
    }
}

test "http decoder: valid chunk extensions accept tokens and quoted values" {
    for ([_][]const u8{
        "1;x\r\nx\r\n0\r\n\r\n",
        "1;x=y\r\nx\r\n0\r\n\r\n",
        "1; x = y \r\nx\r\n0\r\n\r\n",
        "1;x;y=z\r\nx\r\n0\r\n\r\n",
        "1;x=\"a b\"\r\nx\r\n0\r\n\r\n",
        "1;x=\"a\\\"b\"\r\nx\r\n0\r\n\r\n",
    }) |input| {
        var state = decoder.init(.chunked, .{});
        try std.testing.expectEqualStrings("x", decoder.next(&state, input).data);
        try decoder.accept_payload(&state, 1);
        try std.testing.expectEqual(decoder.Event.end, decoder.next(&state, input));
    }
}

test "http decoder: logical chunk cap rejects before offering offending payload" {
    var state = decoder.init(.chunked, .{ .max_body_bytes = 3 });
    try std.testing.expectEqualStrings("ab", decoder.next(&state, "2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n").data);
    try decoder.accept_payload(&state, 2);
    try std.testing.expectEqual(decoder.Event.too_large, decoder.next(&state, "2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n"));
    try std.testing.expectEqual(@as(u64, 2), state.body_length);
    try std.testing.expectEqual(decoder.Event.too_large, decoder.next(&state, ""));
}

test "http decoder: streaming line bound includes discarded size prefix" {
    var state = decoder.init(.chunked, .{ .line_content_limit = 4 });
    try std.testing.expectEqual(decoder.Event.need_more, decoder.next(&state, "1;x"));
    try decoder.discard_prefix(&state, state.mark);
    try std.testing.expectEqual(decoder.Event.invalid, decoder.next(&state, "xyz\r\nx"));
    var exact = decoder.init(.chunked, .{ .line_content_limit = 4 });
    try std.testing.expectEqualStrings("x", decoder.next(&exact, "1;xy\r\nx").data);
}

test "http decoder: streaming trailer byte and field bounds" {
    var input: [1024]u8 = undefined;
    for ([_]usize{ 64, 65 }) |count| {
        var writer = std.Io.Writer.fixed(&input);
        try writer.writeAll("0\r\n");
        for (0..count) |_| try writer.writeAll("X:\r\n");
        try writer.writeAll("\r\n");
        var state = decoder.init(.chunked, .{ .max_header_bytes = 254 });
        const event = decoder.next(&state, input[0..writer.end]);
        const expected: std.meta.Tag(decoder.Event) = if (count == 64) .end else .invalid;
        try std.testing.expectEqual(expected, std.meta.activeTag(event));
    }
    var small = decoder.init(.chunked, .{ .max_header_bytes = 5 });
    try std.testing.expectEqual(decoder.Event.invalid, decoder.next(&small, "0\r\nX:\r\nY:\r\n\r\n"));
}

test "http decoder: buffered extension policy retains long valid lines" {
    var input: [17032]u8 = undefined;
    @memcpy(input[0..2], "1;");
    @memset(input[2..17002], 'x');
    const suffix = "\r\nx\r\n0\r\n\r\nPIPE";
    @memcpy(input[17002..][0..suffix.len], suffix);
    var buffered = decoder.init(.chunked, .{ .buffered = true });
    try std.testing.expectEqualStrings("x", decoder.next(&buffered, input[0 .. 17002 + suffix.len]).data);
    try decoder.accept_payload(&buffered, 1);
    try std.testing.expectEqual(decoder.Event.end, decoder.next(&buffered, input[0 .. 17002 + suffix.len]));
    var streaming = decoder.init(.chunked, .{});
    try std.testing.expectEqual(decoder.Event.invalid, decoder.next(&streaming, input[0 .. 17002 + suffix.len]));
}

test "http decoder: deterministic fuzz seeds retain progress after compaction" {
    const seeds = [_][]const u8{
        "1;x=y\r\nx\r\n0\r\nX: v\r\n\r\nPIPE",
        "0\r\nHost: forbidden\r\n\r\n",
        "100000000\r\nx",
        "10000000000000000\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4294967296\r\n\r\n",
    };
    for (seeds) |seed| {
        for (0..seed.len + 1) |split| support.fuzz_http_body.fuzz_one(seed, split);
    }
}

test "http decoder: payload reclamation does not accumulate framing line budget" {
    var state = decoder.init(.{ .content_length = 100 }, .{ .line_content_limit = 1 });
    for (0..100) |_| {
        try std.testing.expectEqualStrings("x", decoder.next(&state, "x").data);
        try decoder.accept_payload(&state, 1);
        try decoder.discard_prefix(&state, 1);
        try std.testing.expectEqual(@as(usize, 0), state.line_prefix_bytes);
    }
    try std.testing.expectEqual(decoder.Event.end, decoder.next(&state, "PIPE"));
}

test "http decoder: streaming scan work saturates across reclaimed chunks" {
    const input = "1\r\nx\r\n0\r\nX: v\r\n\r\nPIPE";
    var state = decoder.init(.chunked, .{});
    state.scan_work = std.math.maxInt(usize) - 1;
    try std.testing.expectEqualStrings("x", decoder.next(&state, input).data);
    try std.testing.expectEqual(std.math.maxInt(usize), state.scan_work);
    try decoder.accept_payload(&state, 1);
    const reclaimed = state.mark;
    try decoder.discard_prefix(&state, reclaimed);
    try std.testing.expectEqual(decoder.Event.end, decoder.next(&state, input[reclaimed..]));
    try std.testing.expectEqual(std.math.maxInt(usize), state.scan_work);
    try std.testing.expectEqualStrings("PIPE", input[reclaimed + state.mark ..]);
    try std.testing.expectEqual(@as(u64, 1), state.body_length);
}

test "http decoder: streaming partial framing searches saturate" {
    var state = decoder.init(.chunked, .{});
    state.scan_work = std.math.maxInt(usize) - 1;
    try std.testing.expectEqual(decoder.Event.need_more, decoder.next(&state, "1"));
    try std.testing.expectEqual(std.math.maxInt(usize), state.scan_work);
    try std.testing.expectEqual(decoder.Event.need_more, decoder.next(&state, "1;x"));
    try std.testing.expectEqual(decoder.Event.need_more, decoder.next(&state, "1;xy"));
    try std.testing.expectEqualStrings("x", decoder.next(&state, "1;xy\r\nx\r\n0\r\nX: v\r\n\r\n").data);
    try decoder.accept_payload(&state, 1);
    const reclaimed = state.mark;
    try decoder.discard_prefix(&state, reclaimed);
    try std.testing.expectEqual(decoder.Event.need_more, decoder.next(&state, "\r\n0\r\nX:"));
    try std.testing.expectEqual(decoder.Event.end, decoder.next(&state, "\r\n0\r\nX: v\r\n\r\n"));
    try std.testing.expectEqual(std.math.maxInt(usize), state.scan_work);
    try std.testing.expectEqual(@as(u64, 1), state.body_length);
}
