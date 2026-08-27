const std = @import("std");
const uz = @import("uWebZockets");

// pure function handler for the root endpoint
fn hello_handler(req: *uz.Request, res: *uz.Response) void {
    _ = req;
    res.end("200 OK", "Hello from uWebZockets! Zero allocation achieved.") catch return;
}

pub fn main(init: std.process.Init) !void {
    // initialize app with a static pool of 128 connections (avoids stack overflow)
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = app.get("/", hello_handler);

    try app.listen("0.0.0.0", 3000);
    try app.run();
}
