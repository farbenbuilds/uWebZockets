const std = @import("std");
const multipart = @import("../http/multipart.zig");

pub const max_input_size = 8192;
const max_parts = 32;
const header_capacity = 512;
const guard = 0xa7;

const Field = struct { offset: usize, length: usize, present: bool };
const Record = struct {
    name: Field,
    filename: Field,
    content_type: Field,
    data_offset: usize,
    data_length: usize = 0,
    ended: bool = false,
};
const Outcome = struct {
    failure: ?multipart.StreamingError = null,
    metadata: [max_input_size]u8 = undefined,
    metadata_length: usize = 0,
    payload: [max_input_size]u8 = undefined,
    payload_length: usize = 0,
    records: [max_parts]Record = undefined,
    count: usize = 0,
};
const Schedule = enum { whole, bytes, uneven };

/// The first byte selects boundary length and resource limits; the rest is an
/// untrusted entity. Every input also supplies a separate known-valid oracle.
pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;
    const control: u8 = if (input.len == 0) 0 else input[0];
    const entity = if (input.len == 0) input else input[1..];
    const boundary = if (control & 1 == 0) "abc" else "b" ** 70;
    const limits = multipart.StreamingLimits{
        .max_body_bytes = if (control & 2 == 0) max_input_size else entity.len / 2,
        .max_parts = if (control & 4 == 0) max_parts else 1,
        .max_part_headers = if (control & 8 == 0) 8 else 1,
    };
    const header_length: usize = if (control & 16 == 0) header_capacity else 31;
    const whole = drive(entity, boundary, limits, header_length, .whole, false);
    const bytes = drive(entity, boundary, limits, header_length, .bytes, false);
    const uneven = drive(entity, boundary, limits, header_length, .uneven, false);
    compare(&whole, &bytes);
    compare(&whole, &uneven);
    _ = drive(entity, boundary, limits, header_length, .uneven, true);
    known_valid(input, boundary);
}

fn drive(entity: []const u8, boundary: []const u8, limits: multipart.StreamingLimits, header_length: usize, schedule: Schedule, invalid_ack: bool) Outcome {
    var headers: [header_capacity + 2]u8 = @splat(guard);
    var carry: [76]u8 = @splat(guard);
    var parser = multipart.StreamingParser.init(boundary, limits, .{
        .headers = headers[1..][0..header_length],
        .carry = carry[1..][0 .. boundary.len + 4],
    }) catch @panic("valid harness configuration rejected");
    var banks: [2][max_input_size]u8 = @splat(@splat(0xdc));
    var outcome = Outcome{};
    var accepted: usize = 0;
    var window_end: usize = 0;
    var iteration: usize = 0;
    while (true) {
        iteration += 1;
        if (iteration > entity.len * 16 + 4096) @panic("multipart driver did not make bounded progress");
        if (accepted == window_end and accepted < entity.len) {
            const count = switch (schedule) {
                .whole => entity.len,
                .bytes => 1,
                .uneven => 1 + (iteration * 13 % 97),
            };
            window_end = @min(entity.len, accepted + count);
        }
        const scratch = &banks[iteration % banks.len];
        const available = window_end - accepted;
        @memcpy(scratch[0..available], entity[accepted..window_end]);
        const step = parser.next(scratch[0..available]) catch |failure| {
            outcome.failure = failure;
            check_bounds(&parser, &headers, &carry, header_length, boundary.len);
            check_terminal(&parser);
            return outcome;
        };
        if (step.consumed > available) @panic("multipart framing accepted beyond input");
        accepted += step.consumed;
        if (parser.total_bytes != accepted) @panic("multipart framing byte accounting diverged");
        if (step.event) |event| {
            check_borrows(event, parser.storage.headers, parser.storage.carry, scratch[0..available]);
            handle_event(&outcome, event);
            switch (event) {
                .part_data => |payload| {
                    if (payload.len == 0) @panic("multipart emitted empty payload");
                    if (invalid_ack) {
                        const before_total = parser.total_bytes;
                        const before_carry = carry;
                        const before_replay = parser.replay_cursor;
                        const before_length = parser.replay_len;
                        if (parser.accept_data(payload.len + 1)) |_| {
                            @panic("multipart accepted invalid acknowledgement");
                        } else |failure| {
                            if (failure != error.InvalidMultipartProgress) @panic("multipart invalid acknowledgement error changed");
                        }
                        if (parser.total_bytes != before_total or parser.replay_cursor != before_replay or parser.replay_len != before_length) @panic("invalid acknowledgement changed byte state");
                        if (!std.mem.eql(u8, &before_carry, &carry)) @panic("invalid acknowledgement changed carry");
                        check_terminal(&parser);
                        outcome.failure = error.InvalidMultipartProgress;
                        return outcome;
                    }
                    if (parser.pending == .input and payload.len > parser.limits.max_body_bytes - parser.total_bytes) @panic("multipart offered payload beyond logical budget");
                    const count = ack_count(schedule, iteration, payload.len);
                    append_payload(&outcome, payload[0..count]);
                    const advance = parser.accept_data(count) catch @panic("valid acknowledgement rejected");
                    if (advance != 0 and advance != count) @panic("multipart acknowledgement advanced by an invalid amount");
                    if (advance > window_end - accepted) @panic("multipart acknowledgement escaped current input");
                    accepted += advance;
                    if (parser.total_bytes != accepted) @panic("multipart payload byte accounting diverged");
                },
                else => {},
            }
        }
        // Reconstruct the exact unaccepted suffix on every call. Any retained
        // input pointer observes poison before it can be reused.
        @memset(scratch[0..available], 0xdc);
        check_bounds(&parser, &headers, &carry, header_length, boundary.len);
        if (step.event != null) continue;
        if (accepted < entity.len) {
            if (step.consumed == 0) @panic("multipart stalled with real input");
            continue;
        }
        parser.finish() catch |failure| {
            outcome.failure = failure;
            check_terminal(&parser);
            return outcome;
        };
        if (outcome.count != 0 and !outcome.records[outcome.count - 1].ended) @panic("multipart finished with an active part");
        check_terminal(&parser);
        return outcome;
    }
}

