const std = @import("std");
const xev = @import("xev");
const support = @import("test_support");
const app = support.app;
const radix = support.radix;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const AsyncResponseState = support.http_response.AsyncResponseState;

// dummy handler to verify route routing
fn dummy_handler(req: *Request, res: *Response) void {
    _ = req;
    _ = res;
}

fn exact_handler(_: *Request, _: *Response) void {}

const ResponseSink = struct {
    end_count: usize = 0,
    wake_count: usize = 0,

    fn end(
        context: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !void {
        const self: *ResponseSink = @ptrCast(@alignCast(context));
        self.end_count += 1;
    }

    fn begin(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn write(_: *anyopaque, _: []const u8) !void {}
    fn finish(_: *anyopaque) !void {}

    fn wake(context: *anyopaque) void {
        const self: *ResponseSink = @ptrCast(@alignCast(context));
        self.wake_count += 1;
    }

    fn response(self: *ResponseSink) Response {
        return .{ .target = .{ .http3 = .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        } } };
    }
};

const MiddlewareContext = struct {
    order: *[4]u8,
    count: *usize,
    id: u8,
    stop: bool = false,

    fn run(context: *anyopaque, _: *Request, response: *Response) radix.MiddlewareResult {
        const self: *MiddlewareContext = @ptrCast(@alignCast(context));
        self.order[self.count.*] = self.id;
        self.count.* += 1;
        if (!self.stop) return .continue_dispatch;
        response.end("204 No Content", "") catch @panic("test fixture response failed");
        return .stop;
    }
};

const HandlerContext = struct {
    called: bool = false,

    fn handle(context: *anyopaque, _: *Request, _: *Response) void {
        const self: *HandlerContext = @ptrCast(@alignCast(context));
        self.called = true;
    }
};

fn deferred_handler(_: *Request, _: support.http_response.AsyncResponse) void {}

// tests radix trie insertion and exact matching
test "router: radix trie exact match" {
    var router = radix.Router.init();

    try router.get("/api/v1/users", dummy_handler);
    try router.post("/api/v1/users", dummy_handler);
    try router.get("/api/v1/posts", dummy_handler);
    try router.ws("/chat", .{});

    const r1 = router.match("/api/v1/users", .get);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r1.?.http_handler != null);

    const r2 = router.match("/api/v1/posts", .get);
    try std.testing.expect(r2 != null);

    const r3 = router.match("/chat", .get);
    try std.testing.expect(r3 != null);
    try std.testing.expect(r3.?.ws_behavior != null);

    const r4 = router.match("/notfound", .get);
    try std.testing.expect(r4 == null);

    const method_mismatch = router.match("/api/v1/posts", .post).?;
    try std.testing.expect(method_mismatch.http_handler == null);

    var allow_buffer: [64]u8 = undefined;
    const allow = try radix.format_allowed_methods(method_mismatch.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings("GET, HEAD", allow);
}

test "router: RFC 10008 QUERY is routed as a safe body-bearing method" {
    var router = radix.Router.init();
    try router.query("/search", dummy_handler);

    try std.testing.expectEqual(radix.HttpMethod.query, radix.HttpMethod.parse("QUERY").?);
    try std.testing.expectEqualStrings("QUERY", radix.HttpMethod.query.name());

    const match = router.match("/search", .query).?;
    try std.testing.expect(match.http_handler != null);
    var allow_buffer: [96]u8 = undefined;
    const allow = try radix.format_allowed_methods(match.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings("QUERY", allow);
}

test "router: ANY advertises every concrete method including QUERY" {
    var router = radix.Router.init();
    try router.any("/resource", dummy_handler);

    const match = router.match("/resource", .query).?;
    var allow_buffer: [96]u8 = undefined;
    const allow = try radix.format_allowed_methods(match.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings(
        "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, QUERY",
        allow,
    );
}

test "router: registration copies exact and parameterized paths" {
    var router = radix.Router.init();
    var exact_path = "/owned".*;
    var pattern_path = "/users/:id".*;
    try router.get(&exact_path, dummy_handler);
    try router.get(&pattern_path, dummy_handler);

    @memset(&exact_path, 'x');
    @memset(&pattern_path, 'x');

    try std.testing.expect(router.match("/owned", .get).?.http_handler != null);
    var request = Request{ .path = "/users/42" };
    try std.testing.expect(router.match_request(&request, .get).?.http_handler != null);
    try std.testing.expectEqualStrings("42", request.get_param("id").?);
}

test "router: application timeout policy is compile-time configurable" {
    const WithoutIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 0);
    const WithShortIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 1000);

    _ = WithoutIdleTimeout;
    _ = WithShortIdleTimeout;
    try std.testing.expectEqual(@as(u64, 120_000), app.default_idle_timeout_ms);
}

test "router: websocket limits must fit the configured slab" {
    try std.testing.expect(radix.valid_ws_limits(.{}, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{ .max_frame_size = 0 }, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{ .max_message_size = 32 * 1024 }, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{
        .max_frame_size = 1024,
        .max_message_size = 512,
    }, 16 * 1024));
}

test "router: compression scratch separates receive and send state" {
    var storage = [_]u8{0} ** 32;
    const buffers = app.compression_buffers(&storage, 8, 1) orelse {
        return error.TestUnexpectedResult;
    };

    @memset(buffers.incoming, 0xa5);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 8), buffers.incoming);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), buffers.outgoing);
    try std.testing.expect(app.compression_buffers(&storage, 8, 2) == null);
}

