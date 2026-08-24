const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

// handler function signature
pub const Handler = *const fn (req: *Request, res: *Response) void;

// maximum number of static routes
const max_routes = 64;

// static router using struct of arrays (soa) for cache efficiency
pub const Router = struct {
    paths: [max_routes][]const u8 = undefined,
    handlers: [max_routes]Handler = undefined,
    route_count: usize = 0,
};

// register a static route
pub fn add_route(router: *Router, path: []const u8, handler: Handler) void {
    if (router.route_count >= max_routes) @panic("router capacity exceeded");

    router.paths[router.route_count] = path;
    router.handlers[router.route_count] = handler;
    router.route_count += 1;
}

// match a url path to a registered handler
pub fn match_route(router: *const Router, path: []const u8) ?Handler {
    const count = router.route_count;
    for (router.paths[0..count], 0..) |p, i| {
        if (std.mem.eql(u8, p, path)) {
            return router.handlers[i];
        }
    }
    return null;
}
