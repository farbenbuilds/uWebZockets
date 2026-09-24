const std = @import("std");

/// Bounds and membership constraints applied to one decoded field.
pub const Rule = struct {
    min: ?i128 = null,
    max: ?i128 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    /// Float bounds; integer min/max are ignored for float fields.
    min_float: ?f64 = null,
    /// Float bounds; integer min/max are ignored for float fields.
    max_float: ?f64 = null,
    /// Item bounds for arrays and non-u8 slices.
    min_items: ?usize = null,
    /// Item bounds for arrays and non-u8 slices.
    max_items: ?usize = null,
    /// Allowed enum tag names or whole string values; empty disables the check.
    allowed: []const []const u8 = &.{},
};

/// Classification of the first rejected constraint or parse failure.
pub const IssueKind = enum {
    malformed_json,
    below_minimum,
    above_maximum,
    too_short,
    too_long,
    syntax_error,
    unexpected_end_of_input,
    unexpected_token,
    invalid_number,
    number_overflow,
    invalid_enum_tag,
    length_mismatch,
    missing_field,
    duplicate_field,
    unknown_field,
    too_few_items,
    too_many_items,
};

/// First rejected constraint, naming the offending field when decoded.
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
        issue.* = .{ .kind = parse_issue_kind(err) };
        return error.MalformedJson;
    };
    errdefer parsed.deinit();
    try validate(T, parsed.value, issue);
    return parsed;
}

/// Maps a `std.json` parse error to the closest schema issue kind.
fn parse_issue_kind(err: anyerror) IssueKind {
    return switch (err) {
        error.SyntaxError => .syntax_error,
        error.UnexpectedEndOfInput => .unexpected_end_of_input,
        error.UnexpectedToken => .unexpected_token,
        error.InvalidNumber, error.InvalidCharacter => .invalid_number,
        error.Overflow => .number_overflow,
        error.InvalidEnumTag => .invalid_enum_tag,
        error.LengthMismatch => .length_mismatch,
        error.MissingField => .missing_field,
        error.DuplicateField => .duplicate_field,
        error.UnknownField => .unknown_field,
        else => .malformed_json,
    };
}

/// Deepest nested schema level walked before validation stops silently.
pub const max_nested_depth = 4;

/// Pure constraint check for an already-decoded value.
pub fn validate(comptime T: type, value: T, issue: *Issue) !void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.SchemaMustBeStruct;
    if (!@hasDecl(T, "validation")) return;
    try validate_at_depth(T, value, issue, 0);
}

/// Applies direct rules and descends into fields with their own validation.
///
/// The depth bound is runtime rather than comptime so self-referential schema
/// types cannot explode comptime instantiation or recurse without end.
fn validate_at_depth(comptime T: type, value: T, issue: *Issue, depth: usize) !void {
    if (depth >= max_nested_depth) return;
    const rules = T.validation;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_value = @field(value, field.name);
        if (@hasField(@TypeOf(rules), field.name)) {
            const rule: Rule = @field(rules, field.name);
            try validate_field(field.name, field_value, rule, issue);
        }
        try validate_nested(field_value, issue, depth + 1);
    }
}

/// True when `T` is a declaration container carrying its own schema rules.
fn declares_validation(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "validation"),
        else => false,
    };
}

/// Recurses into nested structs and collection elements with their own rules.
fn validate_nested(value: anytype, issue: *Issue, depth: usize) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (!comptime declares_validation(T)) return;
            try validate_at_depth(T, value, issue, depth);
        },
        .array => |array| {
            if (!comptime declares_validation(array.child)) return;
            for (value) |element| try validate_at_depth(array.child, element, issue, depth);
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) return;
            if (!comptime declares_validation(pointer.child)) return;
            for (value) |element| try validate_at_depth(pointer.child, element, issue, depth);
        },
        .optional => {
            if (value) |present| try validate_nested(present, issue, depth);
        },
        else => {},
    }
}

/// Applies `rule` to one decoded field; `value` is genuinely polymorphic
/// because the field type is only known at the comptime call site.
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
        .float, .comptime_float => {
            const numeric: f64 = @floatCast(value);
            if (rule.min_float) |minimum| {
                if (numeric < minimum) {
                    issue.* = .{ .field = field_name, .kind = .below_minimum };
                    return error.ConstraintViolation;
                }
            }
            if (rule.max_float) |maximum| {
                if (numeric > maximum) {
                    issue.* = .{ .field = field_name, .kind = .above_maximum };
                    return error.ConstraintViolation;
                }
            }
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) return;
            if (pointer.child == u8) {
                try validate_string_value(field_name, value, rule, issue);
                return;
            }
            try validate_item_bounds(field_name, value.len, rule, issue);
        },
        .array => {
            try validate_item_bounds(field_name, value.len, rule, issue);
        },
        .@"enum" => {
            try validate_allowed_tag(field_name, value, rule, issue);
        },
        .optional => {
            if (value) |present| try validate_field(field_name, present, rule, issue);
        },
        else => {},
    }
}

fn validate_string_value(field_name: []const u8, value: []const u8, rule: Rule, issue: *Issue) !void {
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
    if (rule.allowed.len == 0) return;
    for (rule.allowed) |allowed_value| {
        if (std.mem.eql(u8, value, allowed_value)) return;
    }
    issue.* = .{ .field = field_name, .kind = .invalid_enum_tag };
    return error.ConstraintViolation;
}

fn validate_allowed_tag(field_name: []const u8, value: anytype, rule: Rule, issue: *Issue) !void {
    if (rule.allowed.len == 0) return;
    const tag = @tagName(value);
    for (rule.allowed) |allowed_value| {
        if (std.mem.eql(u8, tag, allowed_value)) return;
    }
    issue.* = .{ .field = field_name, .kind = .invalid_enum_tag };
    return error.ConstraintViolation;
}

fn validate_item_bounds(field_name: []const u8, count: usize, rule: Rule, issue: *Issue) !void {
    if (rule.min_items) |minimum| {
        if (count < minimum) {
            issue.* = .{ .field = field_name, .kind = .too_few_items };
            return error.ConstraintViolation;
        }
    }
    if (rule.max_items) |maximum| {
        if (count > maximum) {
            issue.* = .{ .field = field_name, .kind = .too_many_items };
            return error.ConstraintViolation;
        }
    }
}
