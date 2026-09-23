//! Shared C ABI layout, fixed capacities, and callback signatures.
//!
//! Every `extern struct` declared here crosses the C boundary, so field order,
//! field types, and alignment must match `include/uWebZockets.h` exactly.

const std = @import("std");
const app_module = @import("../router/app.zig");
const radix = @import("../router/radix.zig");
const Request = @import("../http/request.zig").Request;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const zslay = @import("zslay");

pub const max_connections = 1024;
pub const max_c_routes = 64;
pub const max_c_middleware = radix.max_middleware;
pub const max_route_path_size = 2048;

pub const App = app_module.app(max_connections);

pub const ok: c_int = 0;
pub const invalid_argument: c_int = -1;
pub const out_of_memory: c_int = -2;
pub const invalid_state: c_int = -3;
pub const already_exists: c_int = -4;
pub const capacity: c_int = -5;
pub const would_block: c_int = -6;
pub const protocol: c_int = -7;
pub const io_error: c_int = -8;
pub const unsupported: c_int = -9;
pub const internal: c_int = -10;

pub const CHttpHandler = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) void;

pub const CAsyncHandler = *const fn (
    ?*const anyopaque,
    ?*CAsyncResponse,
    ?*anyopaque,
) callconv(.c) c_int;

pub const CMiddleware = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) c_int;

pub const CWsUpgradeHandler = *const fn (?*const anyopaque, ?*anyopaque) callconv(.c) bool;
pub const CWsOpenHandler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const CWsMessageHandler = *const fn (
    ?*anyopaque,
    CSlice,
    c_int,
    ?*anyopaque,
) callconv(.c) void;
pub const CWsEventHandler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Internal trampoline slot authorizing one WebSocket upgrade.
pub const WsUpgradeSlot = *const fn (*const Request) bool;

/// Internal trampoline slot for WebSocket open, drain, and close events.
pub const WsEventSlot = *const fn (*WebSocket) void;

/// Internal trampoline slot receiving one decoded WebSocket message.
pub const WsMessageSlot = *const fn (*WebSocket, []const u8, zslay.Opcode) void;

/// Fixed synchronous HTTP trampoline table indexed by route registration order.
pub const HttpHandlerTable = [max_c_routes]radix.Handler;

/// Fixed WebSocket upgrade trampoline table indexed by route registration order.
pub const WsUpgradeTable = [max_c_routes]WsUpgradeSlot;

/// Fixed WebSocket open, drain, and close trampoline table by route index.
pub const WsEventTable = [max_c_routes]WsEventSlot;

/// Fixed WebSocket message trampoline table indexed by route registration order.
pub const WsMessageTable = [max_c_routes]WsMessageSlot;

/// C-compatible borrowed byte slice.
pub const CSlice = extern struct {
    data: [*c]const u8,
    length: usize,
};

/// Copyable C view of one generation-checked deferred response token.
///
/// The callback-local value may be copied into caller-owned storage before the
/// callback returns pending. The state pointer remains transport-owned.
pub const CAsyncResponse = extern struct {
    /// Opaque pointer to connection- or stream-owned response state.
    state: ?*anyopaque,
    /// Generation captured when the transport armed this token.
    generation: u64,
};

pub const CRoute = struct {
    path: [max_route_path_size]u8 = undefined,
    path_length: usize = 0,
    http_handler: ?CHttpHandler = null,
    async_handler: ?CAsyncHandler = null,
    ws_upgrade: ?CWsUpgradeHandler = null,
    ws_open: ?CWsOpenHandler = null,
    ws_message: ?CWsMessageHandler = null,
    ws_drain: ?CWsEventHandler = null,
    ws_close: ?CWsEventHandler = null,
    user_data: ?*anyopaque = null,
};

pub const CMiddlewareEntry = struct {
    callback: ?CMiddleware = null,
    user_data: ?*anyopaque = null,
};

/// Fixed copied-route storage; the capacity is part of the C ABI contract.
pub const CRouteTable = [max_c_routes]CRoute;

/// Fixed middleware storage; the capacity is part of the C ABI contract.
pub const CMiddlewareTable = [max_c_middleware]CMiddlewareEntry;

pub const CApp = struct {
    threaded: std.Io.Threaded,
    app: App,
    routes: CRouteTable = [_]CRoute{.{}} ** max_c_routes,
    route_count: usize = 0,
    middleware: CMiddlewareTable = [_]CMiddlewareEntry{.{}} ** max_c_middleware,
    middleware_count: usize = 0,
};

pub const CreateMode = enum {
    plain,
    tls,
    http3,
};

/// C-compatible WebSocket callback and limit configuration.
pub const CWebSocketBehavior = extern struct {
    upgrade: ?CWsUpgradeHandler,
    open: ?CWsOpenHandler,
    message: ?CWsMessageHandler,
    drain: ?CWsEventHandler,
    close: ?CWsEventHandler,
    user_data: ?*anyopaque,
    compression: c_int,
    max_frame_size: u64,
    max_message_size: u64,
};

pub const empty_slice: CSlice = .{ .data = null, .length = 0 };
