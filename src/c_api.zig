const std = @import("std");
const app_module = @import("router/app.zig");
const radix = @import("router/radix.zig");
const Request = @import("http/request.zig").Request;
const http_response = @import("http/response.zig");
const AsyncResponse = http_response.AsyncResponse;
const AsyncResponseState = http_response.AsyncResponseState;
const Response = http_response.Response;
const WebSocket = @import("ws/socket.zig").WebSocket;
const TcpConnection = @import("core/tcp.zig").TcpConnection;
const QuicStream = @import("quic/stream.zig").QuicStream;
const zslay = @import("zslay");

const max_connections = 1024;
const max_c_routes = 64;
const max_c_middleware = radix.max_middleware;
const max_route_path_size = 2048;
const App = app_module.app(max_connections);

const ok: c_int = 0;
const invalid_argument: c_int = -1;
const out_of_memory: c_int = -2;
const invalid_state: c_int = -3;
const already_exists: c_int = -4;
const capacity: c_int = -5;
const would_block: c_int = -6;
const protocol: c_int = -7;
const io_error: c_int = -8;
const unsupported: c_int = -9;
const internal: c_int = -10;

const CHttpHandler = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) void;

const CAsyncHandler = *const fn (
    ?*const anyopaque,
    ?*CAsyncResponse,
    ?*anyopaque,
) callconv(.c) c_int;

const CMiddleware = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) c_int;

const CWsUpgradeHandler = *const fn (?*const anyopaque, ?*anyopaque) callconv(.c) bool;
const CWsOpenHandler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const CWsMessageHandler = *const fn (
    ?*anyopaque,
    CSlice,
    c_int,
    ?*anyopaque,
) callconv(.c) void;
const CWsEventHandler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

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

const CRoute = struct {
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

const CMiddlewareEntry = struct {
    callback: ?CMiddleware = null,
    user_data: ?*anyopaque = null,
};

const CApp = struct {
    threaded: std.Io.Threaded,
    app: App,
    routes: [max_c_routes]CRoute = [_]CRoute{.{}} ** max_c_routes,
    route_count: usize = 0,
    middleware: [max_c_middleware]CMiddlewareEntry =
        [_]CMiddlewareEntry{.{}} ** max_c_middleware,
    middleware_count: usize = 0,
};

const CreateMode = enum {
    plain,
    tls,
    http3,
};

/// Returns the versioned C ABI string.
pub export fn uwz_version() [*c]const u8 {
    return "1.0.0";
}

/// Returns a static name for a versioned C error code.
pub export fn uwz_error_name(code: c_int) [*c]const u8 {
    return switch (code) {
        ok => "ok",
        invalid_argument => "invalid argument",
        out_of_memory => "out of memory",
        invalid_state => "invalid state",
        already_exists => "already exists",
        capacity => "capacity reached",
        would_block => "would block",
        protocol => "protocol error",
        io_error => "I/O error",
        unsupported => "unsupported",
        internal => "internal error",
        else => "unknown error",
    };
}

/// Creates a plaintext application with fixed ABI capacities.
pub export fn uwz_app_create(out_app: ?*?*anyopaque) c_int {
    return create_app(.plain, null, null, out_app);
}

/// Creates a TLS application from NUL-terminated certificate paths.
pub export fn uwz_app_create_tls(
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    return create_app(.tls, certificate_path, private_key_path, out_app);
}

/// Creates a dual HTTP/1.1 and HTTP/3 TLS application.
pub export fn uwz_app_create_http3(
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    return create_app(.http3, certificate_path, private_key_path, out_app);
}

/// Stops new work and drains every completion that owns application storage.
pub export fn uwz_app_shutdown(app_pointer: ?*anyopaque) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    app.app.shutdown() catch |err| return map_error(err);
    return ok;
}

/// Drains, releases, and nulls an opaque application handle.
pub export fn uwz_app_destroy(app_pointer: ?*?*anyopaque) c_int {
    const handle = app_pointer orelse return invalid_argument;
    const app = cast_app(handle.*) orelse return invalid_argument;
    if (app.app.is_running()) return invalid_state;
    app.app.shutdown() catch |err| return map_error(err);
    app.app.deinit();
    app.threaded.deinit();
    std.heap.page_allocator.destroy(app);
    handle.* = null;
    return ok;
}

