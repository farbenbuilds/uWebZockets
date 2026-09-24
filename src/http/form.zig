//! Zero-allocation `application/x-www-form-urlencoded` body helpers.
//!
//! Parsing reuses the query slicer, so form pairs are borrowed from the
//! bounded request body and never copied. Use `query.form_decode` before
//! interpreting values as text.

const std = @import("std");
const query = @import("query.zig");

/// Failures raised while validating or parsing a form body.
pub const Error = query.ParseError || error{
    MissingContentType,
    UnsupportedMediaType,
};

/// Reports whether `value` names the form media type, ignoring parameters.
pub fn is_form_content_type(value: []const u8) bool {
    const parameters = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..parameters], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded");
}

/// Validates `content_type` and parses `body` into borrowed raw pairs.
///
/// `content_type` is the caller-supplied header value; it is not fetched
/// here so the function stays pure and testable.
pub fn parse(content_type: []const u8, body: []const u8) Error!query.QueryParams {
    if (!is_form_content_type(content_type)) return error.UnsupportedMediaType;
    return query.QueryParams.parse(body);
}
