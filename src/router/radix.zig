const std = @import("std");
const request_module = @import("../http/request.zig");
const Request = request_module.Request;
const Response = @import("../http/response.zig").Response;
const AsyncResponse = @import("../http/response.zig").AsyncResponse;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const zslay = @import("zslay");

/// Existing synchronous route callback ABI.
pub const Handler = *const fn (req: *Request, res: *Response) void;

/// Synchronous callback with a caller-owned context pointer.
pub const ContextHandler = *const fn (context: *anyopaque, req: *Request, res: *Response) void;

/// Deferred callback receiving a copyable, one-shot response token.
pub const AsyncHandler = *const fn (req: *Request, response: AsyncResponse) void;

/// Deferred callback with a caller-owned context pointer.
pub const ContextAsyncHandler = *const fn (
    context: *anyopaque,
    req: *Request,
    response: AsyncResponse,
) void;

/// One registered route callback without heap allocation or erased closures.
pub const RouteHandler = union(enum) {
    synchronous: Handler,
    contextual: struct {
        context: *anyopaque,
        callback: ContextHandler,
    },
    asynchronous: AsyncHandler,
    contextual_async: struct {
        context: *anyopaque,
        callback: ContextAsyncHandler,
    },
};

/// Middleware control flow after one ordered callback.
pub const MiddlewareResult = enum(u8) {
    continue_dispatch,
    stop,
};

/// Ordered middleware callback with explicit caller-owned context.
pub const MiddlewareHandler = *const fn (
    context: *anyopaque,
    req: *Request,
    res: *Response,
) MiddlewareResult;

/// Fixed middleware entry stored directly inside the router.
pub const MiddlewareEntry = struct {
    context: *anyopaque,
    callback: MiddlewareHandler,
};

/// WebSocket compression policy for a registered upgrade route.
pub const WsCompression = enum(u8) {
    disabled,
    permessage_deflate,
};

/// Fixed callback set and limits for a WebSocket route.
pub const WsBehavior = struct {
    /// Optional authorization callback evaluated before the upgrade response.
    upgrade: ?*const fn (req: *const Request) bool = null,
    /// Called after the protocol upgrade becomes active.
    open: ?*const fn (ws: *WebSocket) void = null,
    /// Called once for each complete text or binary message.
    message: ?*const fn (ws: *WebSocket, message: []const u8, opcode: zslay.Opcode) void = null,
    /// Called after write backpressure falls below the connection threshold.
    drain: ?*const fn (ws: *WebSocket) void = null,
    /// Called at most once when the WebSocket closes.
    close: ?*const fn (ws: *WebSocket) void = null,
    /// Negotiates no-context-takeover compression when enabled.
    compression: WsCompression = .disabled,
    /// Maximum encoded payload accepted in one frame.
    max_frame_size: u64 = 16 * 1024,
    /// Maximum decoded payload accepted across a fragmented message.
    max_message_size: u64 = 16 * 1024,
};

/// Validates WebSocket limits against the configured connection slab.
pub fn valid_ws_limits(behavior: WsBehavior, message_capacity: usize) bool {
    if (behavior.max_frame_size == 0 or behavior.max_message_size == 0) return false;
    if (behavior.max_frame_size > behavior.max_message_size) return false;
    return behavior.max_message_size <= @as(u64, @intCast(message_capacity));
}

/// HTTP methods supported by the fixed router.
pub const HttpMethod = enum(u8) {
    get,
    head,
    post,
    put,
    delete,
    patch,
    options,
    any,
    query,

    /// Parses a case-sensitive HTTP method token.
    pub fn parse(value: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, value, "GET")) return .get;
        if (std.mem.eql(u8, value, "HEAD")) return .head;
        if (std.mem.eql(u8, value, "POST")) return .post;
        if (std.mem.eql(u8, value, "PUT")) return .put;
        if (std.mem.eql(u8, value, "DELETE")) return .delete;
        if (std.mem.eql(u8, value, "PATCH")) return .patch;
        if (std.mem.eql(u8, value, "OPTIONS")) return .options;
        if (std.mem.eql(u8, value, "QUERY")) return .query;
        return null;
    }

    /// Returns the canonical method spelling, or empty for `any`.
    pub fn name(method: HttpMethod) []const u8 {
        return switch (method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
            .options => "OPTIONS",
            .any => "",
            .query => "QUERY",
        };
    }
};

