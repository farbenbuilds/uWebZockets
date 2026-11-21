//! Borrowed PostgreSQL rows and explicit typed mapping with caller-owned storage.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("pg_wire.zig");
const SqlError = types.SqlError;

/// One borrowed row; slices expire when the connection reuses the response slab.
pub const Row = struct {
    fields: []const types.Field,

    /// Decodes one field without allocating or guessing the SQL type.
    pub fn value(self: Row, index: usize) SqlError!types.Value {
        if (index >= self.fields.len) return error.ColumnNotFound;
        return decode_value(self.fields[index]);
    }

    /// Accepted types: Value, bool, i16/i32/i64, f32/f64, []const u8 and named SQL scalar types.
    pub fn get(self: Row, comptime T: type, index: usize) SqlError!T {
        const decoded = try self.value(index);
        if (T == types.Value) return decoded;
        if (decoded == .null) return error.NullValue;
        if (T == bool) return if (decoded == .bool) decoded.bool else error.TypeMismatch;
        if (T == i16) return if (decoded == .int2) decoded.int2 else error.TypeMismatch;
        if (T == i32) return if (decoded == .int4) decoded.int4 else error.TypeMismatch;
        if (T == i64) return if (decoded == .int8) decoded.int8 else error.TypeMismatch;
        if (T == f32) return if (decoded == .float4) decoded.float4 else error.TypeMismatch;
        if (T == f64) return if (decoded == .float8) decoded.float8 else error.TypeMismatch;
        if (T == types.Timestamp) return if (decoded == .timestamp) decoded.timestamp else error.TypeMismatch;
        if (T == types.Date) return if (decoded == .date) decoded.date else error.TypeMismatch;
        if (T == types.Uuid) return if (decoded == .uuid) decoded.uuid else error.TypeMismatch;
        if (T == types.Numeric) return if (decoded == .numeric) decoded.numeric else error.TypeMismatch;
        if (T == []const u8) return switch (decoded) {
            .text, .varchar, .bytea => |bytes| bytes,
            else => error.TypeMismatch,
        };
        @compileError("SQL Row.get supports only documented explicit SQL scalar types");
    }

    /// Copies field payloads for deferred use; caller owns both returned views.
    pub fn keep(self: Row, field_storage: []types.Field, byte_storage: []u8) SqlError!Row {
        if (self.fields.len > field_storage.len) return error.TooManyColumns;
        var total: usize = 0;
        for (self.fields) |field| {
            if (field.bytes) |bytes| {
                if (bytes.len > byte_storage.len - total) return error.BufferTooSmall;
                total += bytes.len;
            }
        }
        var offset: usize = 0;
        for (self.fields, 0..) |field, index| {
            field_storage[index] = field;
            if (field.bytes) |bytes| {
                @memcpy(byte_storage[offset..][0..bytes.len], bytes);
                field_storage[index].bytes = byte_storage[offset..][0..bytes.len];
                offset += bytes.len;
            }
        }
        return .{ .fields = field_storage[0..self.fields.len] };
    }
};

/// Iterator over complete DataRow frames retained in the connection's response slab.
pub const Rows = struct {
    data: []const u8,
    columns: []const types.Column,
    fields: []types.Field,
    limits: types.Limits = .{},
    offset: usize = 0,
    count: usize = 0,

    /// The previous Row's field array is overwritten on every successful call.
    pub fn next(self: *Rows) SqlError!?Row {
        if (self.data.len > self.limits.max_response_bytes) return error.ResponseTooLarge;
        if (self.offset == self.data.len) return null;
        if (self.offset > self.data.len) return error.InvalidMessage;
        if (self.count == self.limits.max_rows) return error.TooManyRows;
        const frame = try wire.decode(self.data[self.offset..], self.limits.max_message_bytes) orelse return error.TruncatedMessage;
        if (frame.tag != 'D') return error.InvalidMessage;
        const row = try decode_row(frame.payload, self.columns, self.fields, self.limits);
        self.offset += frame.consumed;
        self.count += 1;
        return row;
    }

    /// Rewinds iteration while retaining the same borrowed response slab.
    pub fn reset(self: *Rows) void {
        self.offset = 0;
        self.count = 0;
    }
};

/// Explicit mapper callback writes an application-defined record into aligned caller storage.
pub const FromRowCallback = *const fn (Row, *anyopaque) SqlError!void;
/// Explicit parameter callback fills caller-owned parameter storage.
pub const ToParamCallback = *const fn (*const anyopaque, []types.Param) SqlError![]const types.Param;
/// A mapper declares its expected columns and never generates a schema by reflection.
pub const FromRow = struct { columns: []const types.Column, map: FromRowCallback };
/// A parameter mapper retains explicit type conversion in application code.
pub const ToParam = struct { encode: ToParamCallback };

/// Checks a mapping at startup before any application destination is written.
pub fn validate_mapping(expected: []const types.Column, actual: []const types.Column) SqlError!void {
    if (expected.len != actual.len) return error.TypeMismatch;
    for (expected, actual) |want, got| {
        if (!std.mem.eql(u8, want.name, got.name) or want.oid != got.oid) return error.TypeMismatch;
    }
}

/// Decodes RowDescription into caller-owned descriptors; names borrow the packet.
pub fn decode_columns(payload: []const u8, storage: []types.Column, limits: types.Limits) SqlError![]types.Column {
    if (payload.len < 2) return error.TruncatedMessage;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    if (count > storage.len or count > limits.max_columns) return error.TooManyColumns;
    var offset: usize = 2;
    for (storage[0..count]) |*column| {
        const name_end = std.mem.indexOfScalarPos(u8, payload, offset, 0) orelse return error.TruncatedMessage;
        const name = payload[offset..name_end];
        if (name.len > limits.max_field_bytes) return error.FieldTooLarge;
        offset = name_end + 1;
        if (payload.len - offset < 18) return error.TruncatedMessage;
        const format = std.mem.readInt(u16, payload[offset + 16 ..][0..2], .big);
        if (format > 1) return error.InvalidMessage;
        column.* = .{
            .name = name,
            .oid = std.mem.readInt(u32, payload[offset + 6 ..][0..4], .big),
            .format = @enumFromInt(format),
        };
        offset += 18;
    }
    if (offset != payload.len) return error.InvalidMessage;
    return storage[0..count];
}

