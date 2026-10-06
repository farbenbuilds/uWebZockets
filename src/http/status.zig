//! Canonical HTTP status codes and their status lines.

/// Final-response status codes covered by the canonical status lines.
pub const StatusCode = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    partial_content = 206,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    conflict = 409,
    gone = 410,
    length_required = 411,
    content_too_large = 413,
    unsupported_media_type = 415,
    unprocessable_entity = 422,
    too_many_requests = 429,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
};

/// Largest decimal rendering of a `usize` content length.
const max_decimal_digits = 20;

/// Returns the number of decimal digits needed for `value`.
fn decimal_digits(value: usize) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}

/// Writes the decimal rendering of `value` into `buffer` at `index` and
/// returns the index after the last digit.
fn write_decimal(buffer: []u8, index: usize, value: usize) usize {
    var digits: [max_decimal_digits]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(remaining % 10));
        count += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }

    var at = index;
    while (count != 0) {
        count -= 1;
        buffer[at] = digits[count];
        at += 1;
    }
    return at;
}

/// Formats an HTTP/1.1 status line and optional `Content-Length` field
/// without the `std.fmt` machinery; this runs once per response.
///
/// `content_length` is null for statuses that forbid a body. The returned
/// slice borrows `buffer`, which must hold at least nine bytes plus the
/// status text and, when present, the length field.
pub fn format_http1_framing(
    buffer: []u8,
    status: []const u8,
    content_length: ?usize,
) error{BufferOverflow}![]const u8 {
    const prefix = "HTTP/1.1 ";
    const crlf = "\r\n";
    const length_prefix = "Content-Length: ";

    const required = prefix.len + status.len + crlf.len +
        (if (content_length) |length|
            length_prefix.len + decimal_digits(length) + crlf.len
        else
            0);
    if (required > buffer.len) return error.BufferOverflow;

    var at: usize = 0;
    @memcpy(buffer[at..][0..prefix.len], prefix);
    at += prefix.len;
    @memcpy(buffer[at..][0..status.len], status);
    at += status.len;
    @memcpy(buffer[at..][0..crlf.len], crlf);
    at += crlf.len;

    if (content_length) |length| {
        @memcpy(buffer[at..][0..length_prefix.len], length_prefix);
        at += length_prefix.len;
        at = write_decimal(buffer, at, length);
        @memcpy(buffer[at..][0..crlf.len], crlf);
        at += crlf.len;
    }
    return buffer[0..at];
}

/// Formats an HTTP/1.1 status line plus the `Transfer-Encoding: chunked`
/// field for a streaming response, without the `std.fmt` machinery.
///
/// The returned slice borrows `buffer`, which must hold at least nine bytes
/// plus the status text plus the fixed chunked field.
pub fn format_http1_chunked_framing(
    buffer: []u8,
    status: []const u8,
) error{BufferOverflow}![]const u8 {
    const prefix = "HTTP/1.1 ";
    const crlf = "\r\n";
    const transfer_encoding = "Transfer-Encoding: chunked\r\n";

    const required = prefix.len + status.len + crlf.len + transfer_encoding.len;
    if (required > buffer.len) return error.BufferOverflow;

    var at: usize = 0;
    @memcpy(buffer[at..][0..prefix.len], prefix);
    at += prefix.len;
    @memcpy(buffer[at..][0..status.len], status);
    at += status.len;
    @memcpy(buffer[at..][0..crlf.len], crlf);
    at += crlf.len;
    @memcpy(buffer[at..][0..transfer_encoding.len], transfer_encoding);
    at += transfer_encoding.len;
    return buffer[0..at];
}

/// Returns the canonical status line, for example "404 Not Found".
pub fn line(code: StatusCode) []const u8 {
    return switch (code) {
        .ok => "200 OK",
        .created => "201 Created",
        .accepted => "202 Accepted",
        .no_content => "204 No Content",
        .partial_content => "206 Partial Content",
        .moved_permanently => "301 Moved Permanently",
        .found => "302 Found",
        .see_other => "303 See Other",
        .not_modified => "304 Not Modified",
        .temporary_redirect => "307 Temporary Redirect",
        .permanent_redirect => "308 Permanent Redirect",
        .bad_request => "400 Bad Request",
        .unauthorized => "401 Unauthorized",
        .forbidden => "403 Forbidden",
        .not_found => "404 Not Found",
        .method_not_allowed => "405 Method Not Allowed",
        .not_acceptable => "406 Not Acceptable",
        .conflict => "409 Conflict",
        .gone => "410 Gone",
        .length_required => "411 Length Required",
        .content_too_large => "413 Content Too Large",
        .unsupported_media_type => "415 Unsupported Media Type",
        .unprocessable_entity => "422 Unprocessable Entity",
        .too_many_requests => "429 Too Many Requests",
        .internal_server_error => "500 Internal Server Error",
        .not_implemented => "501 Not Implemented",
        .bad_gateway => "502 Bad Gateway",
        .service_unavailable => "503 Service Unavailable",
        .gateway_timeout => "504 Gateway Timeout",
    };
}
