const std = @import("std");
const uz = @import("uWebZockets");

// pure function handler for the root endpoint
fn hello_handler(req: *uz.Request, res: *uz.Response) void {
    _ = req;
    uz.end_response(res, "200 OK", "Hello from uWebZockets! Zero allocation achieved.");
}

pub fn main() !void {
    // initialize app with a static pool of 4096 connections
    var app = try uz.init_app(4096);
    defer uz.deinit_app(&app);

    uz.add_route(&app, "/", hello_handler);
    try uz.listen(&app, "0.0.0.0", 3000);
    try uz.run(&app);
}
