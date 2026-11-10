const std = @import("std");

/// Limits cover the whole entity, all parts, and every field in each part.
pub const StreamingLimits = struct {
    max_body_bytes: u64,
    max_parts: u32,
    max_part_headers: u16,
};

/// Stable exclusive working memory; neither slice may overlap current input.
pub const StreamingStorage = struct {
    headers: []u8,
    carry: []u8,
};

/// Normalized metadata borrows header storage until the next parser mutation.
pub const PartMeta = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
};

/// Data borrows current input or caller carry until acknowledgement.
pub const StreamingEvent = union(enum) {
    part_begin: PartMeta,
    part_data: []const u8,
    part_end: void,
};

/// Only consumed bytes are accepted; data additionally requires accept_data.
pub const StreamingStep = struct {
    consumed: usize,
    event: ?StreamingEvent = null,
};

pub const StreamingError = error{
    InvalidMultipartBoundary,
    InvalidMultipartStorage,
    InvalidMultipartLimits,
    MultipartBodyTooLarge,
    MultipartHeadersTooLarge,
    TooManyMultipartParts,
    TooManyPartHeaders,
    InvalidMultipartHeaders,
    MissingContentDisposition,
    InvalidContentDisposition,
    MissingPartName,
    IncompleteMultipartBody,
    InvalidMultipartProgress,
    InvalidMultipartState,
};

const State = enum { preamble, headers, body, epilogue, done, failed };
const Pending = enum { none, input, replay };
const Suffix = enum { none, cr, dash };

