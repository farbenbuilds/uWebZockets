//! Terminal development log: colored, allocation-free, real-time terminal output.
//!
//! Build and run:
//!   zig build dev_log_server -Doptimize=ReleaseSafe
//!   curl -i http://127.0.0.1:3000/
//!   curl -i http://127.0.0.1:3000/snapshot
//!   curl -i http://127.0.0.1:3000/metrics
//!   npx wscat -c ws://127.0.0.1:3000/echo
//!
//! The startup wordmark, the Vite-style ready summary, and the request lines
//! are written to stderr by the worker thread that owns the event loop. The
//! summary lists the local URL, the log target, and the metrics endpoint, and
//! the wordmark collapses to a one-line mark on narrow terminals.
//! `GET /snapshot` records every Prometheus counter into the same log, and
//! `GET /metrics` serves the registry. Set `ServerConfig.enable_dev_log` to
//! false to silence it all.

const std = @import("std");
const uz = @import("uWebZockets");

/// Same generated application type as the builder chain below.
const App = uz.App(256);

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from the dev log server\n") catch {};
}

fn snapshot(context: *anyopaque, _: *uz.Request, res: *uz.Response) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.log_metrics();
    res.text("metric snapshot written to the dev log\n") catch {};
}

fn echo(ws: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    ws.send(message, opcode) catch {};
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.Server.builder(init.io)
        .with_max_clients(256)
        .with_observability(true)
        .with_dev_log(true)
        .build(std.heap.page_allocator);
    defer server.deinit();

    _ = try server.get("/", hello);
    _ = try server.get_context("/snapshot", &server, snapshot);
    _ = try server.ws("/echo", .{ .message = echo });

    try server.listen("0.0.0.0", 3000);
    try server.run();
}
