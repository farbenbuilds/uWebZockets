const std = @import("std");
const simd = @import("../core/simd.zig");

/// RFC 9112 section 6.3 framing, independent of physical buffer capacity.
pub const Framing = union(enum) {
    none,
    content_length: u64,
    chunked,
};

/// Caller-owned body validation bounds; buffered compatibility retains its old line policy.
pub const Limits = struct {
    max_body_bytes: u64 = std.math.maxInt(u64),
    max_header_bytes: usize = 16 * 1024,
    line_content_limit: usize = 16 * 1024,
    buffered: bool = false,
};

/// Body framing state, with no retained input pointer or application callback.
pub const State = enum {
    body,
    chunk_size,
    chunk_ext,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    done,
    error_invalid,
    error_too_large,
};

/// Each data event is a nonempty borrow valid until the caller changes input storage.
pub const Event = union(enum) {
    need_more,
    data: []const u8,
    end,
    invalid,
    too_large,
};

/// Offsets address retained caller input; discard_prefix rebases only reclaimed bytes.
pub const BodyDecoder = struct {
    state: State,
    limits: Limits,
    mark: usize = 0,
    scan: usize = 0,
    /// Cumulative delimiter work; streaming saturates at maxInt(usize), even after reclamation.
    /// Buffered collection retains the legacy parser's exact bounded accounting.
    scan_work: usize = 0,
    chunk_length: u64 = 0,
    body_length: u64 = 0,
    remaining: u64 = 0,
    offered: usize = 0,
    line_start: usize = 0,
    line_prefix_bytes: usize = 0,
    trailer_bytes: usize = 0,
    trailer_count: usize = 0,
};

/// Initializes logical framing without narrowing wire lengths to machine width.
pub fn init(framing: Framing, limits: Limits) BodyDecoder {
    var decoder = BodyDecoder{ .state = .done, .limits = limits };
    switch (framing) {
        .none => {},
        .chunked => decoder.state = .chunk_size,
        .content_length => |length| {
            decoder.remaining = length;
            if (length != 0) decoder.state = .body;
            if (length > limits.max_body_bytes) decoder.state = .error_too_large;
        },
    }
    return decoder;
}

fn enter_state(decoder: *BodyDecoder, state: State, offset: usize) void {
    decoder.state = state;
    decoder.mark = offset;
    decoder.scan = offset;
}

fn record_scan_work(decoder: *BodyDecoder, count: usize) void {
    if (decoder.limits.buffered) {
        decoder.scan_work += count;
        return;
    }
    // Reusing bounded ingress does not bound a streaming request's lifetime work.
    decoder.scan_work +|= count;
}

fn fail(decoder: *BodyDecoder, state: State) Event {
    decoder.state = state;
    return if (state == .error_too_large) .too_large else .invalid;
}

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn is_hexadecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// Validates forbidden trailer fields without merging them into initial headers.
/// RFC 9110 section 6.5.1 excludes framing and routing metadata from trailers.
fn valid_trailer(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const name = line[0..colon];
    if (name.len == 0) return false;
    for (name) |c| {
        if (!is_tchar(c)) return false;
    }
    if (std.ascii.eqlIgnoreCase(name, "Content-Length") or
        std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
        std.ascii.eqlIgnoreCase(name, "Host")) return false;
    return simd.valid_http_field_value(line[colon + 1 ..]);
}

fn valid_trailers(trailers: []const u8, max_bytes: usize) bool {
    if (trailers.len > max_bytes) return false;
    var count: usize = 0;
    var lines = std.mem.splitSequence(u8, trailers, "\r\n");
    while (lines.next()) |line| {
        count += 1;
        if (count > 64 or !valid_trailer(line)) return false;
    }
    return true;
}

/// RFC 9112 section 7.1 chunk-ext grammar: `*( ";" name [ "=" value ] )`.
/// The caller has already consumed the first semicolon.
fn valid_chunk_extensions(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) {
        skip_bws(input, &index);
        const name_start = index;
        while (index < input.len and is_tchar(input[index])) index += 1;
        if (index == name_start) return false;
        skip_bws(input, &index);
        if (index < input.len and input[index] == '=') {
            index += 1;
            skip_bws(input, &index);
            if (index == input.len) return false;
            if (input[index] == '"') {
                index += 1;
                var closed = false;
                while (index < input.len) {
                    const byte = input[index];
                    index += 1;
                    if (byte == '"') {
                        closed = true;
                        break;
                    }
                    if (byte == '\\') {
                        if (index == input.len) return false;
                        if (!field_byte(input[index])) return false;
                        index += 1;
                        continue;
                    }
                    if (!field_byte(byte)) return false;
                }
                if (!closed) return false;
            } else {
                const value_start = index;
                while (index < input.len and is_tchar(input[index])) index += 1;
                if (index == value_start) return false;
            }
            skip_bws(input, &index);
        }
        if (index == input.len) return true;
        if (input[index] != ';') return false;
        index += 1;
    }
    return false;
}

