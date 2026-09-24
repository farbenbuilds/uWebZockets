//! Microservice preset: small JSON payloads with a bounded connection pool.
//!
//! Build and run:
//!   zig build basic_microservice -Doptimize=ReleaseSafe
//!   curl -s http://127.0.0.1:3000/health
//!   curl -s -X POST http://127.0.0.1:3000/echo -d '{"ping":true}'
//!   curl -s 'http://127.0.0.1:3000/search?q=zig&page=2'

const std = @import("std");
const uz = @import("uWebZockets");

fn health(_: *uz.Request, res: *uz.Response) void {
    var scratch: [128]u8 = undefined;
    res.json_buf(.{ .status = "ok", .preset = "microservice" }, &scratch) catch {};
}

fn echo(req: *uz.Request, res: *uz.Response) void {
    // Request bodies borrow the connection buffer for this callback only.
    res.bytes(req.bytes()) catch {};
}

fn search(req: *uz.Request, res: *uz.Response) void {
    // Routes match on the path only; query pairs are sliced zero-copy.
    const params = req.query_params() catch {
        res.end("400 Bad Request", "invalid query") catch {};
        return;
    };
    const page = params.get_int(u32, "page") catch {
        res.end("400 Bad Request", "page must be a non-negative integer") catch {};
        return;
    };

    var scratch: [192]u8 = undefined;
    res.json_buf(.{
        .query = params.get("q") orelse "",
        .page = page orelse 1,
        .raw = params.get("page") orelse "",
    }, &scratch) catch {};
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.Server.builder(init.io)
        .preset(uz.Presets.microservice)
        .with_max_clients(256)
        .build(std.heap.page_allocator);
    defer server.deinit();

    _ = try server.get("/health", health);
    _ = try server.post("/echo", echo);
    _ = try server.get("/search", search);

    try server.listen("0.0.0.0", 3000);
    try server.run();
}
