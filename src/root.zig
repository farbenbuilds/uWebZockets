// exposes the main api for uWebZockets.
// follows data-oriented design by separating data structures from behavior.

pub const App = @import("router/app.zig").App;
pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;
pub const end_response = Response.end;
pub const write_chunk = Response.write_chunk;
pub const chunked = @import("http/chunked.zig");

pub const WebSocket = @import("ws/socket.zig").WebSocket;
pub const WsBehavior = @import("router/radix.zig").WsBehavior;

pub const tls = @import("crypto/tls.zig");
pub const quic = @import("quic/engine.zig");

comptime {
    _ = @import("test.zig");
}
