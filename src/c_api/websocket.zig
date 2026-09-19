//! C ABI WebSocket operations: send, close, buffered amount, and bounded
//! publish/subscribe.

const zslay = @import("zslay");
const WebSocket = @import("../ws/socket.zig").WebSocket;
const types = @import("types.zig");
const errors = @import("errors.zig");

const CSlice = types.CSlice;

fn cast_websocket(pointer: ?*anyopaque) ?*WebSocket {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn cast_const_websocket(pointer: ?*const anyopaque) ?*const WebSocket {
    return @ptrCast(@alignCast(pointer orelse return null));
}

/// Sends a complete text or binary WebSocket message.
pub export fn uwz_websocket_send(
    socket_pointer: ?*anyopaque,
    message: CSlice,
    opcode: c_int,
) c_int {
    const socket = cast_websocket(socket_pointer) orelse return types.invalid_argument;
    const message_bytes = errors.slice_bytes(message) orelse return types.invalid_argument;
    const zig_opcode: zslay.Opcode = switch (opcode) {
        0x1 => .text,
        0x2 => .binary,
        else => return types.invalid_argument,
    };
    socket.send(message_bytes, zig_opcode) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Sends a close frame and closes after queued bytes drain.
pub export fn uwz_websocket_send_close(
    socket_pointer: ?*anyopaque,
    code: u16,
    reason: CSlice,
) c_int {
    const socket = cast_websocket(socket_pointer) orelse return types.invalid_argument;
    const reason_bytes = errors.slice_bytes(reason) orelse return types.invalid_argument;
    socket.send_close(code, reason_bytes) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Returns bytes queued for the WebSocket transport.
pub export fn uwz_websocket_buffered_amount(socket_pointer: ?*const anyopaque) usize {
    const socket = cast_const_websocket(socket_pointer) orelse return 0;
    return socket.buffered_amount();
}

/// Subscribes a WebSocket to an owned bounded topic.
pub export fn uwz_websocket_subscribe(socket_pointer: ?*anyopaque, topic: CSlice) c_int {
    const socket = cast_websocket(socket_pointer) orelse return types.invalid_argument;
    const topic_bytes = errors.slice_bytes(topic) orelse return types.invalid_argument;
    socket.subscribe(topic_bytes) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Removes a WebSocket topic subscription.
pub export fn uwz_websocket_unsubscribe(socket_pointer: ?*anyopaque, topic: CSlice) bool {
    const socket = cast_websocket(socket_pointer) orelse return false;
    const topic_bytes = errors.slice_bytes(topic) orelse return false;
    return socket.unsubscribe(topic_bytes);
}

/// Publishes from a WebSocket to matching topic subscribers.
pub export fn uwz_websocket_publish(
    socket_pointer: ?*anyopaque,
    topic: CSlice,
    message: CSlice,
    is_text: bool,
) usize {
    const socket = cast_websocket(socket_pointer) orelse return 0;
    const topic_bytes = errors.slice_bytes(topic) orelse return 0;
    const message_bytes = errors.slice_bytes(message) orelse return 0;
    return socket.publish(topic_bytes, message_bytes, is_text);
}

/// Immediately terminates a WebSocket transport.
pub export fn uwz_websocket_terminate(socket_pointer: ?*anyopaque) void {
    const socket = cast_websocket(socket_pointer) orelse return;
    socket.terminate();
}