/// Registers a synchronous HTTP route and caller context.
pub export fn uwz_app_route(
    app_pointer: ?*anyopaque,
    method: c_int,
    path_pointer: [*c]const u8,
    path_length: usize,
    handler: ?CHttpHandler,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = handler orelse return invalid_argument;
    const path = required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const index = app.route_count;
    const route = &app.routes[index];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.http_handler = callback;
    route.user_data = user_data;

    register_http_route(
        &app.app,
        method,
        route.path[0..route.path_length],
        http_handlers[index],
    ) catch |err| {
        route.* = .{};
        return map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Registers a deferred HTTP route and caller context.
pub export fn uwz_app_route_async(
    app_pointer: ?*anyopaque,
    method: c_int,
    path_pointer: [*c]const u8,
    path_length: usize,
    handler: ?CAsyncHandler,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = handler orelse return invalid_argument;
    const path = required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const method_value = http_method(method) orelse return invalid_argument;
    const route = &app.routes[app.route_count];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.async_handler = callback;
    route.user_data = user_data;

    _ = app.app.route_async_context(
        method_value,
        route.path[0..route.path_length],
        route,
        async_http_handler,
    ) catch |err| {
        route.* = .{};
        return map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Appends one ordered middleware callback and caller context.
pub export fn uwz_app_use(
    app_pointer: ?*anyopaque,
    middleware: ?CMiddleware,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = middleware orelse return invalid_argument;
    if (app.middleware_count >= max_c_middleware) return capacity;

    const entry = &app.middleware[app.middleware_count];
    entry.* = .{ .callback = callback, .user_data = user_data };
    _ = app.app.use(entry, c_middleware_handler) catch |err| {
        entry.* = .{};
        return map_error(err);
    };
    app.middleware_count += 1;
    return ok;
}

/// Registers a WebSocket route with fixed-capacity callback storage.
pub export fn uwz_app_ws(
    app_pointer: ?*anyopaque,
    path_pointer: [*c]const u8,
    path_length: usize,
    behavior_pointer: ?*const CWebSocketBehavior,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const source = behavior_pointer orelse return invalid_argument;
    const path = required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const compression: radix.WsCompression = switch (source.compression) {
        0 => .disabled,
        1 => .permessage_deflate,
        else => return invalid_argument,
    };
    const index = app.route_count;
    const route = &app.routes[index];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.ws_upgrade = source.upgrade;
    route.ws_open = source.open;
    route.ws_message = source.message;
    route.ws_drain = source.drain;
    route.ws_close = source.close;
    route.user_data = source.user_data;

    _ = app.app.ws(route.path[0..route.path_length], .{
        .upgrade = ws_upgrade_handlers[index],
        .open = ws_open_handlers[index],
        .message = ws_message_handlers[index],
        .drain = ws_drain_handlers[index],
        .close = ws_close_handlers[index],
        .compression = compression,
        .max_frame_size = source.max_frame_size,
        .max_message_size = source.max_message_size,
    }) catch |err| {
        route.* = .{};
        return map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Starts the TCP listener on a borrowed address string.
pub export fn uwz_app_listen(
    app_pointer: ?*anyopaque,
    address_pointer: [*c]const u8,
    address_length: usize,
    port: u16,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const address = required_bytes(address_pointer, address_length) orelse return invalid_argument;
    app.app.listen(address, port) catch |err| return map_error(err);
    return ok;
}

/// Starts the QUIC UDP listener on a borrowed address string.
pub export fn uwz_app_listen_udp(
    app_pointer: ?*anyopaque,
    address_pointer: [*c]const u8,
    address_length: usize,
    port: u16,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const address = required_bytes(address_pointer, address_length) orelse return invalid_argument;
    app.app.listen_udp(address, port) catch |err| return map_error(err);
    return ok;
}

/// Runs the application event loop until it becomes idle.
pub export fn uwz_app_run(app_pointer: ?*anyopaque) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    app.app.run() catch |err| return map_error(err);
    return ok;
}

/// Publishes one message to matching subscribers.
pub export fn uwz_app_publish(
    app_pointer: ?*anyopaque,
    topic: CSlice,
    message: CSlice,
    is_text: bool,
) usize {
    const app = cast_app(app_pointer) orelse return 0;
    const topic_bytes = slice_bytes(topic) orelse return 0;
    const message_bytes = slice_bytes(message) orelse return 0;
    return app.app.publish(topic_bytes, message_bytes, is_text);
}

/// Returns the request method borrowed for the callback duration.
pub export fn uwz_request_method(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    return make_slice(request.method);
}

/// Returns the original request target.
pub export fn uwz_request_target(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    return make_slice(request.target);
}

/// Returns the routed request path.
pub export fn uwz_request_path(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    return make_slice(request.path);
}

/// Returns the request query without the question mark.
pub export fn uwz_request_query(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    return make_slice(request.query);
}

/// Returns the bounded request body.
pub export fn uwz_request_body(request_pointer: ?*const anyopaque) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    return make_slice(request.body);
}

/// Returns the first matching header value.
pub export fn uwz_request_header(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    const header_name = slice_bytes(name) orelse return empty_slice;
    return make_slice(request.get_header(header_name) orelse return empty_slice);
}

/// Counts matching request header fields.
pub export fn uwz_request_header_count(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) usize {
    const request = cast_request(request_pointer) orelse return 0;
    const header_name = slice_bytes(name) orelse return 0;
    return request.count_headers(header_name);
}

/// Returns a route parameter borrowed for the callback duration.
pub export fn uwz_request_parameter(
    request_pointer: ?*const anyopaque,
    name: CSlice,
) CSlice {
    const request = cast_request(request_pointer) orelse return empty_slice;
    const parameter_name = slice_bytes(name) orelse return empty_slice;
    return make_slice(request.get_param(parameter_name) orelse return empty_slice);
}

/// Returns the number of fixed-array route captures on this request.
pub export fn uwz_request_parameter_count(request_pointer: ?*const anyopaque) usize {
    const request = cast_request(request_pointer) orelse return 0;
    return request.route_param_count;
}

/// Completes a response with a status and body.
pub export fn uwz_response_end(
    response_pointer: ?*anyopaque,
    status: CSlice,
    body: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return invalid_argument;
    const status_bytes = slice_bytes(status) orelse return invalid_argument;
    const body_bytes = slice_bytes(body) orelse return invalid_argument;
    response.end(status_bytes, body_bytes) catch |err| return map_error(err);
    return ok;
}

/// Completes a response with validated HTTP/1-style header lines.
pub export fn uwz_response_end_with_headers(
    response_pointer: ?*anyopaque,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return invalid_argument;
    const status_bytes = slice_bytes(status) orelse return invalid_argument;
    const header_bytes = slice_bytes(headers) orelse return invalid_argument;
    const body_bytes = slice_bytes(body) orelse return invalid_argument;
    response.end_with_headers(status_bytes, header_bytes, body_bytes) catch |err| {
        return map_error(err);
    };
    return ok;
}

/// Starts a bounded chunked response.
pub export fn uwz_response_begin_chunked(
    response_pointer: ?*anyopaque,
    status: CSlice,
    headers: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return invalid_argument;
    const status_bytes = slice_bytes(status) orelse return invalid_argument;
    const header_bytes = slice_bytes(headers) orelse return invalid_argument;
    response.begin_chunked(status_bytes, header_bytes) catch |err| return map_error(err);
    return ok;
}

/// Appends one chunk to a response in streaming state.
pub export fn uwz_response_write_chunk(response_pointer: ?*anyopaque, chunk: CSlice) c_int {
    const response = cast_response(response_pointer) orelse return invalid_argument;
    const bytes = slice_bytes(chunk) orelse return invalid_argument;
    response.write_chunk(bytes) catch |err| return map_error(err);
    return ok;
}

/// Finishes a chunked response.
pub export fn uwz_response_end_chunks(response_pointer: ?*anyopaque) c_int {
    const response = cast_response(response_pointer) orelse return invalid_argument;
    response.end_chunks() catch |err| return map_error(err);
    return ok;
}

/// Completes one deferred response generation with a status and body.
pub export fn uwz_async_response_end(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    body: CSlice,
) c_int {
    return complete_async_response(response_pointer, status, empty_slice, body);
}

/// Completes one deferred response generation with validated response fields.
pub export fn uwz_async_response_end_with_headers(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    return complete_async_response(response_pointer, status, headers, body);
}

/// Sends a complete text or binary WebSocket message.
pub export fn uwz_websocket_send(
    socket_pointer: ?*anyopaque,
    message: CSlice,
    opcode: c_int,
) c_int {
    const socket = cast_websocket(socket_pointer) orelse return invalid_argument;
    const message_bytes = slice_bytes(message) orelse return invalid_argument;
    const zig_opcode: zslay.Opcode = switch (opcode) {
        0x1 => .text,
        0x2 => .binary,
        else => return invalid_argument,
    };
    socket.send(message_bytes, zig_opcode) catch |err| return map_error(err);
    return ok;
}

/// Sends a close frame and closes after queued bytes drain.
pub export fn uwz_websocket_send_close(
    socket_pointer: ?*anyopaque,
    code: u16,
    reason: CSlice,
) c_int {
    const socket = cast_websocket(socket_pointer) orelse return invalid_argument;
    const reason_bytes = slice_bytes(reason) orelse return invalid_argument;
    socket.send_close(code, reason_bytes) catch |err| return map_error(err);
    return ok;
}

/// Returns bytes queued for the WebSocket transport.
pub export fn uwz_websocket_buffered_amount(socket_pointer: ?*const anyopaque) usize {
    const socket = cast_const_websocket(socket_pointer) orelse return 0;
    return socket.buffered_amount();
}

/// Subscribes a WebSocket to an owned bounded topic.
pub export fn uwz_websocket_subscribe(socket_pointer: ?*anyopaque, topic: CSlice) c_int {
    const socket = cast_websocket(socket_pointer) orelse return invalid_argument;
    const topic_bytes = slice_bytes(topic) orelse return invalid_argument;
    socket.subscribe(topic_bytes) catch |err| return map_error(err);
    return ok;
}

/// Removes a WebSocket topic subscription.
pub export fn uwz_websocket_unsubscribe(socket_pointer: ?*anyopaque, topic: CSlice) bool {
    const socket = cast_websocket(socket_pointer) orelse return false;
    const topic_bytes = slice_bytes(topic) orelse return false;
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
    const topic_bytes = slice_bytes(topic) orelse return 0;
    const message_bytes = slice_bytes(message) orelse return 0;
    return socket.publish(topic_bytes, message_bytes, is_text);
}

/// Immediately terminates a WebSocket transport.
pub export fn uwz_websocket_terminate(socket_pointer: ?*anyopaque) void {
    const socket = cast_websocket(socket_pointer) orelse return;
    socket.terminate();
}

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

const empty_slice: CSlice = .{ .data = null, .length = 0 };

fn create_app(
    mode: CreateMode,
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    const output = out_app orelse return invalid_argument;
    if (output.* != null) return invalid_argument;

    const app = std.heap.page_allocator.create(CApp) catch return out_of_memory;
    app.threaded = .init(std.heap.c_allocator, .{});
    app.routes = [_]CRoute{.{}} ** max_c_routes;
    app.route_count = 0;
    app.middleware = [_]CMiddlewareEntry{.{}} ** max_c_middleware;
    app.middleware_count = 0;

    app.app = switch (mode) {
        .plain => App.init(app.threaded.io()),
        .tls, .http3 => init: {
            if (certificate_path == null or private_key_path == null) {
                app.threaded.deinit();
                std.heap.page_allocator.destroy(app);
                return invalid_argument;
            }
            const certificate: [*:0]const u8 = @ptrCast(certificate_path);
            const private_key: [*:0]const u8 = @ptrCast(private_key_path);
            break :init if (mode == .tls)
                App.init_https(app.threaded.io(), std.mem.span(certificate), std.mem.span(private_key))
            else
                App.init_http3(app.threaded.io(), std.mem.span(certificate), std.mem.span(private_key));
        },
    } catch |err| {
        app.threaded.deinit();
        std.heap.page_allocator.destroy(app);
        return map_error(err);
    };

    output.* = app;
    return ok;
}

fn register_http_route(
    app: *App,
    method: c_int,
    path: []const u8,
    handler: radix.Handler,
) !void {
    _ = switch (method) {
        0 => try app.get(path, handler),
        1 => try app.head(path, handler),
        2 => try app.post(path, handler),
        3 => try app.put(path, handler),
        4 => try app.delete(path, handler),
        5 => try app.patch(path, handler),
        6 => try app.options(path, handler),
        7 => try app.any(path, handler),
        8 => try app.query(path, handler),
        else => return error.InvalidMethod,
    };
}

fn http_method(method: c_int) ?radix.HttpMethod {
    return switch (method) {
        0 => .get,
        1 => .head,
        2 => .post,
        3 => .put,
        4 => .delete,
        5 => .patch,
        6 => .options,
        7 => .any,
        8 => .query,
        else => null,
    };
}

fn async_http_handler(
    context: *anyopaque,
    request: *Request,
    response: AsyncResponse,
) void {
    const route: *CRoute = @ptrCast(@alignCast(context));
    const callback = route.async_handler orelse {
        fail_pending_response(response);
        return;
    };
    var c_response = CAsyncResponse{
        .state = response.owner,
        .generation = response.generation,
    };

    const result = callback(request, &c_response, route.user_data);
    switch (result) {
        0 => if (response.is_pending()) fail_pending_response(response),
        1 => {},
        else => fail_pending_response(response),
    }
}

fn c_middleware_handler(
    context: *anyopaque,
    request: *Request,
    response: *Response,
) radix.MiddlewareResult {
    const entry: *CMiddlewareEntry = @ptrCast(@alignCast(context));
    const callback = entry.callback orelse return .stop;
    return switch (callback(request, response, entry.user_data)) {
        0 => .continue_dispatch,
        1, 2 => .stop,
        else => .stop,
    };
}

fn fail_pending_response(response: AsyncResponse) void {
    if (!response.is_pending()) return;
    response.complete(
        "500 Internal Server Error",
        "Deferred handler returned without a valid completion state",
    ) catch {
        // Completion failures already consume the token and wake the transport.
    };
}

fn complete_async_response(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    const response = response_pointer orelse return invalid_argument;
    const state_pointer = response.state orelse return invalid_argument;
    if (response.generation == 0) return invalid_argument;

    const status_bytes = slice_bytes(status) orelse return invalid_argument;
    const header_bytes = slice_bytes(headers) orelse return invalid_argument;
    const body_bytes = slice_bytes(body) orelse return invalid_argument;
    const state: *AsyncResponseState = @ptrCast(@alignCast(state_pointer));
    const token = AsyncResponse{
        .owner = state,
        .generation = response.generation,
    };
    token.complete_with_headers(status_bytes, header_bytes, body_bytes) catch |err| {
        return map_error(err);
    };
    return ok;
}

fn http_handler(comptime index: usize) radix.Handler {
    return struct {
        fn call(request: *Request, response: *Response) void {
            const owner = owner_from_response(response);
            const route = &owner.routes[index];
            const callback = route.http_handler orelse return;
            callback(request, response, route.user_data);
        }
    }.call;
}

const http_handlers = handlers: {
    var values: [max_c_routes]radix.Handler = undefined;
    for (0..max_c_routes) |index| values[index] = http_handler(index);
    break :handlers values;
};

fn ws_upgrade_handler(comptime index: usize) *const fn (*const Request) bool {
    return struct {
        fn call(request: *const Request) bool {
            const connection: *TcpConnection = @fieldParentPtr("req", @constCast(request));
            const owner = owner_from_router(connection.router);
            const route = &owner.routes[index];
            const callback = route.ws_upgrade orelse return true;
            return callback(request, route.user_data);
        }
    }.call;
}

fn ws_open_handler(comptime index: usize) *const fn (*WebSocket) void {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_open orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

fn ws_message_handler(
    comptime index: usize,
) *const fn (*WebSocket, []const u8, zslay.Opcode) void {
    return struct {
        fn call(socket: *WebSocket, message: []const u8, opcode: zslay.Opcode) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_message orelse return;
            callback(socket, make_slice(message), @intFromEnum(opcode), route.user_data);
        }
    }.call;
}

fn ws_drain_handler(comptime index: usize) *const fn (*WebSocket) void {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_drain orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

fn ws_close_handler(comptime index: usize) *const fn (*WebSocket) void {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_close orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

const ws_upgrade_handlers = handlers: {
    var values: [max_c_routes]*const fn (*const Request) bool = undefined;
    for (0..max_c_routes) |index| values[index] = ws_upgrade_handler(index);
    break :handlers values;
};

const ws_open_handlers = handlers: {
    var values: [max_c_routes]*const fn (*WebSocket) void = undefined;
    for (0..max_c_routes) |index| values[index] = ws_open_handler(index);
    break :handlers values;
};

const ws_message_handlers = handlers: {
    var values: [max_c_routes]*const fn (*WebSocket, []const u8, zslay.Opcode) void = undefined;
    for (0..max_c_routes) |index| values[index] = ws_message_handler(index);
    break :handlers values;
};

const ws_drain_handlers = handlers: {
    var values: [max_c_routes]*const fn (*WebSocket) void = undefined;
    for (0..max_c_routes) |index| values[index] = ws_drain_handler(index);
    break :handlers values;
};

const ws_close_handlers = handlers: {
    var values: [max_c_routes]*const fn (*WebSocket) void = undefined;
    for (0..max_c_routes) |index| values[index] = ws_close_handler(index);
    break :handlers values;
};

fn owner_from_response(response: *Response) *CApp {
    const router = switch (response.target) {
        .tcp => |connection| connection.router,
        .http2 => |target| @as(
            *const radix.Router,
            @ptrCast(@alignCast(target.router)),
        ),
        .http3 => |target| blk: {
            const stream: *QuicStream = @ptrCast(@alignCast(target.context));
            break :blk stream.router;
        },
    };
    return owner_from_router(router);
}

fn owner_from_router(router: *const radix.Router) *CApp {
    const app: *App = @fieldParentPtr("router", @constCast(router));
    return @fieldParentPtr("app", app);
}

fn cast_app(pointer: ?*anyopaque) ?*CApp {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn cast_request(pointer: ?*const anyopaque) ?*const Request {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn cast_response(pointer: ?*anyopaque) ?*Response {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn cast_websocket(pointer: ?*anyopaque) ?*WebSocket {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn cast_const_websocket(pointer: ?*const anyopaque) ?*const WebSocket {
    return @ptrCast(@alignCast(pointer orelse return null));
}

fn required_bytes(pointer: [*c]const u8, length: usize) ?[]const u8 {
    if (pointer == null) return null;
    return pointer[0..length];
}

fn slice_bytes(slice: CSlice) ?[]const u8 {
    if (slice.length == 0) return "";
    if (slice.data == null) return null;
    return slice.data[0..slice.length];
}

fn make_slice(bytes: []const u8) CSlice {
    if (bytes.len == 0) return empty_slice;
    return .{ .data = bytes.ptr, .length = bytes.len };
}

fn map_error(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory,
        error.TlsContextCreationFailed,
        error.SslAllocationFailed,
        error.BioAllocationFailed,
        error.InitFailed,
        error.LsquicEngineCreationFailed,
        => out_of_memory,
        error.WouldBlock => would_block,
        error.RouteCapacityReached,
        error.RouteStorageCapacityReached,
        error.MiddlewareCapacityReached,
        error.RouteParameterCapacityReached,
        error.CapacityExceeded,
        error.ConnectionCapacityReached,
        error.StreamCapacityReached,
        error.TopicCapacityReached,
        error.SubscriptionCapacityReached,
        error.TopicSubscriberCapacityReached,
        error.BufferTooSmall,
        error.SizeOverflow,
        error.ReferenceCountOverflow,
        => capacity,
        error.RouteAlreadyRegistered,
        error.AlreadyListening,
        error.TlsAlreadyInitialized,
        => already_exists,
        error.InvalidRoutePath,
        error.InvalidRoutePattern,
        error.InvalidWebSocketLimits,
        error.InvalidMethod,
        error.InvalidStatus,
        error.InvalidHeaders,
        error.InvalidOpcode,
        error.InvalidUtf8,
        error.InvalidCloseCode,
        error.InvalidClosePayload,
        error.InvalidCloseFrame,
        error.ControlFrameTooLarge,
        error.BodyNotAllowed,
        error.EmptyTopic,
        error.TopicTooLong,
        error.Overflow,
        error.InvalidEnd,
        error.InvalidCharacter,
        error.Incomplete,
        error.NonCanonical,
        error.ParseFailed,
        error.UnresolvedScope,
        error.KeyMismatch,
        => invalid_argument,
        error.ApplicationUnavailable,
        error.ApplicationDeinitialized,
        error.ApplicationAlreadyRunning,
        error.RoutesLocked,
        error.ResponseAlreadyStarted,
        error.ResponseNotStreaming,
        error.Http3NotInitialized,
        error.ShutdownIncomplete,
        error.AsyncResponseExpired,
        error.AsyncResponseAlreadyCompleted,
        error.ConnectionClosed,
        error.CompressionUnavailable,
        error.PubSubUnavailable,
        error.TransportAlreadyStarted,
        error.TransportShuttingDown,
        error.QuicEngineAlreadyStarted,
        error.TlsUnavailable,
        error.StreamClosed,
        error.NestedRunsNotAllowed,
        => invalid_state,
        error.Http3Unavailable,
        error.BackendUnsupported,
        error.Unsupported,
        => unsupported,
        error.ProtocolError,
        error.InvalidFrame,
        error.InvalidHandshake,
        error.OutputTooLarge,
        => protocol,
        error.BufferOverflow => capacity,
        error.InputOutput,
        error.AccessDenied,
        error.AddressInUse,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.AddressNotAvailable,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.NetworkSubsystemFailed,
        error.SystemResources,
        error.TlsReadFailed,
        error.TlsWriteFailed,
        error.TlsShutdownFailed,
        error.CertificateLoadFailed,
        error.PrivateKeyLoadFailed,
        => io_error,
        else => internal,
    };
}
