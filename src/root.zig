// exposes the main api for uWebZockets.
// follows data-oriented design by separating data structures from behavior.

pub const App = @import("router/app.zig").App;
pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;
pub const end_response = @import("http/response.zig").end;
pub const write_chunk = @import("http/response.zig").write_chunk;

pub const WebSocket = @import("ws/socket.zig").WebSocket;
pub const WsBehavior = @import("router/radix.zig").WsBehavior;

comptime {
    _ = @import("test.zig");
}
