//! uWebZockets Main API Entrypoint
//! Follows data-oriented design by separating data structures from behavior.

// --- Core ---
pub const App = @import("router/app.zig").App;

// --- HTTP ---
pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;
pub const chunked = @import("http/chunked.zig");

// --- WebSocket ---
pub const WebSocket = @import("ws/socket.zig").WebSocket;
pub const WsBehavior = @import("router/radix.zig").WsBehavior;

// --- Security / Protocols ---
pub const tls = @import("crypto/tls.zig");
pub const quic = @import("quic/engine.zig");

// --- Tests ---
comptime {
    _ = @import("test.zig");
}