/// Pure incremental recognition of ADR 0011's exact-suffix multipart subset.
/// RFC 2046 section 5.1.1 transport padding is deliberately unsupported (MP-L1).
/// The parser never retains input pointers. Reoffer every unaccepted suffix,
/// which may move; keep working storage stable, exclusive, and disjoint.
pub const StreamingParser = struct {
    limits: StreamingLimits,
    storage: StreamingStorage,
    total_bytes: u64 = 0,
    header_len: usize = 0,
    matched: usize = 0,
    replay_len: usize = 0,
    replay_cursor: usize = 0,
    pending_len: usize = 0,
    parts: u32 = 0,
    boundary: [70]u8 = undefined,
    boundary_len: u8,
    header_tail: u3 = 0,
    state: State = .preamble,
    pending: Pending = .none,
    suffix: Suffix = .none,
    line_start: bool = true,

    pub fn init(boundary: []const u8, limits: StreamingLimits, storage: StreamingStorage) StreamingError!StreamingParser {
        if (!valid_boundary(boundary)) return error.InvalidMultipartBoundary;
        if (limits.max_parts == 0 or limits.max_part_headers == 0) return error.InvalidMultipartLimits;
        if (storage.headers.len == 0 or storage.carry.len < boundary.len + 4) return error.InvalidMultipartStorage;
        if (overlaps(storage.headers, storage.carry)) return error.InvalidMultipartStorage;
        var parser = StreamingParser{
            .limits = limits,
            .storage = .{ .headers = storage.headers, .carry = storage.carry[0 .. boundary.len + 4] },
            .boundary_len = @intCast(boundary.len),
        };
        @memcpy(parser.boundary[0..boundary.len], boundary);
        return parser;
    }

    /// Begin/end commit once. A data event commits nothing until accept_data.
    /// A call while data is pending is a terminal misuse, even with empty input.
    pub fn next(self: *StreamingParser, input: []const u8) StreamingError!StreamingStep {
        try self.require_active();
        errdefer self.fail();
        if (self.pending != .none) return error.InvalidMultipartState;
        if (overlaps(input, self.storage.headers) or overlaps(input, self.storage.carry)) return error.InvalidMultipartStorage;
        var offset: usize = 0;
        while (true) {
            if (self.replay_cursor < self.replay_len) return self.offer_replay(offset);
            if (offset == input.len) return .{ .consumed = offset };
            switch (self.state) {
                .preamble => try self.preamble_byte(input[offset]),
                .headers => {
                    if (try self.header_byte(input[offset])) |meta| {
                        return .{ .consumed = offset + 1, .event = .{ .part_begin = meta } };
                    }
                },
                .body => {
                    const step = try self.body_step(input[offset..]);
                    offset += step.consumed;
                    if (step.event) |event| return .{ .consumed = offset, .event = event };
                    continue;
                },
                .epilogue => {
                    try self.accept_bytes(input.len - offset);
                    return .{ .consumed = input.len };
                },
                .done, .failed => return error.InvalidMultipartState,
            }
            offset += 1;
        }
    }

    /// Returns additional real-input advancement; replay always advances zero.
    /// Invalid progress changes only terminal/event control, accepting no bytes.
    pub fn accept_data(self: *StreamingParser, consumed: usize) StreamingError!usize {
        try self.require_active();
        errdefer self.fail();
        if (self.pending == .none or consumed > self.pending_len) return error.InvalidMultipartProgress;
        const origin = self.pending;
        if (origin == .input) try self.accept_bytes(consumed);
        if (origin == .replay) self.replay_cursor += consumed;
        self.pending = .none;
        self.pending_len = 0;
        return if (origin == .input) consumed else 0;
    }

    /// Validates EOF once; never flushes an undecided prefix as payload.
    pub fn finish(self: *StreamingParser) StreamingError!void {
        try self.require_active();
        errdefer self.fail();
        if (self.pending != .none) return error.InvalidMultipartState;
        if (self.state != .epilogue or self.replay_cursor != self.replay_len) return error.IncompleteMultipartBody;
        self.state = .done;
    }

    fn require_active(self: *const StreamingParser) StreamingError!void {
        if (self.state == .done or self.state == .failed) return error.InvalidMultipartState;
    }

    fn fail(self: *StreamingParser) void {
        self.state = .failed;
        self.pending = .none;
    }

    fn accept_bytes(self: *StreamingParser, count: usize) StreamingError!void {
        try self.check_budget(count);
        self.total_bytes += @intCast(count);
    }

    fn check_budget(self: *const StreamingParser, count: usize) StreamingError!void {
        if (count > self.limits.max_body_bytes - self.total_bytes) return error.MultipartBodyTooLarge;
    }

    fn delimiter_len(self: *const StreamingParser) usize {
        return @as(usize, self.boundary_len) + 4;
    }

    fn delimiter_byte(self: *const StreamingParser, index: usize) u8 {
        return switch (index) {
            0 => '\r',
            1 => '\n',
            2, 3 => '-',
            else => self.boundary[index - 4],
        };
    }

    fn preamble_byte(self: *StreamingParser, byte: u8) StreamingError!void {
        try self.accept_bytes(1);
        if (self.matched == 0 and !self.line_start) {
            self.line_start = byte == '\n';
            return;
        }
        const opening_len = @as(usize, self.boundary_len) + 2;
        if (self.matched < opening_len) {
            if (byte == self.delimiter_byte(self.matched + 2)) {
                self.matched += 1;
                return;
            }
            self.reset_opening(byte);
            return;
        }
        if (self.suffix == .none) {
            self.suffix = suffix_start(byte);
            if (self.suffix == .none) self.reset_opening(byte);
            return;
        }
        if (valid_suffix(self.suffix, byte)) {
            self.complete_delimiter();
            return;
        }
        self.reset_opening(byte);
    }

    fn reset_opening(self: *StreamingParser, byte: u8) void {
        self.matched = 0;
        self.suffix = .none;
        self.line_start = byte == '\n';
    }

    fn complete_delimiter(self: *StreamingParser) void {
        self.state = if (self.suffix == .dash) .epilogue else .headers;
        self.matched = 0;
        self.suffix = .none;
        self.header_len = 0;
        self.header_tail = 0;
    }

    fn header_byte(self: *StreamingParser, byte: u8) StreamingError!?PartMeta {
        try self.accept_bytes(1);
        const separator = "\r\n\r\n";
        self.storage.carry[self.header_tail] = byte;
        self.header_tail += 1;
        while (!std.mem.eql(u8, self.storage.carry[0..self.header_tail], separator[0..self.header_tail])) {
            if (self.header_len == self.storage.headers.len) return error.MultipartHeadersTooLarge;
            self.storage.headers[self.header_len] = self.storage.carry[0];
            self.header_len += 1;
            self.header_tail -= 1;
            std.mem.copyForwards(u8, self.storage.carry[0..self.header_tail], self.storage.carry[1..][0..self.header_tail]);
        }
        if (self.header_tail != 4) return null;
        const meta = try parse_headers(self.storage.headers[0..self.header_len], self.limits.max_part_headers);
        if (self.parts == self.limits.max_parts) return error.TooManyMultipartParts;
        self.parts += 1;
        self.header_tail = 0;
        self.state = .body;
        return meta;
    }

    fn body_step(self: *StreamingParser, input: []const u8) StreamingError!StreamingStep {
        if (self.matched == 0) {
            const data_len = std.mem.indexOfScalar(u8, input, '\r') orelse input.len;
            if (data_len > 0) {
                try self.check_budget(data_len);
                self.pending = .input;
                self.pending_len = data_len;
                return .{ .consumed = 0, .event = .{ .part_data = input[0..data_len] } };
            }
        }
        if (self.matched < self.delimiter_len()) {
            if (input[0] != self.delimiter_byte(self.matched)) return self.false_delimiter();
            try self.accept_bytes(1);
            self.matched += 1;
            return .{ .consumed = 1 };
        }
        if (self.suffix == .none) {
            const suffix = suffix_start(input[0]);
            if (suffix == .none) return self.false_delimiter();
            try self.accept_bytes(1);
            self.suffix = suffix;
            return .{ .consumed = 1 };
        }
        if (!valid_suffix(self.suffix, input[0])) return self.false_delimiter();
        try self.accept_bytes(1);
        self.complete_delimiter();
        return .{ .consumed = 1, .event = .part_end };
    }

    fn false_delimiter(self: *StreamingParser) StreamingStep {
        // A held CR can start an overlapping delimiter. Replay everything else
        // before deciding whether the still-unaccepted mismatch is payload.
        self.replay_len = self.matched + @as(usize, @intFromBool(self.suffix == .dash));
        self.replay_cursor = 0;
        self.matched = if (self.suffix == .cr) 1 else 0;
        self.suffix = .none;
        return .{ .consumed = 0 };
    }

    fn offer_replay(self: *StreamingParser, consumed: usize) StreamingStep {
        const len = @min(self.replay_len - self.replay_cursor, self.storage.carry.len);
        for (self.storage.carry[0..len], self.replay_cursor..) |*byte, index| {
            byte.* = if (index < self.delimiter_len()) self.delimiter_byte(index) else '-';
        }
        self.pending = .replay;
        self.pending_len = len;
        return .{ .consumed = consumed, .event = .{ .part_data = self.storage.carry[0..len] } };
    }
};

