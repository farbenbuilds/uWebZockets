const std = @import("std");
const binding = @import("../quic/webtransport/binding.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const radix = @import("radix.zig");
const datagram = @import("datagram.zig");

/// The explicit handler's empty 2xx approves authentication and supplied Origin.
pub fn admit(
    router: *const radix.Router,
    routes: *const datagram.Router,
    request: *Request,
    response: *Response,
) binding.AdmissionResult {
    const origin = request.get_unique_header("origin") orelse {
        response.end_best_effort("400 Bad Request", "Exactly one Origin is required");
        return .rejected;
    };
    if (origin.len == 0) {
        response.end_best_effort("400 Bad Request", "Origin is empty");
        return .rejected;
    }
    const route_id = routes.find_id(request.path) orelse {
        response.end_best_effort("404 Not Found", "Datagram endpoint not found");
        return .rejected;
    };
    const matched = router.match_explicit_request(request, .connect) orelse {
        response.end_best_effort("404 Not Found", "CONNECT endpoint not found");
        return .rejected;
    };
    const handler = matched.handler orelse {
        refuse_method(response, matched.allowed_methods);
        return .rejected;
    };
    switch (handler) {
        .synchronous, .contextual => {},
        else => {
            response.end_best_effort("501 Not Implemented", "CONNECT admission must be synchronous");
            return .rejected;
        },
    }
    if (router.run_middleware(request, response) == .stop) return .rejected;
    if (response.is_started()) return .rejected;
    switch (handler) {
        .synchronous => |callback| callback(request, response),
        .contextual => |context| context.callback(context.context, request, response),
        else => unreachable,
    }
    if (!response.is_complete()) return .rejected;
    return .{ .accepted = route_id };
}

fn refuse_method(response: *Response, methods: u16) void {
    var value: [96]u8 = undefined;
    const allowed = radix.format_allowed_methods(methods, &value) catch {
        response.end_best_effort("500 Internal Server Error", "Allow field exceeds capacity");
        return;
    };
    var headers: [112]u8 = undefined;
    const fields = std.fmt.bufPrint(&headers, "Allow: {s}\r\n", .{allowed}) catch {
        response.end_best_effort("500 Internal Server Error", "Allow field exceeds capacity");
        return;
    };
    response.end_with_headers_best_effort("405 Method Not Allowed", fields, "Explicit CONNECT handler required");
}
