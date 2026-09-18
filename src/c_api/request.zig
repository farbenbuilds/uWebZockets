//! C ABI request accessors.
//!
//! Returned slices borrow request storage and are valid only for the callback
//! invocation declared in `include/uWebZockets.h`.

const types = @import("types.zig");
const errors = @import("errors.zig");
const Request = @import("../http/request.zig").Request;

const CSlice = types.CSlice;

fn cast_request(pointer: ?*const anyopaque) ?*const Request {
    return @ptrCast(@alignCast(pointer orelse return null));
}

/// Returns the request method borrowed for the callback duration.
pub export fn uwz_request_method(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    return errors.make_slice(request.method);
}

/// Returns the original request target.
pub export fn uwz_request_target(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    return errors.make_slice(request.target);
}

/// Returns the routed request path.
pub export fn uwz_request_path(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    return errors.make_slice(request.path);
}

/// Returns the request query without the question mark.
pub export fn uwz_request_query(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    return errors.make_slice(request.query);
}

/// Returns the bounded request body.
pub export fn uwz_request_body(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    return errors.make_slice(request.body);
}

/// Returns the first matching header value.
pub export fn uwz_request_header(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    const header_name = errors.slice_bytes(name) orelse return types.empty_slice;
    return errors.make_slice(request.get_header(header_name) orelse return types.empty_slice);
}

/// Counts matching request header fields.
pub export fn uwz_request_header_count(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) usize {
    const request = cast_request(request_pointer) orelse return 0;
    const header_name = errors.slice_bytes(name) orelse return 0;
    return request.count_headers(header_name);
}

/// Returns a route parameter borrowed for the callback duration.
pub export fn uwz_request_parameter(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) CSlice {
    const request = cast_request(request_pointer) orelse return types.empty_slice;
    const parameter_name = errors.slice_bytes(name) orelse return types.empty_slice;
    return errors.make_slice(request.get_param(parameter_name) orelse return types.empty_slice);
}

/// Returns the number of fixed-array route captures on this request.
pub export fn uwz_request_parameter_count(request_pointer: ?*const anyopaque) usize {
    const request = cast_request(request_pointer) orelse return 0;
    return request.route_param_count;
}