fn skip_bws(input: []const u8, index: *usize) void {
    while (index.* < input.len and (input[index.*] == ' ' or input[index.*] == '\t')) index.* += 1;
}

fn field_byte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn line_too_long(decoder: *const BodyDecoder, end: usize) bool {
    if (decoder.limits.buffered) return false;
    const length = std.math.add(usize, decoder.line_prefix_bytes, end - decoder.line_start) catch return true;
    return length > decoder.limits.line_content_limit;
}

fn chunk_size(decoder: *BodyDecoder, buffer: []const u8) ?Event {
    const search_start = decoder.scan;
    const offset = std.mem.indexOfAny(u8, buffer[search_start..], "\r;") orelse {
        record_scan_work(decoder, buffer.len - search_start);
        decoder.scan = buffer.len;
        if (line_too_long(decoder, buffer.len)) return fail(decoder, .error_invalid);
        return .need_more;
    };
    record_scan_work(decoder, offset + 1);
    const end = search_start + offset;
    if (line_too_long(decoder, end + @as(usize, @intFromBool(buffer[end] == ';')))) return fail(decoder, .error_invalid);
    const hex = buffer[decoder.mark..end];
    if (!is_hexadecimal(hex)) return fail(decoder, .error_invalid);
    const length = std.fmt.parseInt(u64, hex, 16) catch return fail(decoder, .error_invalid);
    if (decoder.limits.buffered and length > std.math.maxInt(usize)) return fail(decoder, .error_invalid);
    if (decoder.body_length > decoder.limits.max_body_bytes or
        length > decoder.limits.max_body_bytes - decoder.body_length) return fail(decoder, .error_too_large);
    decoder.chunk_length = length;
    decoder.remaining = length;
    if (buffer[end] == ';') {
        enter_state(decoder, .chunk_ext, end + 1);
        return null;
    }
    if (end + 1 == buffer.len) {
        decoder.scan = end;
        return .need_more;
    }
    if (buffer[end + 1] != '\n') return fail(decoder, .error_invalid);
    enter_state(decoder, if (length == 0) .chunk_trailer else .chunk_data, end + 2);
    decoder.line_start = decoder.mark;
    decoder.line_prefix_bytes = 0;
    return null;
}

fn chunk_extension(decoder: *BodyDecoder, buffer: []const u8) ?Event {
    const search_start = decoder.scan;
    const offset = std.mem.indexOfScalar(u8, buffer[search_start..], '\r') orelse {
        record_scan_work(decoder, buffer.len - search_start);
        decoder.scan = buffer.len;
        if (line_too_long(decoder, buffer.len)) return fail(decoder, .error_invalid);
        return .need_more;
    };
    record_scan_work(decoder, offset + 1);
    const end = search_start + offset;
    if (line_too_long(decoder, end)) return fail(decoder, .error_invalid);
    if (!valid_chunk_extensions(buffer[decoder.mark..end])) return fail(decoder, .error_invalid);
    if (end + 1 == buffer.len) {
        decoder.scan = end;
        return .need_more;
    }
    if (buffer[end + 1] != '\n') return fail(decoder, .error_invalid);
    enter_state(decoder, if (decoder.chunk_length == 0) .chunk_trailer else .chunk_data, end + 2);
    decoder.line_start = decoder.mark;
    decoder.line_prefix_bytes = 0;
    return null;
}

fn buffered_trailers(decoder: *BodyDecoder, buffer: []const u8) Event {
    if (buffer.len - decoder.mark >= 2 and std.mem.eql(u8, buffer[decoder.mark..][0..2], "\r\n")) {
        enter_state(decoder, .done, decoder.mark + 2);
        return .end;
    }
    const search_start = decoder.scan;
    if (simd.index_of_header_end(buffer[search_start..])) |relative_end| {
        record_scan_work(decoder, relative_end + 4);
        const end = search_start + relative_end;
        if (!valid_trailers(buffer[decoder.mark..end], decoder.limits.max_header_bytes)) return fail(decoder, .error_invalid);
        enter_state(decoder, .done, end + 4);
        return .end;
    }
    record_scan_work(decoder, buffer.len - search_start);
    decoder.scan = @max(decoder.mark, buffer.len -| 3);
    return .need_more;
}