fn suffix_start(byte: u8) Suffix {
    return switch (byte) {
        '\r' => .cr,
        '-' => .dash,
        else => .none,
    };
}

fn valid_suffix(suffix: Suffix, byte: u8) bool {
    return switch (suffix) {
        .cr => byte == '\n',
        .dash => byte == '-',
        .none => false,
    };
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const start_a = @intFromPtr(a.ptr);
    const start_b = @intFromPtr(b.ptr);
    return if (start_a <= start_b) start_b - start_a < a.len else start_a - start_b < b.len;
}

fn valid_boundary(boundary: []const u8) bool {
    if (boundary.len == 0 or boundary.len > 70) return false;
    if (boundary[boundary.len - 1] == ' ') return false;
    for (boundary) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '\'', '(', ')', '+', '_', ',', '-', '.', '/', ':', '=', '?', ' ' => {},
            else => return false,
        }
    }
    return true;
}

/// Separate policy from the permissive legacy scanner (RFC 7578 section 4.2).
fn parse_headers(headers: []u8, max_fields: u16) StreamingError!PartMeta {
    var meta = PartMeta{ .name = "", .filename = null, .content_type = null };
    var disposition_seen = false;
    var count: u16 = 0;
    var offset: usize = 0;
    while (offset < headers.len) {
        const end = if (std.mem.indexOf(u8, headers[offset..], "\r\n")) |relative| offset + relative else headers.len;
        const line = headers[offset..end];
        if (count == max_fields) return error.TooManyPartHeaders;
        count += 1;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidMultipartHeaders;
        if (!is_token(line[0..colon])) return error.InvalidMultipartHeaders;
        const raw_value = line[colon + 1 ..];
        const trimmed = std.mem.trim(u8, raw_value, " \t");
        const start = @intFromPtr(trimmed.ptr) - @intFromPtr(raw_value.ptr);
        const value = raw_value[start..][0..trimmed.len];
        if (!valid_field_value(value)) return error.InvalidMultipartHeaders;
        try recognized_header(line[0..colon], value, &meta, &disposition_seen);
        offset = if (end == headers.len) end else end + 2;
    }
    if (!disposition_seen) return error.MissingContentDisposition;
    return meta;
}

