//! Compiles the README Quick Start snippet against the package module surface.
//!
//! `zig build check` proves a downstream consumer can fetch the package,
//! import `uWebZockets`, and build a real `App` with a route, listener, and
//! run call.

const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a dependency") catch {};
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello);
    try app.listen("0.0.0.0", 3000);
    try app.run();
}
