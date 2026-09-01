//! Supported µWebZockets public API.

/// Returns the default bounded application type for `max_connections` peers.
pub const App = @import("router/app.zig").app;
/// Returns an application type with explicit WebSocket and write capacities.
pub const ConfiguredApp = @import("router/app.zig").configured_app;
/// Returns an application type with explicit capacities and idle timeout.
pub const ConfiguredAppWithTimeout = @import("router/app.zig").configured_app_with_timeout;
/// Default connection idle timeout in milliseconds.
pub const default_idle_timeout_ms = @import("router/app.zig").default_idle_timeout_ms;
/// Reports whether the build includes the HTTP/3 transport.
pub const http3_available = @import("router/app.zig").http3_available;

/// Borrowed, fixed-capacity HTTP request metadata passed to route callbacks.
pub const Request = @import("http/request.zig").Request;
/// Bounded response writer passed to route callbacks.
pub const Response = @import("http/response.zig").Response;
/// Copyable, generation-checked one-shot asynchronous response token.
pub const AsyncResponse = @import("http/response.zig").AsyncResponse;
/// Connection-owned state backing asynchronous response tokens.
pub const AsyncResponseState = @import("http/response.zig").AsyncResponseState;
/// Lifecycle of a connection-owned asynchronous response slot.
pub const AsyncResponseStatus = @import("http/response.zig").AsyncState;
/// Low-level HTTP/1.1 chunked response helpers.
pub const chunked = @import("http/chunked.zig");

/// HTTP method selector used by generic route registration.
pub const HttpMethod = @import("router/radix.zig").HttpMethod;
/// Existing context-free synchronous route callback.
pub const Handler = @import("router/radix.zig").Handler;
/// Synchronous route callback carrying caller-owned context.
pub const ContextHandler = @import("router/radix.zig").ContextHandler;
/// Deferred route callback receiving an asynchronous response token.
pub const AsyncHandler = @import("router/radix.zig").AsyncHandler;
/// Deferred route callback carrying caller-owned context.
pub const ContextAsyncHandler = @import("router/radix.zig").ContextAsyncHandler;
/// Middleware result controlling whether route dispatch continues.
pub const MiddlewareResult = @import("router/radix.zig").MiddlewareResult;
/// Ordered middleware callback carrying caller-owned context.
pub const MiddlewareHandler = @import("router/radix.zig").MiddlewareHandler;

/// Server-side RFC 6455 connection handle.
pub const WebSocket = @import("ws/socket.zig").WebSocket;
/// WebSocket route callbacks and bounded behavior limits.
pub const WsBehavior = @import("router/radix.zig").WsBehavior;
/// WebSocket compression policy selected per route.
pub const WsCompression = @import("router/radix.zig").WsCompression;
/// RFC 6455 frame opcode.
pub const Opcode = @import("zslay").Opcode;
/// Position-aware WebSocket masking helpers.
pub const websocket_mask = @import("ws/mask.zig");

/// TLS context API backed by BoringSSL.
pub const tls = @import("crypto/tls.zig");
/// Completion-driven UDP/QUIC transport API.
pub const udp = @import("core/udp.zig");
/// Bounded HTTP/2 frame and stream state machine.
pub const http2 = @import("http2/connection.zig");
/// Bounded HPACK decoder, dynamic table, Huffman codec, and response encoder.
pub const http2_hpack = @import("http2/hpack.zig");
/// Allocation-free HTTP/2 request session and response framing API.
pub const http2_server = @import("http2/server.zig");
/// HTTP/3 extended CONNECT, push, and early-data protocol helpers.
pub const http3_extensions = @import("quic/http3_extensions.zig");
/// Bounded WebTransport-over-HTTP/3 draft protocol state.
pub const webtransport = @import("quic/webtransport.zig");

comptime {
    _ = @import("c_api.zig");
}