const method_count = @typeInfo(HttpMethod).@"enum".fields.len;
const concrete_methods = [_]HttpMethod{ .get, .head, .post, .put, .delete, .patch, .options, .query };
const all_method_mask: u16 = ((@as(u16, 1) << method_count) - 1) &
    ~(@as(u16, 1) << @intFromEnum(HttpMethod.any));

/// Result of exact or parameterized route selection.
pub const RouteMatch = struct {
    /// Borrowed request path used for this lookup.
    path: []const u8,
    /// Selected callback for the requested method, when registered.
    handler: ?RouteHandler,
    /// Legacy synchronous callback when `handler` is synchronous.
    http_handler: ?Handler,
    /// WebSocket behavior registered on this path, when present.
    ws_behavior: ?WsBehavior,
    /// Bit mask used to format the HTTP Allow response field.
    allowed_methods: u16,
    /// Reports whether any HTTP method is registered on this path.
    has_http: bool,
};

const max_nodes = 256;
const max_route_path_size = 2048;
/// Maximum number of parameterized route patterns.
pub const max_pattern_routes = 64;
const max_route_storage_size = (max_nodes + max_pattern_routes) * max_route_path_size;
/// Maximum number of ordered global middleware callbacks.
pub const max_middleware = 32;
const null_node: u16 = std.math.maxInt(u16);
const empty_handlers = [_]?RouteHandler{null} ** method_count;

const PatternRoute = struct {
    handlers: [method_count]?RouteHandler = empty_handlers,
    ws_behavior: ?WsBehavior = null,
    static_bytes: u16 = 0,
    parameter_count: u8 = 0,
    has_wildcard: bool = false,
};

const PatternInfo = struct {
    dynamic: bool = false,
    static_bytes: u16 = 0,
    parameter_count: u8 = 0,
    has_wildcard: bool = false,
};