test "router: route registration locks before callbacks can observe mutation" {
    const TestApp = app.app(1);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();
    server.routes_locked = true;

    try std.testing.expectError(error.RoutesLocked, server.get("/", dummy_handler));
}

test "router: callback shutdown is drained by the active outer run" {
    const TestApp = app.configured_app_with_timeout(1, 1024, 4096, 0);
    const Probe = struct {
        server: *TestApp,
        timer: xev.Timer,
        completion: xev.Completion = .{},
        callback_called: bool = false,
        observed_running: bool = false,
        shutdown_error: ?anyerror = null,

        fn route(context: *anyopaque, _: *Request, _: *Response) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callback_called = true;
            self.observed_running = self.server.is_running();
            self.server.shutdown() catch |err| {
                self.shutdown_error = err;
            };
        }

        fn fire(
            user_data: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                self.shutdown_error = err;
                return .disarm;
            };

            var request = Request{ .path = "/shutdown" };
            const matched = self.server.router.match_request(&request, .get) orelse {
                self.shutdown_error = error.RouteMissing;
                return .disarm;
            };
            var sink = ResponseSink{};
            var response = sink.response();
            switch (matched.handler orelse {
                self.shutdown_error = error.HandlerMissing;
                return .disarm;
            }) {
                .contextual => |binding| binding.callback(binding.context, &request, &response),
                else => self.shutdown_error = error.UnexpectedHandler,
            }
            return .disarm;
        }
    };

    var server = try TestApp.init(std.testing.io);
    defer server.deinit();
    var probe = Probe{
        .server = &server,
        .timer = try xev.Timer.init(),
    };
    defer probe.timer.deinit();

    _ = try server.route_context(.get, "/shutdown", &probe, Probe.route);
    probe.timer.run(
        server.loop.get_xev_loop(),
        &probe.completion,
        1,
        Probe,
        &probe,
        Probe.fire,
    );

    try server.run();
    try std.testing.expect(probe.callback_called);
    try std.testing.expect(probe.observed_running);
    try std.testing.expect(probe.shutdown_error == null);
    try std.testing.expect(server.shutting_down);
    try std.testing.expect(!server.is_running());
}

test "router: exact route wins before bounded parameter patterns" {
    var router = radix.Router.init();
    try router.get("/users/:id", dummy_handler);
    try router.get("/users/new", exact_handler);
    try router.get("/assets/*path", dummy_handler);

    var request = Request{ .path = "/users/42" };
    const parameterized = router.match_request(&request, .get).?;
    try std.testing.expect(parameterized.http_handler != null);
    try std.testing.expectEqualStrings("42", request.get_param("id").?);

    request.path = "/users/new";
    const exact = router.match_request(&request, .get).?;
    try std.testing.expectEqual(@intFromPtr(&exact_handler), @intFromPtr(exact.http_handler.?));
    try std.testing.expectEqual(@as(usize, 0), request.route_param_count);

    request.path = "/assets/css/site.css";
    _ = router.match_request(&request, .get).?;
    try std.testing.expectEqualStrings("css/site.css", request.get_param("path").?);

    request.path = "/assets";
    _ = router.match_request(&request, .get).?;
    try std.testing.expectEqualStrings("", request.get_param("path").?);
}

