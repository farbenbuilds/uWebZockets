//! PostgreSQL protocol 3.0 framing and frontend serialization into caller storage.
const std = @import("std");
const types = @import("types.zig");
const SqlError = types.SqlError;

/// One complete borrowed backend message.
pub const Frame = struct { tag: u8, payload: []const u8, consumed: usize };
/// Describe and Close distinguish statement names from portal names.
pub const Target = enum(u8) { statement = 'S', portal = 'P' };

/// Incomplete live input returns null; invalid lengths are rejected before buffering.
pub fn decode(input: []const u8, max_message_bytes: usize) SqlError!?Frame {
    if (input.len < 5) return null;
    const length = std.mem.readInt(u32, input[1..5], .big);
    if (length < 4 or length > std.math.maxInt(i32)) return error.InvalidMessage;
    if (length > max_message_bytes or @as(u64, length) + 1 > max_message_bytes) return error.MessageTooLarge;
    const consumed: usize = @as(usize, length) + 1;
    if (input.len < consumed) return null;
    return .{ .tag = input[0], .payload = input[5..consumed], .consumed = consumed };
}

/// EOF must occur exactly between messages, never inside a backend frame.
pub fn finish_eof(input: []const u8) SqlError!void {
    var offset: usize = 0;
    while (offset < input.len) {
        const frame = try decode(input[offset..], std.math.maxInt(i32)) orelse return error.TruncatedMessage;
        offset += frame.consumed;
    }
}

/// Mutable caller-buffer cursor; no growing storage or external effects.
const Encoder = struct {
    buffer: []u8,
    offset: usize = 0,

    fn bytes(self: *Encoder, value: []const u8) SqlError!void {
        if (value.len > self.buffer.len - self.offset) return error.BufferTooSmall;
        @memcpy(self.buffer[self.offset..][0..value.len], value);
        self.offset += value.len;
    }

    fn byte(self: *Encoder, value: u8) SqlError!void {
        if (self.offset == self.buffer.len) return error.BufferTooSmall;
        self.buffer[self.offset] = value;
        self.offset += 1;
    }

    fn integer(self: *Encoder, comptime T: type, value: T) SqlError!void {
        if (@sizeOf(T) > self.buffer.len - self.offset) return error.BufferTooSmall;
        std.mem.writeInt(T, self.buffer[self.offset..][0..@sizeOf(T)], value, .big);
        self.offset += @sizeOf(T);
    }

    fn string(self: *Encoder, value: []const u8) SqlError!void {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidString;
        try self.bytes(value);
        try self.byte(0);
    }

    fn begin(self: *Encoder, tag: u8) SqlError!void {
        try self.byte(tag);
        try self.integer(u32, 0);
    }

    fn finish(self: *Encoder) SqlError!usize {
        if (self.offset - 1 > std.math.maxInt(i32)) return error.MessageTooLarge;
        std.mem.writeInt(u32, self.buffer[1..5], @intCast(self.offset - 1), .big);
        return self.offset;
    }
};

/// Generates a protocol 3.0 startup packet; passwords are never startup properties.
pub fn startup(buffer: []u8, user: []const u8, database: []const u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.integer(u32, 0);
    try encoder.integer(u32, 196608);
    try encoder.string("user");
    try encoder.string(user);
    try encoder.string("database");
    try encoder.string(database);
    try encoder.string("client_encoding");
    try encoder.string("UTF8");
    try encoder.byte(0);
    if (encoder.offset > std.math.maxInt(i32)) return error.MessageTooLarge;
    std.mem.writeInt(u32, buffer[0..4], @intCast(encoder.offset), .big);
    return encoder.offset;
}

/// Requests TLS before sending startup credentials.
pub fn ssl_request(buffer: []u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.integer(u32, 8);
    try encoder.integer(u32, 80877103);
    return encoder.offset;
}

/// Encodes the raw password/SASL payload; MD5/cleartext payloads include their NUL.
pub fn password(buffer: []u8, payload: []const u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('p');
    try encoder.bytes(payload);
    return encoder.finish();
}

/// Encodes the selected SASL mechanism and initial response.
pub fn sasl_initial(buffer: []u8, mechanism: []const u8, response: []const u8) SqlError!usize {
    if (response.len > std.math.maxInt(i32)) return error.MessageTooLarge;
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('p');
    try encoder.string(mechanism);
    try encoder.integer(u32, @intCast(response.len));
    try encoder.bytes(response);
    return encoder.finish();
}

