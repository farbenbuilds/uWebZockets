const std = @import("std");
const c = @import("c"); // lsquic
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;

// represents an independent http/3 stream inside a quic connection.
pub const QuicStream = struct {
    // lsquic stream pointer.
    stream_ptr: *c.lsquic_stream,

    // each stream has its own http parser.
    // (note: http/3 actually uses qpack, but this architecture simulates l7 streams).
    parser: HttpParser = .{},
    req: Request = .{},
    router: *const @import("../router/radix.zig").Router = undefined,

    pub fn init(stream: *c.lsquic_stream, router: *const @import("../router/radix.zig").Router) QuicStream {
        return .{
            .stream_ptr = stream,
            .router = router,
        };
    }

    // receives clean (decrypted) bytes from lsquic engine.
    pub fn on_data(self: *QuicStream, data: []const u8) void {
        // reuse static http parser.
        _ = http_parser.consume(&self.parser, &self.req, data);

        if (self.parser.state == .error_invalid) {
            std.debug.print("http/3 parse error\n", .{});
            _ = c.lsquic_stream_close(self.stream_ptr);
            return;
        }

        if (self.parser.state == .done) {
            var res = @import("../http/response.zig").Response{ .target = .{ .quic = self } };

            if (self.router.match(self.req.path)) |route| {
                if (route.route_type == .http) {
                    if (route.http_handler) |handler| {
                        handler(&self.req, &res);
                    }
                } else {
                    res.end("404 Not Found", "WebSockets over QUIC not implemented") catch {};
                }
            } else {
                res.end("404 Not Found", "Route not found") catch {};
            }
        }
    }

    // sends HTTP/3 headers and body
    pub fn send_response(self: *QuicStream, status: []const u8, body: []const u8) void {
        _ = status; // lsquic helper currently hardcodes 200 OK
        c.send_h3_response(self.stream_ptr, body.ptr, body.len);
    }
};
