const std = @import("std");
const parser = @import("../http/parser.zig");
const Request = @import("../http/request.zig").Request;

// tests the zero-allocation http parser state machine
test "http: parse basic get request" {
    var p = parser.HttpParser{};
    var req = Request{};

    const request_data = "GET /index.html HTTP/1.1\r\nHost: localhost\r\nUser-Agent: curl\r\n\r\n";

    const consumed = parser.consume(&p, &req, request_data);

    try std.testing.expectEqual(request_data.len, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/index.html", req.path);
    try std.testing.expectEqual(@as(usize, 2), req.header_count);

    try std.testing.expectEqualStrings("localhost", req.get_header("Host").?);
    try std.testing.expectEqualStrings("curl", req.get_header("User-Agent").?);
}