test "router: route patterns fail closed when malformed or over capacity" {
    var router = radix.Router.init();
    try std.testing.expectError(
        error.InvalidRoutePattern,
        router.get("/files/*path/more", dummy_handler),
    );
    try std.testing.expectError(
        error.InvalidRoutePattern,
        router.get("/users/:id/posts/:id", dummy_handler),
    );
    try std.testing.expectError(
        error.RouteParameterCapacityReached,
        router.get(
            "/:a/:b/:c/:d/:e/:f/:g/:h/:i/:j/:k/:l/:m/:n/:o/:p/:q",
            dummy_handler,
        ),
    );
}

test "router: middleware runs in order and stops after a response" {
    var router = radix.Router.init();
    var order = [_]u8{0} ** 4;
    var count: usize = 0;
    var first = MiddlewareContext{ .order = &order, .count = &count, .id = 1 };
    var second = MiddlewareContext{ .order = &order, .count = &count, .id = 2, .stop = true };
    var third = MiddlewareContext{ .order = &order, .count = &count, .id = 3 };
    try router.use(&first, MiddlewareContext.run);
    try router.use(&second, MiddlewareContext.run);
    try router.use(&third, MiddlewareContext.run);

    var sink = ResponseSink{};
    var response = sink.response();
    var request = Request{};
    try std.testing.expectEqual(
        radix.MiddlewareResult.stop,
        router.run_middleware(&request, &response),
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, order[0..count]);
    try std.testing.expectEqual(@as(usize, 1), sink.end_count);
}

test "router: middleware and route tables enforce fixed capacities" {
    var router = radix.Router.init();
    var context: u8 = 0;
    for (0..radix.max_middleware) |_| {
        try router.use(&context, MiddlewareContext.run);
    }
    try std.testing.expectError(
        error.MiddlewareCapacityReached,
        router.use(&context, MiddlewareContext.run),
    );
}

test "router: contextual and async handlers preserve legacy sync ABI" {
    var router = radix.Router.init();
    var context = HandlerContext{};
    try router.route_context(.get, "/context", &context, HandlerContext.handle);
    try router.route_async(.get, "/deferred/:id", deferred_handler);
    try router.get("/sync", dummy_handler);

    var request = Request{ .path = "/context" };
    const contextual = router.match_request(&request, .get).?;
    try std.testing.expect(contextual.http_handler == null);
    switch (contextual.handler.?) {
        .contextual => |binding| {
            var sink = ResponseSink{};
            var response = sink.response();
            binding.callback(binding.context, &request, &response);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(context.called);

    request.path = "/deferred/7";
    const deferred = router.match_request(&request, .get).?;
    try std.testing.expect(deferred.http_handler == null);
    try std.testing.expect(deferred.handler.? == .asynchronous);

    request.path = "/sync";
    const synchronous = router.match_request(&request, .get).?;
    try std.testing.expect(synchronous.http_handler != null);
}

test "router: async response token is generation checked and one shot" {
    var sink = ResponseSink{};
    var state = AsyncResponseState{};
    const target = support.http_response.AsyncTarget{
        .context = &sink,
        .complete_fn = ResponseSink.end,
        .wake_fn = ResponseSink.wake,
    };

    const first = state.arm(target);
    try first.complete("200 OK", "done");
    try std.testing.expectEqual(@as(usize, 1), sink.end_count);
    try std.testing.expectEqual(@as(usize, 1), sink.wake_count);
    try std.testing.expectError(
        error.AsyncResponseAlreadyCompleted,
        first.complete("200 OK", "again"),
    );

    const second = state.arm(target);
    try std.testing.expectError(
        error.AsyncResponseExpired,
        first.complete("200 OK", "stale"),
    );
    state.cancel();
    try std.testing.expectError(
        error.AsyncResponseExpired,
        second.complete("200 OK", "closed"),
    );
}
