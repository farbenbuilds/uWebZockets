//! Bounded, allocation-free rejection responses shared by the transports.
//!
//! Transports cannot propagate an error from a rejection path, so every
//! renderer here writes into a caller-owned scratch buffer and never allocates.

const std = @import("std");
const http_parser = @import("parser.zig");

/// Worst-case JSON document produced by `RejectionPolicy` renderers.
pub const max_document_bytes = 384;

/// Renders `bytes` in compact binary units, for example `16MB` or `1.5KB`.
///
/// A 32-byte buffer always suffices: a `usize` caps at 16EB, which leaves at
/// most eight digits, one fraction digit, and a two-character unit.
pub fn format_bytes(bytes: usize, buffer: *[32]u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value = bytes;
    var remainder: usize = 0;
    var unit_index: usize = 0;
    while (value >= 1024 and unit_index + 1 < units.len) {
        remainder = value % 1024;
        value /= 1024;
        unit_index += 1;
    }

    if (unit_index == 0) {
        return std.fmt.bufPrint(buffer, "{d}B", .{value}) catch unreachable;
    }
    const tenths = (remainder * 10) / 1024;
    if (tenths == 0) {
        return std.fmt.bufPrint(buffer, "{d}{s}", .{ value, units[unit_index] }) catch unreachable;
    }
    return std.fmt.bufPrint(buffer, "{d}.{d}{s}", .{ value, tenths, units[unit_index] }) catch unreachable;
}

/// Fixed transport limits rendered into rejection messages.
///
/// The policy is plain data so it can live inside the application slab and be
/// borrowed by every connection without allocation or hidden state.
pub const RejectionPolicy = struct {
    /// Configured request body ceiling in bytes.
    max_body_size: usize = http_parser.default_max_body_size,
    /// Configured request header block ceiling in bytes.
    max_header_size: usize = http_parser.max_header_size,

    pub const default: RejectionPolicy = .{};

    /// Renders the HTTP 413 JSON document for an oversized body.
    ///
    /// `buffer` should provide `max_document_bytes`; a smaller buffer degrades
    /// to a minimal valid document instead of failing the rejection path.
    pub fn payload_too_large(self: RejectionPolicy, buffer: []u8) []const u8 {
        var size_buffer: [32]u8 = undefined;
        const limit = format_bytes(self.max_body_size, &size_buffer);
        return std.fmt.bufPrint(
            buffer,
            "{{\"error\":{{\"code\":\"payload_too_large\",\"message\":\"Request body exceeded the {s} limit. Consider increasing 'max_body_size' in ServerConfig.\",\"limit_bytes\":{d}}}}}",
            .{ limit, self.max_body_size },
        ) catch fallback_document("payload_too_large");
    }

    /// Renders the HTTP 431 JSON document for an oversized header block.
    ///
    /// `buffer` should provide `max_document_bytes`; a smaller buffer degrades
    /// to a minimal valid document instead of failing the rejection path.
    pub fn headers_too_large(self: RejectionPolicy, buffer: []u8) []const u8 {
        var size_buffer: [32]u8 = undefined;
        const limit = format_bytes(self.max_header_size, &size_buffer);
        return std.fmt.bufPrint(
            buffer,
            "{{\"error\":{{\"code\":\"headers_too_large\",\"message\":\"Request headers exceeded the {s} limit. Consider sending smaller headers or raising max_header_size.\",\"limit_bytes\":{d}}}}}",
            .{ limit, self.max_header_size },
        ) catch fallback_document("headers_too_large");
    }
};

/// Minimal valid error document used when the caller buffer is undersized.
fn fallback_document(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "payload_too_large")) {
        return "{\"error\":{\"code\":\"payload_too_large\"}}";
    }
    return "{\"error\":{\"code\":\"headers_too_large\"}}";
}
