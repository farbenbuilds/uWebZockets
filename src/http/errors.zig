//! Typed JSON error responses for HTTP handlers.
//!
//! Renderers write into caller-owned scratch storage, so a response never
//! allocates and an undersized buffer degrades to a constant valid document.

const std = @import("std");
const status = @import("status.zig");
const Response = @import("response.zig").Response;

/// Worst-case JSON document produced by `render` for bounded messages.
pub const max_document_bytes = 512;

/// One typed error response: status, machine code, and human message.
pub const Problem = struct {
    /// Status whose canonical line is sent.
    status: status.StatusCode,
    /// Stable machine-readable code, JSON-escaped by `render`.
    code: []const u8,
    /// Human-readable message, JSON-escaped by `render`.
    message: []const u8,
};

/// Document returned when the caller buffer cannot hold the rendered one.
const fallback_document = "{\"error\":{\"code\":\"internal\"}}";

/// Content type shared by every error document.
const content_type = "Content-Type: application/json; charset=utf-8\r\n";

/// UTF-8 encoding of U+FFFD, substituted for each malformed input byte.
const replacement_character = "\xef\xbf\xbd";

/// Renders `{"error":{"code":...,"message":...}}` into `buffer` and returns it.
///
/// `code` and `message` may hold attacker-influenced bytes: every malformed
/// UTF-8 byte is replaced with U+FFFD so the document is always valid UTF-8
/// JSON. An undersized buffer yields the constant minimal document instead of
/// a partial one.
pub fn render(code: []const u8, message: []const u8, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    write_document(&writer, code, message) catch return fallback_document;
    return writer.buffered();
}

/// Writes the canonical error document into `writer`.
fn write_document(writer: *std.Io.Writer, code: []const u8, message: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("{\"error\":{\"code\":");
    try write_json_string(writer, code);
    try writer.writeAll(",\"message\":");
    try write_json_string(writer, message);
    try writer.writeAll("}}");
}

/// Writes one JSON string, replacing malformed UTF-8 bytes with U+FFFD.
///
/// JSON strings must be valid UTF-8, and `std.json` emits invalid byte slices
/// as number arrays, so this writer owns the escaping and substitutes per
/// malformed byte instead. A failed sequence advances exactly one byte, which
/// keeps every replacement aligned with the byte that caused it and never
/// consumes the valid bytes that follow.
fn write_json_string(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        switch (byte) {
            '"' => {
                try writer.writeAll("\\\"");
                index += 1;
            },
            '\\' => {
                try writer.writeAll("\\\\");
                index += 1;
            },
            '\x08' => {
                try writer.writeAll("\\b");
                index += 1;
            },
            '\x0c' => {
                try writer.writeAll("\\f");
                index += 1;
            },
            '\n' => {
                try writer.writeAll("\\n");
                index += 1;
            },
            '\r' => {
                try writer.writeAll("\\r");
                index += 1;
            },
            '\t' => {
                try writer.writeAll("\\t");
                index += 1;
            },
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{byte});
                index += 1;
            },
            0x20...0x21, 0x23...0x5b, 0x5d...0x7f => {
                try writer.writeByte(byte);
                index += 1;
            },
            else => index += try write_utf8_sequence(writer, value[index..]),
        }
    }
    try writer.writeByte('"');
}

/// Emits one valid UTF-8 sequence from the head of `rest`, or U+FFFD for its
/// first byte; returns the number of input bytes consumed.
fn write_utf8_sequence(writer: *std.Io.Writer, rest: []const u8) std.Io.Writer.Error!usize {
    const sequence_length = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
        try writer.writeAll(replacement_character);
        return 1;
    };
    if (rest.len < sequence_length) {
        try writer.writeAll(replacement_character);
        return 1;
    }
    _ = std.unicode.utf8Decode(rest[0..sequence_length]) catch {
        try writer.writeAll(replacement_character);
        return 1;
    };
    try writer.writeAll(rest[0..sequence_length]);
    return sequence_length;
}

/// Sends a Problem as application/json using an internal bounded buffer.
pub fn send(response: *Response, problem: Problem) !void {
    var buffer: [max_document_bytes]u8 = undefined;
    return send_buf(response, problem, &buffer);
}

/// Sends a Problem using caller-owned scratch storage.
pub fn send_buf(response: *Response, problem: Problem, buffer: []u8) !void {
    const payload = render(problem.code, problem.message, buffer);
    return response.end_with_headers(status.line(problem.status), content_type, payload);
}

/// Sends 405 with an Allow field; `allow` may not contain CR/LF.
pub fn method_not_allowed(response: *Response, allow: []const u8) !void {
    try response.append_header("Allow", allow);
    return send(response, .{
        .status = .method_not_allowed,
        .code = "method_not_allowed",
        .message = "Method Not Allowed",
    });
}

/// Sends a generic 500 that never echoes internal detail.
pub fn internal(response: *Response) !void {
    return send(response, .{
        .status = .internal_server_error,
        .code = "internal",
        .message = "Internal Server Error",
    });
}