/// Allocation-free radix router with bounded patterns and middleware.
pub const Router = struct {
    route_storage: [max_route_storage_size]u8 = undefined,
    segment_offsets: [max_nodes]u32 = .{0} ** max_nodes,
    segment_lengths: [max_nodes]u16 = .{0} ** max_nodes,
    first_child: [max_nodes]u16 = .{null_node} ** max_nodes,
    next_sibling: [max_nodes]u16 = .{null_node} ** max_nodes,
    has_route: [max_nodes]bool = .{false} ** max_nodes,
    http_handlers: [max_nodes][method_count]?RouteHandler = .{empty_handlers} ** max_nodes,
    ws_behaviors: [max_nodes]?WsBehavior = .{null} ** max_nodes,
    pattern_routes: [max_pattern_routes]PatternRoute = .{PatternRoute{}} ** max_pattern_routes,
    pattern_offsets: [max_pattern_routes]u32 = .{0} ** max_pattern_routes,
    pattern_lengths: [max_pattern_routes]u16 = .{0} ** max_pattern_routes,
    middleware: [max_middleware]MiddlewareEntry = undefined,

    node_count: u16 = 0,
    root_idx: u16 = null_node,
    pattern_count: u8 = 0,
    middleware_count: u8 = 0,
    route_storage_length: u32 = 0,

    /// Initializes an empty router with fixed inline storage.
    pub fn init() Router {
        var router = Router{};
        router.root_idx = 0;
        router.node_count = 1;
        router.segment_lengths[0] = 0;
        router.first_child[0] = null_node;
        router.next_sibling[0] = null_node;
        router.has_route[0] = false;
        router.http_handlers[0] = empty_handlers;
        router.ws_behaviors[0] = null;
        return router;
    }

    fn alloc_node(self: *Router, bytes: []const u8) !u16 {
        if (self.node_count >= max_nodes) return error.RouteCapacityReached;
        if (bytes.len > max_route_path_size) return error.InvalidRoutePath;

        const index = self.node_count;
        self.segment_offsets[index] = try self.store_path(bytes);
        self.segment_lengths[index] = @intCast(bytes.len);
        self.node_count += 1;
        self.first_child[index] = null_node;
        self.next_sibling[index] = null_node;
        self.has_route[index] = false;
        self.http_handlers[index] = empty_handlers;
        self.ws_behaviors[index] = null;
        return index;
    }

    fn store_path(self: *Router, path: []const u8) !u32 {
        const start: usize = @intCast(self.route_storage_length);
        if (path.len > self.route_storage.len - start) return error.RouteStorageCapacityReached;
        const end = start + path.len;
        @memcpy(self.route_storage[start..end], path);
        self.route_storage_length = @intCast(end);
        return @intCast(start);
    }

    fn segment(self: *const Router, index: u16) []const u8 {
        const start: usize = @intCast(self.segment_offsets[index]);
        const length: usize = self.segment_lengths[index];
        return self.route_storage[start .. start + length];
    }

    fn pattern_path(self: *const Router, index: u8) []const u8 {
        const start: usize = @intCast(self.pattern_offsets[index]);
        const length: usize = self.pattern_lengths[index];
        return self.route_storage[start .. start + length];
    }

    fn common_prefix(first: []const u8, second: []const u8) usize {
        const length = @min(first.len, second.len);
        var index: usize = 0;
        while (index < length and first[index] == second[index]) : (index += 1) {}
        return index;
    }

    fn valid_path(path: []const u8) bool {
        if (path.len == 0 or path.len > max_route_path_size) return false;
        if (path[0] != '/') return false;
        if (std.mem.indexOfAny(u8, path, "?#\r\n") != null) return false;
        return true;
    }

    fn insert_path(self: *Router, path: []const u8) !u16 {
        if (!valid_path(path)) return error.InvalidRoutePath;

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return current;

            var best_child: u16 = null_node;
            var best_prefix: usize = 0;
            var child = self.first_child[current];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const prefix = common_prefix(self.segment(child), search);
                if (prefix == 0) continue;
                best_child = child;
                best_prefix = prefix;
                break;
            }

            if (best_child == null_node) {
                const new_child = try self.alloc_node(search);
                self.next_sibling[new_child] = self.first_child[current];
                self.first_child[current] = new_child;
                return new_child;
            }

            const child_segment = self.segment(best_child);
            if (best_prefix < child_segment.len) {
                const required_nodes: u16 = if (best_prefix < search.len) 2 else 1;
                if (required_nodes > max_nodes - self.node_count) {
                    return error.RouteCapacityReached;
                }

                const split_node = try self.alloc_node(child_segment[best_prefix..]);
                self.first_child[split_node] = self.first_child[best_child];
                self.has_route[split_node] = self.has_route[best_child];
                self.http_handlers[split_node] = self.http_handlers[best_child];
                self.ws_behaviors[split_node] = self.ws_behaviors[best_child];

                self.segment_lengths[best_child] = @intCast(best_prefix);
                self.first_child[best_child] = split_node;
                self.has_route[best_child] = false;
                self.http_handlers[best_child] = empty_handlers;
                self.ws_behaviors[best_child] = null;
            }

            if (best_prefix == search.len) return best_child;
            current = best_child;
            search = search[best_prefix..];
        }
    }

    fn register_http(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        return self.register_route(path, method, .{ .synchronous = handler });
    }

    fn register_route(
        self: *Router,
        path: []const u8,
        method: HttpMethod,
        handler: RouteHandler,
    ) !void {
        const pattern = try analyze_pattern(path);
        if (pattern.dynamic) {
            const route = try self.get_or_add_pattern(path, pattern);
            const method_index = @intFromEnum(method);
            if (route.handlers[method_index] != null) return error.RouteAlreadyRegistered;
            route.handlers[method_index] = handler;
            return;
        }

        const node = try self.insert_path(path);
        const method_index = @intFromEnum(method);
        if (self.http_handlers[node][method_index] != null) return error.RouteAlreadyRegistered;

        self.http_handlers[node][method_index] = handler;
        self.has_route[node] = true;
    }

    /// Registers a synchronous GET route.
    pub fn get(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .get, handler);
    }

    /// Registers a synchronous HEAD route.
    pub fn head(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .head, handler);
    }

    /// Registers a synchronous POST route.
    pub fn post(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .post, handler);
    }

    /// Registers a synchronous PUT route.
    pub fn put(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .put, handler);
    }

    /// Registers a synchronous DELETE route.
    pub fn delete(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .delete, handler);
    }

    /// Registers a synchronous PATCH route.
    pub fn patch(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .patch, handler);
    }

    /// Registers a synchronous OPTIONS route.
    pub fn options(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .options, handler);
    }

    /// Registers a safe, idempotent RFC 10008 QUERY route.
    pub fn query(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .query, handler);
    }

    /// Registers a synchronous fallback method route.
    pub fn any(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .any, handler);
    }

    /// Registers a context-aware route for one method.
    pub fn route_context(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        context: *anyopaque,
        handler: ContextHandler,
    ) !void {
        return self.register_route(path, method, .{ .contextual = .{
            .context = context,
            .callback = handler,
        } });
    }

    /// Registers a deferred route for one method.
    pub fn route_async(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        handler: AsyncHandler,
    ) !void {
        return self.register_route(path, method, .{ .asynchronous = handler });
    }

    /// Registers a context-aware deferred route for one method.
    pub fn route_async_context(
        self: *Router,
        method: HttpMethod,
        path: []const u8,
        context: *anyopaque,
        handler: ContextAsyncHandler,
    ) !void {
        return self.register_route(path, method, .{ .contextual_async = .{
            .context = context,
            .callback = handler,
        } });
    }

    /// Appends one global middleware callback in execution order.
    pub fn use(
        self: *Router,
        context: *anyopaque,
        callback: MiddlewareHandler,
    ) !void {
        if (self.middleware_count == self.middleware.len) return error.MiddlewareCapacityReached;
        self.middleware[self.middleware_count] = .{
            .context = context,
            .callback = callback,
        };
        self.middleware_count += 1;
    }

    /// Executes middleware until a callback or response stops dispatch.
    pub fn run_middleware(
        self: *const Router,
        request: *Request,
        response: *Response,
    ) MiddlewareResult {
        for (self.middleware[0..self.middleware_count]) |entry| {
            const result = entry.callback(entry.context, request, response);
            if (result == .stop or response.is_started()) return .stop;
        }
        return .continue_dispatch;
    }

    /// Registers a WebSocket upgrade route.
    pub fn ws(self: *Router, path: []const u8, behavior: WsBehavior) !void {
        const pattern = try analyze_pattern(path);
        if (pattern.dynamic) {
            const route = try self.get_or_add_pattern(path, pattern);
            if (route.ws_behavior != null) return error.RouteAlreadyRegistered;
            route.ws_behavior = behavior;
            return;
        }

        const node = try self.insert_path(path);
        if (self.ws_behaviors[node] != null) return error.RouteAlreadyRegistered;

        self.ws_behaviors[node] = behavior;
        self.has_route[node] = true;
    }

    /// Matches a path without materializing parameter captures.
    pub fn match(self: *const Router, path: []const u8, method: ?HttpMethod) ?RouteMatch {
        if (self.find_node(path)) |node| return self.node_match(node, path, method);
        const pattern_index = self.find_pattern(path) orelse return null;
        return self.pattern_match(pattern_index, path, method);
    }

    /// Matches a request and stores borrowed route captures in its fixed array.
    pub fn match_request(
        self: *const Router,
        request: *Request,
        method: ?HttpMethod,
    ) ?RouteMatch {
        request.clear_params();
        if (self.find_node(request.path)) |node| {
            return self.node_match(node, request.path, method);
        }

        const pattern_index = self.find_pattern(request.path) orelse return null;
        capture_pattern(
            self.pattern_path(pattern_index),
            request.path,
            request,
        ) catch return null;
        return self.pattern_match(pattern_index, request.path, method);
    }

    fn find_node(self: *const Router, path: []const u8) ?u16 {
        if (self.node_count == 0) return null;

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return if (self.has_route[current]) current else null;

            var child = self.first_child[current];
            var found = false;
            const first_char = search[0];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const child_segment = self.segment(child);
                if (child_segment.len == 0 or child_segment[0] != first_char) continue;
                if (!std.mem.startsWith(u8, search, child_segment)) return null;

                current = child;
                search = search[child_segment.len..];
                found = true;
                break;
            }

            if (!found) return null;
        }
    }

    fn node_has_http(self: *const Router, node: u16) bool {
        for (self.http_handlers[node]) |handler| {
            if (handler != null) return true;
        }
        return false;
    }

    fn node_match(
        self: *const Router,
        node: u16,
        path: []const u8,
        method: ?HttpMethod,
    ) RouteMatch {
        const handler = select_handler(&self.http_handlers[node], method);
        return .{
            .path = path,
            .handler = handler,
            .http_handler = legacy_handler(handler),
            .ws_behavior = self.ws_behaviors[node],
            .allowed_methods = self.allowed_method_mask(node),
            .has_http = self.node_has_http(node),
        };
    }

    fn pattern_match(
        self: *const Router,
        pattern_index: u8,
        path: []const u8,
        method: ?HttpMethod,
    ) RouteMatch {
        const route = self.pattern_routes[pattern_index];
        const handler = select_handler(&route.handlers, method);
        return .{
            .path = path,
            .handler = handler,
            .http_handler = legacy_handler(handler),
            .ws_behavior = route.ws_behavior,
            .allowed_methods = allowed_handler_mask(&route.handlers, route.ws_behavior != null),
            .has_http = handlers_present(&route.handlers),
        };
    }

    fn get_or_add_pattern(
        self: *Router,
        path: []const u8,
        info: PatternInfo,
    ) !*PatternRoute {
        for (0..self.pattern_count) |index| {
            if (std.mem.eql(u8, self.pattern_path(@intCast(index)), path)) {
                return &self.pattern_routes[index];
            }
        }
        if (self.pattern_count == self.pattern_routes.len) return error.RouteCapacityReached;

        const index = self.pattern_count;
        self.pattern_offsets[index] = try self.store_path(path);
        self.pattern_lengths[index] = @intCast(path.len);
        self.pattern_count += 1;
        self.pattern_routes[index] = .{
            .static_bytes = info.static_bytes,
            .parameter_count = info.parameter_count,
            .has_wildcard = info.has_wildcard,
        };
        return &self.pattern_routes[index];
    }

    fn find_pattern(self: *const Router, path: []const u8) ?u8 {
        var best: ?u8 = null;
        for (0..self.pattern_count) |index| {
            const route = self.pattern_routes[index];
            if (!pattern_matches(self.pattern_path(@intCast(index)), path)) continue;
            const current = best orelse {
                best = @intCast(index);
                continue;
            };
            const selected = self.pattern_routes[current];
            if (route.static_bytes > selected.static_bytes or
                (route.static_bytes == selected.static_bytes and
                    !route.has_wildcard and selected.has_wildcard) or
                (route.static_bytes == selected.static_bytes and
                    route.has_wildcard == selected.has_wildcard and
                    route.parameter_count < selected.parameter_count))
            {
                best = @intCast(index);
            }
        }
        return best;
    }

    fn allowed_method_mask(self: *const Router, node: u16) u16 {
        if (self.http_handlers[node][@intFromEnum(HttpMethod.any)] != null) {
            return all_method_mask;
        }

        var mask: u16 = 0;
        for (concrete_methods) |method| {
            if (self.http_handlers[node][@intFromEnum(method)] == null) continue;
            mask |= method_bit(method);
            if (method == .get) mask |= method_bit(.head);
        }
        if (self.ws_behaviors[node] != null) mask |= method_bit(.get);
        return mask;
    }
};

