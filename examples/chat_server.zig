const std = @import("std");
const uz = @import("uWebZockets");
const zslay = @import("zslay");

fn on_ws_open(ws: *uz.WebSocket) void {
    std.debug.print("a client just connected!\n", .{});
    ws.send("Welcome to uWebZockets!", .text);
}

fn on_ws_message(ws: *uz.WebSocket, message: []const u8, opcode: zslay.Opcode) void {
    std.debug.print("received message: {s}\n", .{message});

    // echo: send the message back to the client
    ws.send(message, opcode);
}

fn on_ws_close(ws: *uz.WebSocket) void {
    _ = ws;
    std.debug.print("client disconnected.\n", .{});
}

pub fn main() !void {
    var app = try uz.App(128).init();
    defer app.deinit();

    _ = app.ws("/chat", .{
        .open = on_ws_open,
        .message = on_ws_message,
        .close = on_ws_close,
    });

    try app.listen("0.0.0.0", 3000);

    std.debug.print("open browser and visit: ws://localhost:3000/chat\n", .{});
    try app.run();
}
