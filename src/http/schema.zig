const std = @import("std");

pub const Rule = struct {
    min: ?i128 = null,
    max: ?i128 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
};

pub const IssueKind = enum {
    malformed_json,
    below_minimum,
    above_maximum,
    too_short,
    too_long,
};

pub const Issue = struct {
    field: []const u8 = "",
    kind: IssueKind = .malformed_json,
};

/// Parses T and enforces optional `pub const validation` field rules.
///
/// A schema may declare tags as an anonymous struct whose fields match data
/// fields and whose values are `Rule`, for example:
/// `pub const validation = .{ .name = Rule{ .min_length = 1 } };`.
pub fn validate_json(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
) !std.json.Parsed(T) {
    var issue = Issue{};
    return validate_json_detailed(T, allocator, input, &issue);
}

/// Detailed variant that identifies the first rejected field and constraint.
pub fn validate_json_detailed(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    issue: *Issue,
) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, input, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        issue.* = .{ .kind = .malformed_json };
        return error.MalformedJson;
    };
    errdefer parsed.deinit();
    try validate(T, parsed.value, issue);
    return parsed;
}

/// Pure constraint check for an already-decoded value.
pub fn validate(comptime T: type, value: T, issue: *Issue) !void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.SchemaMustBeStruct;
    if (!@hasDecl(T, "validation")) return;

    const rules = T.validation;
    inline for (type_info.@"struct".fields) |field| {
        if (!@hasField(@TypeOf(rules), field.name)) continue;
        const rule: Rule = @field(rules, field.name);
        try validate_field(field.name, @field(value, field.name), rule, issue);
    }
}

fn validate_field(
    field_name: []const u8,
    value: anytype,
    rule: Rule,
    issue: *Issue,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const numeric: i128 = std.math.cast(i128, value) orelse {
                issue.* = .{ .field = field_name, .kind = .above_maximum };
                return error.ConstraintViolation;
            };
            if (rule.min) |minimum| {
                if (numeric < minimum) {
                    issue.* = .{ .field = field_name, .kind = .below_minimum };
                    return error.ConstraintViolation;
                }
            }
            if (rule.max) |maximum| {
                if (numeric > maximum) {
                    issue.* = .{ .field = field_name, .kind = .above_maximum };
                    return error.ConstraintViolation;
                }
            }
        },
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child != u8) return;
            if (rule.min_length) |minimum| {
                if (value.len < minimum) {
                    issue.* = .{ .field = field_name, .kind = .too_short };
                    return error.ConstraintViolation;
                }
            }
            if (rule.max_length) |maximum| {
                if (value.len > maximum) {
                    issue.* = .{ .field = field_name, .kind = .too_long };
                    return error.ConstraintViolation;
                }
            }
        },
        .optional => {
            if (value) |present| try validate_field(field_name, present, rule, issue);
        },
        else => {},
    }
}