/// Validates every signed field length before creating borrowed slices.
pub fn decode_row(payload: []const u8, columns: []const types.Column, storage: []types.Field, limits: types.Limits) SqlError!Row {
    if (payload.len < 2) return error.TruncatedMessage;
    const count = std.mem.readInt(u16, payload[0..2], .big);
    if (count != columns.len) return error.TypeMismatch;
    if (count > storage.len or count > limits.max_columns) return error.TooManyColumns;
    var offset: usize = 2;
    for (columns, storage[0..count]) |column, *field| {
        if (payload.len - offset < 4) return error.TruncatedMessage;
        const length = std.mem.readInt(i32, payload[offset..][0..4], .big);
        offset += 4;
        if (length < -1) return error.InvalidMessage;
        field.* = .{ .bytes = null, .oid = column.oid, .format = column.format };
        if (length == -1) continue;
        const size: usize = @intCast(length);
        if (size > limits.max_field_bytes) return error.FieldTooLarge;
        if (size > payload.len - offset) return error.TruncatedMessage;
        field.bytes = payload[offset..][0..size];
        offset += size;
    }
    if (offset != payload.len) return error.InvalidMessage;
    return .{ .fields = storage[0..count] };
}

/// Decodes the documented PostgreSQL scalar OIDs with exact binary widths.
pub fn decode_value(field: types.Field) SqlError!types.Value {
    const bytes = field.bytes orelse return .null;
    if (field.format == .text) return decode_text(field.oid, bytes);
    return switch (field.oid) {
        16 => .{ .bool = try decode_bool(bytes) },
        21 => .{ .int2 = try read_integer(i16, bytes) },
        23 => .{ .int4 = try read_integer(i32, bytes) },
        20 => .{ .int8 = try read_integer(i64, bytes) },
        700 => .{ .float4 = @bitCast(try read_integer(u32, bytes)) },
        701 => .{ .float8 = @bitCast(try read_integer(u64, bytes)) },
        25 => .{ .text = try utf8(bytes) },
        1043 => .{ .varchar = try utf8(bytes) },
        17 => .{ .bytea = bytes },
        1114, 1184 => .{ .timestamp = .{ .microseconds = try read_integer(i64, bytes) } },
        1082 => .{ .date = .{ .days = try read_integer(i32, bytes) } },
        2950 => .{ .uuid = .{ .bytes = try decode_uuid(bytes) } },
        1700 => .{ .numeric = try decode_numeric(bytes) },
        else => error.UnsupportedType,
    };
}

fn utf8(bytes: []const u8) SqlError![]const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidValue;
    return bytes;
}

fn read_integer(comptime T: type, bytes: []const u8) SqlError!T {
    if (bytes.len != @sizeOf(T)) return error.InvalidValue;
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

fn decode_bool(bytes: []const u8) SqlError!bool {
    if (bytes.len != 1 or bytes[0] > 1) return error.InvalidValue;
    return bytes[0] == 1;
}

fn decode_uuid(bytes: []const u8) SqlError![16]u8 {
    if (bytes.len != 16) return error.InvalidValue;
    return bytes[0..16].*;
}

fn decode_numeric(bytes: []const u8) SqlError!types.Numeric {
    if (bytes.len < 8) return error.InvalidValue;
    const count = std.mem.readInt(i16, bytes[0..2], .big);
    if (count < 0 or @as(usize, @intCast(count)) * 2 != bytes.len - 8) return error.InvalidValue;
    const sign = std.enums.fromInt(types.NumericSign, std.mem.readInt(u16, bytes[4..6], .big)) orelse return error.InvalidValue;
    const scale = std.mem.readInt(u16, bytes[6..8], .big);
    if (scale > 16383) return error.InvalidValue;
    if (@intFromEnum(sign) >= 0xc000 and count != 0) return error.InvalidValue;
    var offset: usize = 8;
    while (offset < bytes.len) : (offset += 2) {
        if (std.mem.readInt(u16, bytes[offset..][0..2], .big) >= 10000) return error.InvalidValue;
    }
    return .{ .digits = bytes[8..], .weight = std.mem.readInt(i16, bytes[2..4], .big), .scale = scale, .sign = sign };
}

fn decode_text(oid: u32, bytes: []const u8) SqlError!types.Value {
    return switch (oid) {
        16 => if (std.mem.eql(u8, bytes, "t")) .{ .bool = true } else if (std.mem.eql(u8, bytes, "f")) .{ .bool = false } else error.InvalidValue,
        21 => .{ .int2 = std.fmt.parseInt(i16, bytes, 10) catch return error.InvalidValue },
        23 => .{ .int4 = std.fmt.parseInt(i32, bytes, 10) catch return error.InvalidValue },
        20 => .{ .int8 = std.fmt.parseInt(i64, bytes, 10) catch return error.InvalidValue },
        700 => .{ .float4 = std.fmt.parseFloat(f32, bytes) catch return error.InvalidValue },
        701 => .{ .float8 = std.fmt.parseFloat(f64, bytes) catch return error.InvalidValue },
        25 => .{ .text = try utf8(bytes) },
        1043 => .{ .varchar = try utf8(bytes) },
        else => error.UnsupportedType,
    };
}