fn ack_count(schedule: Schedule, iteration: usize, length: usize) usize {
    return switch (schedule) {
        .whole => length,
        .bytes => if (iteration % 3 == 0) 0 else 1,
        .uneven => if (iteration % 5 == 0) 0 else 1 + (iteration % length),
    };
}

fn handle_event(outcome: *Outcome, event: multipart.StreamingEvent) void {
    switch (event) {
        .part_begin => |metadata| {
            if (outcome.count == outcome.records.len) @panic("multipart exceeded part bound");
            if (outcome.count != 0 and !outcome.records[outcome.count - 1].ended) @panic("multipart began a second active part");
            outcome.records[outcome.count] = .{
                .name = copy_field(outcome, metadata.name),
                .filename = copy_field(outcome, metadata.filename),
                .content_type = copy_field(outcome, metadata.content_type),
                .data_offset = outcome.payload_length,
            };
            outcome.count += 1;
        },
        .part_data => {
            if (outcome.count == 0 or outcome.records[outcome.count - 1].ended) @panic("multipart emitted payload outside a part");
        },
        .part_end => {
            if (outcome.count == 0 or outcome.records[outcome.count - 1].ended) @panic("multipart ended an inactive part");
            outcome.records[outcome.count - 1].ended = true;
        },
    }
}

fn copy_field(outcome: *Outcome, value: ?[]const u8) Field {
    const offset = outcome.metadata_length;
    const bytes = value orelse return .{ .offset = offset, .length = 0, .present = false };
    if (bytes.len > outcome.metadata.len - offset) @panic("multipart metadata escaped logical input bound");
    @memcpy(outcome.metadata[offset..][0..bytes.len], bytes);
    outcome.metadata_length += bytes.len;
    return .{ .offset = offset, .length = bytes.len, .present = true };
}

fn append_payload(outcome: *Outcome, payload: []const u8) void {
    if (payload.len > outcome.payload.len - outcome.payload_length) @panic("multipart emitted more data than input");
    @memcpy(outcome.payload[outcome.payload_length..][0..payload.len], payload);
    outcome.payload_length += payload.len;
    outcome.records[outcome.count - 1].data_length += payload.len;
}

fn check_bounds(parser: *const multipart.StreamingParser, headers: *const [header_capacity + 2]u8, carry: *const [76]u8, header_length: usize, boundary_length: usize) void {
    if (parser.total_bytes > parser.limits.max_body_bytes) @panic("multipart escaped logical byte limit");
    if (parser.parts > parser.limits.max_parts) @panic("multipart escaped part limit");
    if (parser.header_len > header_length) @panic("multipart escaped header storage");
    if (parser.storage.carry.len != boundary_length + 4) @panic("multipart changed carry bound");
    if (parser.replay_cursor > parser.replay_len or parser.replay_len > boundary_length + 5) @panic("multipart replay escaped reconstructed delimiter bound");
    if (parser.pending == .replay and parser.pending_len > boundary_length + 4) @panic("multipart offered replay beyond carry");
    if (headers[0] != guard) @panic("multipart wrote before header storage");
    for (headers[header_length + 1 ..]) |byte| if (byte != guard) @panic("multipart wrote after header storage");
    if (carry[0] != guard) @panic("multipart wrote before carry storage");
    for (carry[boundary_length + 5 ..]) |byte| if (byte != guard) @panic("multipart wrote after carry storage");
}

fn check_terminal(parser: *multipart.StreamingParser) void {
    if (parser.next("ignored")) |_| @panic("multipart terminal next succeeded") else |failure| {
        if (failure != error.InvalidMultipartState) @panic("multipart terminal next error changed");
    }
    if (parser.accept_data(0)) |_| @panic("multipart terminal acknowledgement succeeded") else |failure| {
        if (failure != error.InvalidMultipartState) @panic("multipart terminal acknowledgement error changed");
    }
    if (parser.finish()) |_| @panic("multipart terminal finish succeeded") else |failure| {
        if (failure != error.InvalidMultipartState) @panic("multipart terminal finish error changed");
    }
}

