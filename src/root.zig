// exposes the main api for uWebZockets.
// follows data-oriented design by separating data structures from behavior.

pub const App = @import("router/app.zig").App;
pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;

comptime {
    _ = @import("test.zig");
}
