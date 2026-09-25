const std = @import("std");
const uz = @import("uWebZockets");

fn index(_: *uz.Request, response: *uz.Response) void {
    response.text("hello from ephemeral TLS") catch |err| {
        std.log.err("response failed: {}", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init_https_ephemeral(init.io);
    defer server.deinit();

    _ = try server.get("/", index);
    try server.listen("0.0.0.0", 3443);
    try server.run();
}
