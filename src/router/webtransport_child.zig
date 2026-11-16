//! Converts captured private identities into App-affine public callback values.
const api = @import("../quic/webtransport/stream_api.zig");
const child = @import("../quic/webtransport/child_runtime.zig");
const binding = @import("../quic/webtransport/binding.zig");
const runtime = @import("../quic/webtransport/runtime.zig");
const endpoints = @import("webtransport_endpoints.zig");
const SessionHandle = @import("../quic/webtransport/session.zig").SessionHandle;

/// Borrows the immutable registry at its final App address until native drain.
pub const Dispatcher = struct {
    owner: usize,
    registry: *const endpoints.Registry,
    legacy: ?binding.ChildConsumer,
};

fn dispatcher(context: *anyopaque) *Dispatcher {
    return @ptrCast(@alignCast(context));
}

fn handle(owner: usize, key: child.Key) api.Handle {
    return .{ .owner = owner, .index = key.location.index, .generation = key.location.generation };
}

fn session_handle(owner: usize, connection: runtime.ConnectionHandle, session: SessionHandle) api.SessionHandle {
    return .{ .owner = owner, .connection_index = connection.index, .connection_generation = connection.generation, .index = session.index, .generation = session.generation };
}

fn error_code(code: u64) api.ErrorCode {
    // Native snapshots validate u62, and every local cause is a bounded constant or mapped u32.
    return api.from_native_code(code) catch unreachable;
}

fn stream_binding(active: *const Dispatcher, route: binding.RouteId) ?endpoints.StreamBinding {
    return (active.registry.get(route) orelse return null).streams;
}

/// Chooses one endpoint once; subsequent callbacks never resolve a live parent.
pub fn select(context: *anyopaque, route: binding.RouteId) ?binding.ChildConsumer {
    const active = dispatcher(context);
    if (stream_binding(active, route) == null) return active.legacy;
    return .{ .context = context, .open = open, .data = data, .eof = eof, .reset = reset, .stop = stop, .closed = closed, .policy = .duplex, .writable = if (stream_binding(active, route).?.callbacks.writable != null) writable else null };
}

fn open(context: *anyopaque, info: child.Info) bool {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, info.route) orelse return false;
    return endpoint.callbacks.open(endpoint.context, .{
        .handle = handle(active.owner, info.key),
        .session = session_handle(active.owner, info.key.connection, info.key.session),
        .session_id = info.key.session_id,
        .stream_id = info.key.stream_id,
        .direction = if (info.direction == .uni) .uni else .bidi,
        .initiator = .peer,
    });
}

fn data(context: *anyopaque, key: child.Key, bytes: []const u8) bool {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, key.route) orelse return false;
    const callback = endpoint.callbacks.data orelse return false;
    return callback(endpoint.context, handle(active.owner, key), bytes);
}

fn writable(context: *anyopaque, key: child.Key) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, key.route) orelse return;
    const callback = endpoint.callbacks.writable orelse return;
    callback(endpoint.context, handle(active.owner, key));
}

fn eof(context: *anyopaque, key: child.Key, final_size: u64) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, key.route) orelse return;
    const callback = endpoint.callbacks.eof orelse return;
    callback(endpoint.context, handle(active.owner, key), final_size);
}

fn reset(context: *anyopaque, key: child.Key, code: u64, final_size: u64) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, key.route) orelse return;
    const callback = endpoint.callbacks.reset orelse return;
    callback(endpoint.context, handle(active.owner, key), error_code(code), final_size);
}

fn stop(context: *anyopaque, key: child.Key, code: u64) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, key.route) orelse return;
    const callback = endpoint.callbacks.stop orelse return;
    callback(endpoint.context, handle(active.owner, key), error_code(code));
}

fn closed(context: *anyopaque, event: child.ClosedEvent) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, event.key.route) orelse return;
    const callback = endpoint.callbacks.closed orelse return;
    callback(endpoint.context, .{ .handle = handle(active.owner, event.key), .reason = event.reason, .code = if (event.code) |code| error_code(code) else null, .final_payload_size = event.final_payload_size, .accounted_bytes = event.accounted_bytes });
}

pub fn session_open(context: *anyopaque, notice: runtime.SessionNotice) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, notice.route) orelse return;
    const callback = endpoint.callbacks.session_open orelse return;
    callback(endpoint.context, .{ .handle = session_handle(active.owner, notice.connection, notice.session), .session_id = notice.session_id });
}

pub fn session_closed(context: *anyopaque, notice: runtime.SessionNotice, reason: child.CloseReason, code: ?u64) void {
    const active = dispatcher(context);
    const endpoint = stream_binding(active, notice.route) orelse return;
    const callback = endpoint.callbacks.session_closed orelse return;
    callback(endpoint.context, .{ .handle = session_handle(active.owner, notice.connection, notice.session), .session_id = notice.session_id, .reason = reason, .code = if (code) |value| error_code(value) else null });
}
