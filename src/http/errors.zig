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

/// Wire shape of one error document.
const ErrorDocument = struct {
    @"error": ErrorBody,
};

/// Payload nested under the document's "error" member.
const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

/// Renders `{"error":{"code":...,"message":...}}` into `buffer` and returns it.
///
/// Message and code bytes are JSON-escaped in place; an undersized buffer
/// yields the constant minimal document instead of a partial one.
pub fn render(code: []const u8, message: []const u8, buffer: []u8) []const u8 {
    const document: ErrorDocument = .{ .@"error" = .{ .code = code, .message = message } };
    return std.fmt.bufPrint(buffer, "{f}", .{std.json.fmt(document, .{})}) catch fallback_document;
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