/// Formats a deterministic `Allow` field value into caller storage.
pub fn format_allowed_methods(mask: u16, buffer: []u8) ![]const u8 {
    var offset: usize = 0;

    for (concrete_methods) |method| {
        if (mask & method_bit(method) == 0) continue;

        const separator = if (offset == 0) "" else ", ";
        const method_name = method.name();
        if (separator.len + method_name.len > buffer.len - offset) return error.BufferTooSmall;

        @memcpy(buffer[offset .. offset + separator.len], separator);
        offset += separator.len;
        @memcpy(buffer[offset .. offset + method_name.len], method_name);
        offset += method_name.len;
    }
    return buffer[0..offset];
}

fn select_handler(
    handlers: *const [method_count]?RouteHandler,
    method: ?HttpMethod,
) ?RouteHandler {
    var handler: ?RouteHandler = null;
    if (method) |known_method| {
        handler = handlers[@intFromEnum(known_method)];
        if (handler == null and known_method == .head) {
            handler = handlers[@intFromEnum(HttpMethod.get)];
        }
    }
    if (handler == null) handler = handlers[@intFromEnum(HttpMethod.any)];
    return handler;
}

fn legacy_handler(handler: ?RouteHandler) ?Handler {
    const binding = handler orelse return null;
    return switch (binding) {
        .synchronous => |callback| callback,
        else => null,
    };
}

