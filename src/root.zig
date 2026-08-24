// exposes the main api for uWebZockets.
// follows data-oriented design by separating data structures from behavior.

pub const App = @import("router/app.zig").App;
pub const init_app = @import("router/app.zig").init_app;
pub const deinit_app = @import("router/app.zig").deinit_app;
pub const add_route = @import("router/app.zig").add_route;
pub const listen = @import("router/app.zig").listen;
pub const run = @import("router/app.zig").run;
pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;
pub const end_response = @import("http/response.zig").end;
pub const write_chunk = @import("http/response.zig").write_chunk;

comptime {
    _ = @import("test.zig");
}
