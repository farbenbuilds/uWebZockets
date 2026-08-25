const std = @import("std");
const uz = @import("uWebZockets");

// pure function handler for the root endpoint
fn hello_handler(req: *uz.Request, res: *uz.Response) void {
    _ = req;
    uz.end_response(res, "200 OK", "Hello from uWebZockets! Zero allocation achieved.");
}

pub fn main() !void {
    // initialize app with a static pool of 4096 connections
    var app = try uz.App(4096).init();
    defer app.deinit();

    _ = app.get("/", hello_handler);

    try app.listen("0.0.0.0", 3000);
    try app.run();
}