/// Defines a prepared statement without interpolating parameter data.
pub fn parse(buffer: []u8, statement: types.Statement) SqlError!usize {
    if (statement.param_oids.len > std.math.maxInt(u16)) return error.TooManyParameters;
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('P');
    try encoder.string(statement.name);
    try encoder.string(statement.sql);
    try encoder.integer(u16, @intCast(statement.param_oids.len));
    for (statement.param_oids) |oid| try encoder.integer(u32, oid);
    return encoder.finish();
}

/// Binds typed binary parameters and requests binary result fields.
pub fn bind(buffer: []u8, portal: []const u8, statement: []const u8, parameters: []const types.Param) SqlError!usize {
    if (parameters.len > std.math.maxInt(u16)) return error.TooManyParameters;
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('B');
    try encoder.string(portal);
    try encoder.string(statement);
    try encoder.integer(u16, 1);
    try encoder.integer(u16, 1);
    try encoder.integer(u16, @intCast(parameters.len));
    for (parameters) |parameter| try encode_parameter(&encoder, parameter.value);
    try encoder.integer(u16, 1);
    try encoder.integer(u16, 1);
    return encoder.finish();
}

fn encode_parameter(encoder: *Encoder, value: types.Value) SqlError!void {
    if (value == .null) {
        try encoder.integer(i32, -1);
        return;
    }
    const length_offset = encoder.offset;
    try encoder.integer(u32, 0);
    switch (value) {
        .null => unreachable,
        .bool => |v| try encoder.byte(@intFromBool(v)),
        .int2 => |v| try encoder.integer(i16, v),
        .int4 => |v| try encoder.integer(i32, v),
        .int8 => |v| try encoder.integer(i64, v),
        .float4 => |v| try encoder.integer(u32, @bitCast(v)),
        .float8 => |v| try encoder.integer(u64, @bitCast(v)),
        .text, .varchar, .bytea => |v| try encoder.bytes(v),
        .timestamp => |v| try encoder.integer(i64, v.microseconds),
        .date => |v| try encoder.integer(i32, v.days),
        .uuid => |v| try encoder.bytes(&v.bytes),
        .numeric => |v| try encode_numeric(encoder, v),
    }
    const length = encoder.offset - length_offset - 4;
    if (length > std.math.maxInt(i32)) return error.FieldTooLarge;
    std.mem.writeInt(u32, encoder.buffer[length_offset..][0..4], @intCast(length), .big);
}

fn encode_numeric(encoder: *Encoder, numeric: types.Numeric) SqlError!void {
    if (numeric.digits.len % 2 != 0 or numeric.digits.len / 2 > 32767) return error.NumericTooLarge;
    if (numeric.scale > 16383) return error.InvalidValue;
    if (@intFromEnum(numeric.sign) >= 0xc000 and numeric.digits.len != 0) return error.InvalidValue;
    var offset: usize = 0;
    while (offset < numeric.digits.len) : (offset += 2) {
        if (std.mem.readInt(u16, numeric.digits[offset..][0..2], .big) >= 10000) return error.InvalidValue;
    }
    try encoder.integer(u16, @intCast(numeric.digits.len / 2));
    try encoder.integer(i16, numeric.weight);
    try encoder.integer(u16, @intFromEnum(numeric.sign));
    try encoder.integer(u16, numeric.scale);
    try encoder.bytes(numeric.digits);
}

/// Requests metadata for a statement or bound portal.
pub fn describe(buffer: []u8, target: Target, name: []const u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('D');
    try encoder.byte(@intFromEnum(target));
    try encoder.string(name);
    return encoder.finish();
}

/// Executes a bound portal with a caller-selected row limit, zero meaning all.
pub fn execute(buffer: []u8, portal: []const u8, max_rows: u32) SqlError!usize {
    if (max_rows > std.math.maxInt(i32)) return error.InvalidValue;
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('E');
    try encoder.string(portal);
    try encoder.integer(u32, max_rows);
    return encoder.finish();
}

/// Ends an extended-query batch and restores ReadyForQuery synchronization.
pub fn sync(buffer: []u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('S');
    return encoder.finish();
}

/// Closes an evicted server statement or portal before reusing its cache name.
pub fn close(buffer: []u8, target: Target, name: []const u8) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.begin('C');
    try encoder.byte(@intFromEnum(target));
    try encoder.string(name);
    return encoder.finish();
}

/// Cancellation runs over a separate connection with the backend's secret key.
pub fn cancel(buffer: []u8, process_id: u32, secret_key: u32) SqlError!usize {
    var encoder = Encoder{ .buffer = buffer };
    try encoder.integer(u32, 16);
    try encoder.integer(u32, 80877102);
    try encoder.integer(u32, process_id);
    try encoder.integer(u32, secret_key);
    return encoder.offset;
}
