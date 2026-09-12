const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

const log = std.log.scoped(.json_rpc_http);

/// Serves a JSON-RPC service through the framework's HTTP response boundary.
pub fn serve(service: anytype, request: *Request, response: *Response) !void {
    if (!valid_json_content_type(request)) {
        return response.end_with_headers(
            "415 Unsupported Media Type",
            "Accept: application/json\r\n",
            "",
        );
    }

    const payload = try service.dispatch(request.bytes(), service.response_buffer());
    if (payload) |body| {
        return response.end_with_headers(
            "200 OK",
            "Content-Type: application/json; charset=utf-8\r\n",
            body,
        );
    }
    return response.end("204 No Content", "");
}

/// Returns the contextual route callback for one concrete service type.
pub fn route_handler(
    comptime Service: type,
) *const fn (*anyopaque, *Request, *Response) void {
    return struct {
        fn handle(
            context: *anyopaque,
            request: *Request,
            response: *Response,
        ) void {
            const service: *Service = @ptrCast(@alignCast(context));
            serve(service, request, response) catch |err| {
                log.err("request failed: {}", .{err});
                if (response.is_started()) return;
                response.end("500 Internal Server Error", "") catch |write_err| {
                    log.err("fallback response failed: {}", .{write_err});
                };
            };
        }
    }.handle;
}

fn valid_json_content_type(request: *const Request) bool {
    if (request.count_headers("content-type") != 1) return false;
    const value = request.get_unique_header("content-type") orelse return false;
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json") or
        std.ascii.eqlIgnoreCase(media_type, "application/json-rpc");
}