fn recognized_header(name: []const u8, value: []u8, meta: *PartMeta, disposition_seen: *bool) StreamingError!void {
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        if (meta.content_type != null) return error.InvalidMultipartHeaders;
        meta.content_type = value;
        return;
    }
    if (!std.ascii.eqlIgnoreCase(name, "content-disposition")) return;
    if (disposition_seen.*) return error.InvalidMultipartHeaders;
    disposition_seen.* = true;
    const disposition_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const disposition = std.mem.trim(u8, value[0..disposition_end], " \t");
    if (!std.ascii.eqlIgnoreCase(disposition, "form-data")) return error.InvalidContentDisposition;
    var offset = disposition_end;
    var part_name: ?[]const u8 = null;
    while (offset < value.len) {
        const parameter = try parse_parameter(value, &offset);
        if (std.ascii.eqlIgnoreCase(parameter.name, "name")) {
            if (part_name != null) return error.InvalidMultipartHeaders;
            part_name = parameter.value;
        }
        if (std.ascii.eqlIgnoreCase(parameter.name, "filename")) {
            if (meta.filename != null) return error.InvalidMultipartHeaders;
            meta.filename = parameter.value;
        }
    }
    meta.name = part_name orelse return error.MissingPartName;
}

/// Parameter slices stay within their original header span after pair decoding.
const Parameter = struct {
    name: []const u8,
    value: []const u8,
};

fn parse_parameter(input: []u8, offset: *usize) StreamingError!Parameter {
    if (input[offset.*] != ';') return error.InvalidMultipartHeaders;
    offset.* += 1;
    skip_ows(input, offset);
    const name_start = offset.*;
    while (offset.* < input.len and token_byte(input[offset.*])) offset.* += 1;
    const name = input[name_start..offset.*];
    if (name.len == 0) return error.InvalidMultipartHeaders;
    skip_ows(input, offset);
    if (offset.* == input.len or input[offset.*] != '=') return error.InvalidMultipartHeaders;
    offset.* += 1;
    skip_ows(input, offset);
    const value = try parameter_value(input, offset);
    skip_ows(input, offset);
    if (offset.* < input.len and input[offset.*] != ';') return error.InvalidMultipartHeaders;
    return .{ .name = name, .value = value };
}

fn parameter_value(input: []u8, offset: *usize) StreamingError![]const u8 {
    if (offset.* == input.len) return error.InvalidMultipartHeaders;
    if (input[offset.*] != '"') {
        const start = offset.*;
        while (offset.* < input.len and token_byte(input[offset.*])) offset.* += 1;
        if (offset.* == start) return error.InvalidMultipartHeaders;
        return input[start..offset.*];
    }
    offset.* += 1;
    const start = offset.*;
    var write = start;
    // RFC 9110 section 5.6.4: quoted pairs represent the following octet.
    while (offset.* < input.len) {
        var byte = input[offset.*];
        offset.* += 1;
        if (byte == '"') return input[start..write];
        if (byte == '\\') {
            if (offset.* == input.len) return error.InvalidMultipartHeaders;
            byte = input[offset.*];
            offset.* += 1;
        }
        if (!field_byte(byte)) return error.InvalidMultipartHeaders;
        input[write] = byte;
        write += 1;
    }
    return error.InvalidMultipartHeaders;
}

fn skip_ows(input: []const u8, offset: *usize) void {
    while (offset.* < input.len and (input[offset.*] == ' ' or input[offset.*] == '\t')) offset.* += 1;
}

fn is_token(input: []const u8) bool {
    if (input.len == 0) return false;
    for (input) |byte| if (!token_byte(byte)) return false;
    return true;
}

fn token_byte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn valid_field_value(input: []const u8) bool {
    for (input) |byte| if (!field_byte(byte)) return false;
    return true;
}

fn field_byte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}