fn streaming_trailers(decoder: *BodyDecoder, buffer: []const u8) ?Event {
    const search_start = decoder.scan;
    const offset = std.mem.indexOfScalar(u8, buffer[search_start..], '\n') orelse {
        record_scan_work(decoder, buffer.len - search_start);
        decoder.scan = buffer.len;
        const end = buffer.len - @as(usize, @intFromBool(buffer[buffer.len - 1] == '\r'));
        if (line_too_long(decoder, end)) return fail(decoder, .error_invalid);
        return .need_more;
    };
    record_scan_work(decoder, offset + 1);
    const end = search_start + offset;
    if (end == decoder.mark or buffer[end - 1] != '\r') return fail(decoder, .error_invalid);
    const line = buffer[decoder.mark .. end - 1];
    if (line_too_long(decoder, end - 1)) return fail(decoder, .error_invalid);
    if (line.len == 0) {
        enter_state(decoder, .done, end + 1);
        return .end;
    }
    const separator: usize = if (decoder.trailer_count == 0) 0 else 2;
    if (decoder.trailer_count == 64 or !valid_trailer(line)) return fail(decoder, .error_invalid);
    const added = std.math.add(usize, line.len, separator) catch return fail(decoder, .error_invalid);
    const total = std.math.add(usize, decoder.trailer_bytes, added) catch return fail(decoder, .error_invalid);
    if (total > decoder.limits.max_header_bytes) return fail(decoder, .error_invalid);
    decoder.trailer_bytes = total;
    decoder.trailer_count += 1;
    enter_state(decoder, .chunk_trailer, end + 1);
    decoder.line_start = decoder.mark;
    decoder.line_prefix_bytes = 0;
    return null;
}

/// Consumes framing only. Payload remains unconsumed until accept_payload succeeds.
/// Input retains incomplete framing; after rebasing reclaimed bytes, pass its retained tail.
pub fn next(decoder: *BodyDecoder, buffer: []const u8) Event {
    decoder.offered = 0;
    while (decoder.mark < buffer.len) {
        switch (decoder.state) {
            .body, .chunk_data => {
                if (decoder.remaining == 0) {
                    enter_state(decoder, if (decoder.state == .body) .done else .chunk_crlf, decoder.mark);
                    continue;
                }
                const available = buffer.len - decoder.mark;
                if (decoder.limits.buffered and available < decoder.remaining) return .need_more;
                const length: usize = @intCast(@min(@as(u64, available), decoder.remaining));
                decoder.offered = length;
                return .{ .data = buffer[decoder.mark..][0..length] };
            },
            .chunk_size => if (chunk_size(decoder, buffer)) |event| return event,
            .chunk_ext => if (chunk_extension(decoder, buffer)) |event| return event,
            .chunk_crlf => {
                if (buffer.len - decoder.mark < 2) return .need_more;
                if (!std.mem.eql(u8, buffer[decoder.mark..][0..2], "\r\n")) return fail(decoder, .error_invalid);
                enter_state(decoder, .chunk_size, decoder.mark + 2);
                decoder.line_start = decoder.mark;
                decoder.line_prefix_bytes = 0;
            },
            .chunk_trailer => {
                if (decoder.limits.buffered) return buffered_trailers(decoder, buffer);
                if (streaming_trailers(decoder, buffer)) |event| return event;
            },
            .done => return .end,
            .error_invalid => return .invalid,
            .error_too_large => return .too_large,
        }
    }
    return switch (decoder.state) {
        .done => .end,
        .error_invalid => .invalid,
        .error_too_large => .too_large,
        else => .need_more,
    };
}

/// Accepts at most the last offered prefix, without retaining its borrowed slice.
pub fn accept_payload(decoder: *BodyDecoder, count: usize) error{InvalidProgress}!void {
    if (decoder.state != .body and decoder.state != .chunk_data) return error.InvalidProgress;
    if (count > decoder.offered) return error.InvalidProgress;
    decoder.mark += count;
    decoder.remaining -= count;
    decoder.body_length += count;
    decoder.offered -= count;
    if (decoder.remaining != 0) return;
    enter_state(decoder, if (decoder.state == .body) .done else .chunk_crlf, decoder.mark);
}

/// Reclaims a consumed prefix while preserving offsets into retained framing or payload.
pub fn discard_prefix(decoder: *BodyDecoder, count: usize) error{InvalidProgress}!void {
    if (count > decoder.mark) return error.InvalidProgress;
    const line_active = decoder.state == .chunk_size or decoder.state == .chunk_ext or decoder.state == .chunk_trailer;
    if (line_active and count > decoder.line_start) {
        decoder.line_prefix_bytes += count - decoder.line_start;
    }
    decoder.mark -= count;
    decoder.scan -|= count;
    decoder.line_start -|= count;
    decoder.offered = 0;
}
