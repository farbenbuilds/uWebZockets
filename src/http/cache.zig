//! ETag and conditional-GET helpers for bounded responses.

const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Storage for one quoted 64-bit strong ETag: two quotes plus 16 hex digits.
pub const EtagBuffer = [18]u8;

/// RFC 9110 weak-validator prefix stripped before comparison.
const weak_prefix = "W/";

/// Header scanned for conditional GET validators.
const if_none_match = "if-none-match";

/// Writes a deterministic strong ETag for `content` (Wyhash-64, lowercase hex).
pub fn etag(content: []const u8, buffer: *EtagBuffer) []const u8 {
    const digest = std.hash.Wyhash.hash(0, content);
    // A u64 renders as at most 16 lowercase hex digits, and EtagBuffer holds 18
    // bytes with both quotes, so the write can never overflow.
    return std.fmt.bufPrint(buffer, "\"{x:0>16}\"", .{digest}) catch unreachable;
}

/// Reports whether If-None-Match on `request` matches `etag_value`.
pub fn is_not_modified(request: *const Request, etag_value: []const u8) bool {
    if (etag_value.len == 0) return false;
    var entries = request.header_entries();
    while (entries.next()) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.name, if_none_match)) continue;
        if (validator_matches(entry.value, etag_value)) return true;
    }
    return false;
}

/// Queues the ETag field and ends a 304 with no body.
pub fn not_modified(response: *Response, etag_value: []const u8) !void {
    try response.append_header("ETag", etag_value);
    return response.end("304 Not Modified", "");
}

/// Reports whether one If-None-Match field lists `etag_value` or `*`.
fn validator_matches(field: []const u8, etag_value: []const u8) bool {
    var candidates = std.mem.splitScalar(u8, field, ',');
    while (candidates.next()) |raw_candidate| {
        const candidate = std.mem.trim(u8, raw_candidate, " \t");
        if (std.mem.eql(u8, candidate, "*")) return true;
        if (std.mem.eql(u8, strip_weak(candidate), strip_weak(etag_value))) return true;
    }
    return false;
}

/// Strips the RFC 9110 `W/` weak-validator prefix when present.
fn strip_weak(value: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, weak_prefix)) return value[weak_prefix.len..];
    return value;
}
