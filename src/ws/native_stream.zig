const zslay = @import("zslay");
const WebSocket = @import("socket.zig").WebSocket;
const stream = @import("stream.zig");

pub const NativeAdapter = struct {
    pub fn send(context: *anyopaque, message: []const u8, kind: stream.MessageKind) !void {
        const socket: *WebSocket = @ptrCast(@alignCast(context));
        try socket.send(message, switch (kind) {
            .binary => zslay.Opcode.Binary,
            .text => zslay.Opcode.Text,
        });
    }

    pub fn close(context: *anyopaque) !void {
        const socket: *WebSocket = @ptrCast(@alignCast(context));
        try socket.send_close(1000, "");
    }

    pub fn terminate(context: *anyopaque) void {
        const socket: *WebSocket = @ptrCast(@alignCast(context));
        socket.terminate();
    }
};

/// Pull-based stream facade over the existing RFC 6455 socket.
pub const NativeWebSocketStream = stream.web_socket_stream(NativeAdapter);