fn compare(left: *const Outcome, right: *const Outcome) void {
    if (left.failure) |expected| {
        const actual = right.failure orelse @panic("multipart chunking changed failure into success");
        if (expected != actual) @panic("multipart chunking changed error tag");
    } else if (right.failure != null) @panic("multipart chunking changed success into failure");
    if (left.count != right.count) @panic("multipart chunking changed part count");
    for (left.records[0..left.count], right.records[0..right.count]) |a, b| {
        compare_field(left, right, a.name, b.name);
        compare_field(left, right, a.filename, b.filename);
        compare_field(left, right, a.content_type, b.content_type);
        const common = @min(a.data_length, b.data_length);
        if (!std.mem.eql(u8, left.payload[a.data_offset..][0..common], right.payload[b.data_offset..][0..common])) @panic("multipart chunking changed payload bytes");
        if (left.failure == null and (a.data_length != b.data_length or a.ended != b.ended)) @panic("multipart chunking changed complete part");
    }
}

fn compare_field(left: *const Outcome, right: *const Outcome, a: Field, b: Field) void {
    if (a.present != b.present or a.length != b.length) @panic("multipart chunking changed metadata presence or size");
    if (!std.mem.eql(u8, left.metadata[a.offset..][0..a.length], right.metadata[b.offset..][0..b.length])) @panic("multipart chunking changed metadata bytes");
}

fn known_valid(input: []const u8, boundary: []const u8) void {
    const prefix = "preamble\r\n--";
    const headers = "\r\nContent-Disposition: form-data; name=\"a;\\\"b\"; filename=\"f\\\\x\"\r\nContent-Type: application/octet-stream\r\n\r\n";
    var entity: [max_input_size]u8 = undefined;
    var cursor: usize = 0;
    append(&entity, &cursor, prefix);
    append(&entity, &cursor, boundary);
    append(&entity, &cursor, headers);
    const payload_start = cursor;
    append(&entity, &cursor, "\r\n--");
    append(&entity, &cursor, boundary);
    append(&entity, &cursor, "X\r\r\n--");
    append(&entity, &cursor, boundary);
    append(&entity, &cursor, "-!");
    const count = @min(input.len, 1024);
    for (input[0..count]) |byte| {
        entity[cursor] = if (byte == '\r') '.' else byte;
        cursor += 1;
    }
    const payload_end = cursor;
    append(&entity, &cursor, "\r\n--");
    append(&entity, &cursor, boundary);
    append(&entity, &cursor, "--\r\nepilogue");
    const limits = multipart.StreamingLimits{ .max_body_bytes = cursor, .max_parts = 1, .max_part_headers = 2 };
    const whole = drive(entity[0..cursor], boundary, limits, header_capacity, .whole, false);
    const bytes = drive(entity[0..cursor], boundary, limits, header_capacity, .bytes, false);
    const uneven = drive(entity[0..cursor], boundary, limits, header_capacity, .uneven, false);
    compare(&whole, &bytes);
    compare(&whole, &uneven);
    if (whole.failure != null or whole.count != 1 or !whole.records[0].ended) @panic("multipart rejected known-valid entity");
    if (!std.mem.eql(u8, whole.payload[0..whole.payload_length], entity[payload_start..payload_end])) @panic("multipart known payload oracle mismatch");
    const record = whole.records[0];
    if (!std.mem.eql(u8, whole.metadata[record.name.offset..][0..record.name.length], "a;\"b")) @panic("multipart quoted name oracle mismatch");
    if (!record.filename.present or !std.mem.eql(u8, whole.metadata[record.filename.offset..][0..record.filename.length], "f\\x")) @panic("multipart quoted filename oracle mismatch");
    if (!record.content_type.present or !std.mem.eql(u8, whole.metadata[record.content_type.offset..][0..record.content_type.length], "application/octet-stream")) @panic("multipart content type oracle mismatch");
}

fn append(buffer: []u8, cursor: *usize, bytes: []const u8) void {
    if (bytes.len > buffer.len - cursor.*) @panic("multipart fixture overflowed");
    @memcpy(buffer[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn within(buffer: []const u8, bytes: []const u8) bool {
    const start = @intFromPtr(buffer.ptr);
    const pointer = @intFromPtr(bytes.ptr);
    if (pointer < start) return false;
    const offset = pointer - start;
    return offset <= buffer.len and bytes.len <= buffer.len - offset;
}

fn check_borrows(event: multipart.StreamingEvent, headers: []const u8, carry: []const u8, input: []const u8) void {
    switch (event) {
        .part_begin => |metadata| {
            if (!within(headers, metadata.name)) @panic("multipart name escaped caller headers");
            if (metadata.filename) |bytes| if (!within(headers, bytes)) @panic("multipart filename escaped caller headers");
            if (metadata.content_type) |bytes| if (!within(headers, bytes)) @panic("multipart content type escaped caller headers");
        },
        .part_data => |bytes| if (!within(carry, bytes) and !within(input, bytes)) @panic("multipart payload escaped caller storage"),
        .part_end => {},
    }
}