fn handlers_present(handlers: *const [method_count]?RouteHandler) bool {
    for (handlers) |handler| {
        if (handler != null) return true;
    }
    return false;
}

fn allowed_handler_mask(
    handlers: *const [method_count]?RouteHandler,
    has_websocket: bool,
) u16 {
    if (handlers[@intFromEnum(HttpMethod.any)] != null) return all_method_mask;

    var mask: u16 = 0;
    for (concrete_methods) |method| {
        if (handlers[@intFromEnum(method)] == null) continue;
        mask |= method_bit(method);
        if (method == .get) mask |= method_bit(.head);
    }
    if (has_websocket) mask |= method_bit(.get);
    return mask;
}

fn analyze_pattern(path: []const u8) !PatternInfo {
    if (!Router.valid_path(path)) return error.InvalidRoutePath;

    var info = PatternInfo{};
    var cursor: usize = 1;
    while (cursor <= path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, cursor, '/') orelse path.len;
        const segment = path[cursor..end];
        if (segment.len != 0 and (segment[0] == ':' or segment[0] == '*')) {
            if (segment.len == 1 or !valid_parameter_name(segment[1..])) {
                return error.InvalidRoutePattern;
            }
            info.dynamic = true;
            if (info.parameter_count == request_module.max_route_params) {
                return error.RouteParameterCapacityReached;
            }
            info.parameter_count += 1;
            if (segment[0] == '*') {
                if (end != path.len) return error.InvalidRoutePattern;
                info.has_wildcard = true;
            }
        } else {
            if (segment.len > std.math.maxInt(u16) - info.static_bytes) {
                return error.InvalidRoutePattern;
            }
            info.static_bytes += @intCast(segment.len);
        }

        if (end == path.len) break;
        cursor = end + 1;
    }
    if (duplicate_parameter_name(path)) return error.InvalidRoutePattern;
    return info;
}

