const decoder = @import("../http/body_decoder.zig");
const parser = @import("../http/parser.zig");

/// Shared bounded Smith/LLVM exercise for provisional heads and acknowledged payloads.
pub fn fuzz_one(input: []const u8, split: usize) void {
    if (input.len > 4096 or split > input.len) return;
    check_head(input, split);
    check_body(input, split, .chunked);
    const length: u64 = if (input.len == 0) 0 else @as(u64, 4294967296) + input[0];
    check_body(input, split, .{ .content_length = length });
}

fn check_head(input: []const u8, split: usize) void {
    var storage: [4096]u8 = undefined;
    @memcpy(storage[0..input.len], input);
    var state = parser.HttpParser{};
    var request = parser.Request{};
    var result = parser.consume_head(&state, &request, storage[0..split]);
    if (result.ready == null and !terminal(state.state)) {
        result = parser.consume_head(&state, &request, storage[0..input.len]);
    }
    if (result.consumed > input.len) @panic("HTTP head consumed beyond input");
    if (request.body.len != 0) @panic("HTTP head consumed payload before admission");
    if (state.scan_work > 4 * input.len + 32) @panic("HTTP head scan work is superlinear");
    if (result.ready) |head| {
        if (head.header_end > input.len) @panic("HTTP head offset exceeds input");
    }
    _ = parser.commit_head(&state, &request, result);
}

fn terminal(state: parser.ParserState) bool {
    return switch (state) {
        .done, .error_invalid, .error_headers_too_large, .error_too_large => true,
        else => false,
    };
}

fn check_body(input: []const u8, split: usize, framing: decoder.Framing) void {
    var state = decoder.init(framing, .{ .max_body_bytes = 4294971392, .max_header_bytes = 256, .line_content_limit = 128 });
    var base: usize = 0;
    var end = split;
    var steps: usize = 0;
    while (steps <= 2 * input.len + 32) : (steps += 1) {
        const event = decoder.next(&state, input[base..end]);
        if (state.mark > end - base) @panic("HTTP decoder consumed beyond retained input");
        if (state.body_length > state.limits.max_body_bytes) @panic("HTTP decoder logical limit exceeded");
        switch (event) {
            .data => |bytes| {
                if (bytes.len == 0) @panic("HTTP decoder emitted empty payload");
                const accepted = @min(bytes.len, 1 + @as(usize, input[0] % 8));
                const previous = state.body_length;
                // The nonempty event bounds this accepted prefix.
                decoder.accept_payload(&state, accepted) catch unreachable;
                if (state.body_length - previous != accepted) @panic("HTTP payload credit diverged");
            },
            .need_more => {
                if (end == input.len) return;
                end = input.len;
            },
            .end, .invalid, .too_large => return,
        }
        const reclaimed = state.mark;
        // mark is precisely the decoder's acknowledged prefix.
        decoder.discard_prefix(&state, reclaimed) catch unreachable;
        base += reclaimed;
    }
    @panic("HTTP decoder failed to make bounded progress");
}
