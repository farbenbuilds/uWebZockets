//! Fixed-capacity WebTransport datagram routing.
//!
//! A WebTransport session is established by an extended CONNECT request whose
//! `:path` identifies the endpoint, so datagram dispatch keys on that same
//! path. The table is a bounded linear scan over caller-registered routes:
//! registration happens at startup, dispatch touches at most `max_routes`
//! string comparisons, and nothing here allocates.

const std = @import("std");

/// Upper bound on datagram routes per application.
pub const max_routes = 16;

/// Receives one datagram delivered to a registered session path.
///
/// `payload` borrows transport storage and is only valid for the duration of
/// the call; handlers that need to retain bytes must copy them.
pub const Handler = *const fn (context: *anyopaque, session_id: u64, payload: []const u8) void;

/// One registered datagram endpoint.
pub const Route = struct {
    path: []const u8,
    handler: Handler,
    context: *anyopaque,
};

pub const Error = error{
    InvalidPath,
    RouteCapacityReached,
    RouteAlreadyRegistered,
};

/// Bounded path table for datagram handlers.
pub const Router = struct {
    routes: [max_routes]Route = undefined,
    route_count: u8 = 0,

    /// Adds one handler; `path` must outlive the application and start with '/'.
    pub fn register(
        self: *Router,
        path: []const u8,
        handler: Handler,
        context: *anyopaque,
    ) Error!void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        if (self.route_count == max_routes) return error.RouteCapacityReached;
        for (self.routes[0..self.route_count]) |route| {
            if (std.mem.eql(u8, route.path, path)) return error.RouteAlreadyRegistered;
        }

        self.routes[self.route_count] = .{
            .path = path,
            .handler = handler,
            .context = context,
        };
        self.route_count += 1;
    }

    /// Finds the handler registered for a session path.
    pub fn find(self: *const Router, path: []const u8) ?Route {
        for (self.routes[0..self.route_count]) |route| {
            if (std.mem.eql(u8, route.path, path)) return route;
        }
        return null;
    }
};