fn valid_parameter_name(name: []const u8) bool {
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn duplicate_parameter_name(pattern: []const u8) bool {
    var outer: usize = 1;
    while (outer < pattern.len) {
        const outer_end = std.mem.indexOfScalarPos(u8, pattern, outer, '/') orelse pattern.len;
        const outer_segment = pattern[outer..outer_end];
        if (outer_segment.len > 1 and (outer_segment[0] == ':' or outer_segment[0] == '*')) {
            var inner = outer_end + @as(usize, @intFromBool(outer_end < pattern.len));
            while (inner < pattern.len) {
                const inner_end = std.mem.indexOfScalarPos(u8, pattern, inner, '/') orelse pattern.len;
                const inner_segment = pattern[inner..inner_end];
                if (inner_segment.len > 1 and
                    (inner_segment[0] == ':' or inner_segment[0] == '*') and
                    std.mem.eql(u8, outer_segment[1..], inner_segment[1..]))
                {
                    return true;
                }
                if (inner_end == pattern.len) break;
                inner = inner_end + 1;
            }
        }
        if (outer_end == pattern.len) break;
        outer = outer_end + 1;
    }
    return false;
}

fn pattern_matches(pattern: []const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var pattern_cursor: usize = 1;
    var path_cursor: usize = 1;

    while (pattern_cursor <= pattern.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_cursor, '/') orelse pattern.len;
        const segment = pattern[pattern_cursor..pattern_end];
        if (segment.len > 0 and segment[0] == '*') return true;

        const path_end = std.mem.indexOfScalarPos(u8, path, path_cursor, '/') orelse path.len;
        const value = path[path_cursor..path_end];
        if (segment.len > 0 and segment[0] == ':') {
            if (value.len == 0) return false;
        } else if (!std.mem.eql(u8, segment, value)) {
            return false;
        }

        if (pattern_end == pattern.len) return path_end == path.len;
        if (path_end == path.len) {
            pattern_cursor = pattern_end + 1;
            path_cursor = path.len;
            continue;
        }
        pattern_cursor = pattern_end + 1;
        path_cursor = path_end + 1;
    }
    return path_cursor == path.len;
}

fn capture_pattern(pattern: []const u8, path: []const u8, request: *Request) !void {
    var pattern_cursor: usize = 1;
    var path_cursor: usize = 1;

    while (pattern_cursor <= pattern.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_cursor, '/') orelse pattern.len;
        const segment = pattern[pattern_cursor..pattern_end];
        if (segment.len > 0 and segment[0] == '*') {
            try request.add_param(segment[1..], path[path_cursor..]);
            return;
        }

        const path_end = std.mem.indexOfScalarPos(u8, path, path_cursor, '/') orelse path.len;
        if (segment.len > 0 and segment[0] == ':') {
            try request.add_param(segment[1..], path[path_cursor..path_end]);
        }
        if (pattern_end == pattern.len) return;
        pattern_cursor = pattern_end + 1;
        path_cursor = if (path_end == path.len) path.len else path_end + 1;
    }
}

fn method_bit(method: HttpMethod) u16 {
    std.debug.assert(method != .any);
    return @as(u16, 1) << @as(u4, @intCast(@intFromEnum(method)));
}
