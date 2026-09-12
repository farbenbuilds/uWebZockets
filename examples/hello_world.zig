const std = @import("std");
const uz = @import("uWebZockets");

fn hello_handler(_: *uz.Request, res: *uz.Response) void {
    res.text("Hello from µWebZockets! Zero allocation achieved.") catch |err| {
        std.debug.print("response error: {}\n", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello_handler);

    try app.listen("0.0.0.0", 3000);
    try app.run();
}
