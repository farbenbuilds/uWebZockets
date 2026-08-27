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

    pub fn init(stream: *c.lsquic_stream) QuicStream {
        return .{
            .stream_ptr = stream,
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
            std.debug.print("received full http/3 request: {s}\n", .{self.req.path});

            // TODO: call app router to route this request.
            // app.router.match(self.req.path)...

            // hardcoded response example:
            self.send_response("HTTP/3 200 OK\r\n\r\nHello from QUIC!");
        }
    }

    // sends data back to engine for encryption and udp transmission.
    pub fn send_response(self: *QuicStream, data: []const u8) void {
        _ = c.lsquic_stream_write(self.stream_ptr, data.ptr, data.len);

        // requests lsquic to immediately package and send.
        _ = c.lsquic_stream_flush(self.stream_ptr);

        // normally close stream after sending http response.
        _ = c.lsquic_stream_close(self.stream_ptr);
    }
};
