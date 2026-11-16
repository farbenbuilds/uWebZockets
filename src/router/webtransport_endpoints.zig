const datagram = @import("datagram.zig");
const stream_api = @import("../quic/webtransport/stream_api.zig");
const RouteId = datagram.RouteId;

pub const max_routes = 16;

/// Context and path storage remain caller-owned for the listener lifetime.
pub const DatagramBinding = struct {
    handler: datagram.Handler,
    context: *anyopaque,
};

pub const StreamBinding = struct {
    callbacks: stream_api.Callbacks,
    context: *anyopaque,
};

/// One path can independently provide datagram and stream capabilities.
pub const Endpoint = struct {
    path: []const u8 = "",
    datagram: ?DatagramBinding = null,
    streams: ?StreamBinding = null,
};

pub const Error = error{ InvalidPath, RouteCapacityReached, RouteAlreadyRegistered };

/// Registration is bounded and startup-only; lookups never allocate.
pub const Registry = struct {
    routes: [max_routes]Endpoint = @splat(.{}),
    route_count: u8 = 0,

    /// The path and context borrow caller storage through listener shutdown.
    pub fn register_datagram(registry: *Registry, path: []const u8, handler: datagram.Handler, context: *anyopaque) Error!RouteId {
        const id = try registry.ensure_endpoint(path);
        const endpoint = &registry.routes[@intFromEnum(id)];
        if (endpoint.datagram != null) return error.RouteAlreadyRegistered;
        endpoint.datagram = .{ .handler = handler, .context = context };
        return id;
    }

    /// Stream callbacks use an independent context even on a shared path.
    pub fn register_streams(registry: *Registry, path: []const u8, callbacks: stream_api.Callbacks, context: *anyopaque) Error!RouteId {
        const id = try registry.ensure_endpoint(path);
        const endpoint = &registry.routes[@intFromEnum(id)];
        if (endpoint.streams != null) return error.RouteAlreadyRegistered;
        endpoint.streams = .{ .callbacks = callbacks, .context = context };
        return id;
    }

    /// Resolves a path to an identity without retaining request-owned bytes.
    pub fn find_id(registry: *const Registry, path: []const u8) ?RouteId {
        for (registry.routes[0..registry.route_count], 0..) |endpoint, index| {
            if (std.mem.eql(u8, endpoint.path, path)) return @enumFromInt(index);
        }
        return null;
    }

    /// Values borrow the registered path and context; invalid IDs return null.
    pub fn get(registry: *const Registry, id: RouteId) ?Endpoint {
        const index = @intFromEnum(id);
        if (index >= registry.route_count) return null;
        return registry.routes[index];
    }

    /// Finds either or both capabilities attached to an exact path.
    pub fn find(registry: *const Registry, path: []const u8) ?Endpoint {
        return registry.get(registry.find_id(path) orelse return null);
    }

    fn ensure_endpoint(registry: *Registry, path: []const u8) Error!RouteId {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        if (registry.find_id(path)) |id| return id;
        if (registry.route_count == max_routes) return error.RouteCapacityReached;
        const index = registry.route_count;
        // A new endpoint has no capabilities, so the caller cannot reject a duplicate.
        registry.routes[index] = .{ .path = path };
        registry.route_count += 1;
        return @enumFromInt(index);
    }
};
const std = @import("std");
