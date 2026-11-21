const http_parser = @import("../http/parser.zig");

/// Per-stream HTTP/3 storage and field capacities.
///
/// `decoded_header_count` caps the regular request fields accepted from one
/// field section; pseudo-fields are validated into named slots and do not
/// consume it. `header_extra_capacity` reserves the request-field pointer slots
/// the engine lends beyond the inline `Request` arrays.
pub const Capacities = struct {
    request_header_size: usize = http_parser.max_header_size,
    request_body_size: usize = http_parser.default_max_body_size,
    response_header_size: usize = 4096,
    response_header_count: usize = 64,
    decoded_header_count: usize = 64,
    header_extra_capacity: usize = 0,
};

/// Default per-stream capacity record; the production stream is specialized
/// with these values.
pub const default_capacities: Capacities = .{};
