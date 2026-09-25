const std = @import("std");

/// Maximum accepted route path length in bytes.
pub const max_route_path_size = 2048;

/// Static and dynamic shape of one candidate route path.
pub const PatternInfo = struct {
    dynamic: bool = false,
    static_bytes: u16 = 0,
    parameter_count: u8 = 0,
    has_wildcard: bool = false,
};

/// Reports whether a route path is absolute, within `max_path_size` bytes,
/// and free of query, fragment, and control separators.
pub fn valid_path(path: []const u8, max_path_size: usize) bool {
    if (path.len == 0 or path.len > max_path_size) return false;
    if (path[0] != '/') return false;
    if (std.mem.indexOfAny(u8, path, "?#\r\n") != null) return false;
    return true;
}

/// Validates a route path against `max_path_size`, classifies its static and
/// parameter segments, and rejects patterns needing more than `max_params`
/// captures so registration fails closed for the configured capacity.
pub fn analyze_pattern(path: []const u8, max_path_size: usize, max_params: usize) !PatternInfo {
    if (!valid_path(path, max_path_size)) return error.InvalidRoutePath;

    var info = PatternInfo{};
    var cursor: usize = 1;
    while (cursor <= path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, cursor, '/') orelse path.len;
        const segment = path[cursor..end];
        if (segment.len != 0 and (segment[0] == ':' or segment[0] == '*')) {
            if (segment.len == 1 or !valid_parameter_name(segment[1..])) {
                return error.InvalidRoutePattern;
            }
            info.dynamic = true;
            // The 255 guard keeps the u8 counter from overflowing when a
            // caller configures more captures than the counter can hold.
            if (info.parameter_count == std.math.maxInt(u8) or
                @as(usize, info.parameter_count) >= max_params)
            {
                return error.RouteParameterCapacityReached;
            }
            info.parameter_count += 1;
            if (segment[0] == '*') {
                if (end != path.len) return error.InvalidRoutePattern;
                info.has_wildcard = true;
            }
        } else {
            if (segment.len > std.math.maxInt(u16) - info.static_bytes) {
                return error.InvalidRoutePattern;
            }
            info.static_bytes += @intCast(segment.len);
        }

        if (end == path.len) break;
        cursor = end + 1;
    }
    if (duplicate_parameter_name(path)) return error.InvalidRoutePattern;
    return info;
}

fn valid_parameter_name(name: []const u8) bool {
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn duplicate_parameter_name(pattern: []const u8) bool {
    var outer: usize = 1;
    while (outer < pattern.len) {
        const outer_end = std.mem.indexOfScalarPos(u8, pattern, outer, '/') orelse pattern.len;
        const outer_segment = pattern[outer..outer_end];
        if (outer_segment.len > 1 and (outer_segment[0] == ':' or outer_segment[0] == '*')) {
            var inner = outer_end + @as(usize, @intFromBool(outer_end < pattern.len));
            while (inner < pattern.len) {
                const inner_end = std.mem.indexOfScalarPos(u8, pattern, inner, '/') orelse pattern.len;
                const inner_segment = pattern[inner..inner_end];
                if (inner_segment.len > 1 and
                    (inner_segment[0] == ':' or inner_segment[0] == '*') and
                    std.mem.eql(u8, outer_segment[1..], inner_segment[1..]))
                {
                    return true;
                }
                if (inner_end == pattern.len) break;
                inner = inner_end + 1;
            }
        }
        if (outer_end == pattern.len) break;
        outer = outer_end + 1;
    }
    return false;
}
