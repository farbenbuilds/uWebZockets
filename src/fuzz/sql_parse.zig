//! Allocation-free fuzz invariants for peer frames, binary values, and history.
const std = @import("std");
const wire = @import("../sql/pg_wire.zig");
const rows = @import("../sql/rows.zig");
const types = @import("../sql/types.zig");
const migrate = @import("../sql/migrate.zig");

pub const max_input_bytes = 4096;

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_bytes) return;
    fuzz_frames(input);
    fuzz_value(input);
    fuzz_checksum(input);
}

fn fuzz_frames(input: []const u8) void {
    var offset: usize = 0;
    while (offset < input.len) {
        const frame = wire.decode(input[offset..], max_input_bytes) catch return;
        const complete = frame orelse return;
        if (complete.consumed < 5 or complete.consumed > input.len - offset) @panic("SQL frame escaped input");
        var columns: [8]types.Column = undefined;
        if (complete.tag == 'T') {
            const decoded = rows.decode_columns(complete.payload, &columns, .{}) catch return;
            for (decoded) |column| {
                if (!within(input, column.name)) @panic("SQL column escaped input");
            }
        }
        if (complete.tag == 'D') {
            var fields: [1]types.Field = undefined;
            const row = rows.decode_row(complete.payload, &.{.{ .name = "value", .oid = 17 }}, &fields, .{}) catch return;
            if (row.fields[0].bytes) |bytes| {
                if (!within(input, bytes)) @panic("SQL field escaped input");
            }
        }
        offset += complete.consumed;
    }
}

fn fuzz_value(input: []const u8) void {
    if (input.len == 0) return;
    const oids = [_]u32{ 16, 21, 23, 20, 700, 701, 25, 1043, 17, 1114, 1082, 2950, 1700 };
    const oid = oids[input[0] % oids.len];
    const decoded = rows.decode_value(.{ .bytes = input[1..], .oid = oid }) catch return;
    switch (decoded) {
        .text, .varchar, .bytea => |bytes| if (!within(input, bytes)) {
            @panic("SQL scalar escaped input");
        },
        .numeric => |numeric| if (!within(input, numeric.digits)) {
            @panic("SQL numeric escaped input");
        },
        else => {},
    }
}

fn fuzz_checksum(input: []const u8) void {
    const checksum = migrate.parse_checksum(input) catch return;
    var encoded: [64]u8 = undefined;
    migrate.encode_checksum(checksum, &encoded);
    const roundtrip = migrate.parse_checksum(&encoded) catch @panic("SQL checksum encoder produced invalid text");
    if (!std.mem.eql(u8, &checksum, &roundtrip)) @panic("SQL checksum changed on roundtrip");
}

fn within(input: []const u8, bytes: []const u8) bool {
    const start = @intFromPtr(input.ptr);
    const pointer = @intFromPtr(bytes.ptr);
    if (pointer < start or pointer > start + input.len) return false;
    return bytes.len <= start + input.len - pointer;
}
