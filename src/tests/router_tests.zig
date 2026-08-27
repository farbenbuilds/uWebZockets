const std = @import("std");
const radix = @import("../router/radix.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

// dummy handler to verify route routing
fn dummy_handler(req: *Request, res: *Response) void {
    _ = req;
    _ = res;
}

// tests radix trie insertion and exact matching
test "router: radix trie exact match" {
    var router = radix.Router.init();

    router.get("/api/v1/users", dummy_handler);
    router.get("/api/v1/posts", dummy_handler);
    router.ws("/chat", .{});

    const r1 = router.match("/api/v1/users");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqual(radix.RouteType.http, r1.?.route_type);

    const r2 = router.match("/api/v1/posts");
    try std.testing.expect(r2 != null);

    const r3 = router.match("/chat");
    try std.testing.expect(r3 != null);
    try std.testing.expectEqual(radix.RouteType.websocket, r3.?.route_type);

    const r4 = router.match("/notfound");
    try std.testing.expect(r4 == null);
}
