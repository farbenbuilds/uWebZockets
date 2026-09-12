const std = @import("std");
const support = @import("test_support");

const json_rpc = support.json_rpc;
const Request = support.http_request.Request;
const Response = support.http_response.Response;

const ResponseCapture = struct {
    status: []const u8 = "",
    headers: [256]u8 = undefined,
    headers_length: usize = 0,
    body: [4096]u8 = undefined,
    body_length: usize = 0,

    fn target(self: *ResponseCapture) support.http_response.Http3Target {
        return .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        };
    }

    fn end(
        context: *anyopaque,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        self.status = status;
        if (headers.len > self.headers.len or body.len > self.body.len) {
            return error.BufferOverflow;
        }
        @memcpy(self.headers[0..headers.len], headers);
        @memcpy(self.body[0..body.len], body);
        self.headers_length = headers.len;
        self.body_length = body.len;
    }

    fn begin(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn write(_: *anyopaque, _: []const u8) !void {}
    fn finish(_: *anyopaque) !void {}
};

const ArithmeticParams = struct {
    left: i64,
    right: i64,
};

const ArithmeticResult = struct {
    difference: i64,
};

const AmountParams = struct {
    amount: usize,
};

fn add(call: *json_rpc.Call) json_rpc.HandlerError!void {
    const parsed = try call.parse_params(ArithmeticParams, std.testing.allocator);
    defer parsed.deinit();
    try call.result(.{ .sum = parsed.value.left + parsed.value.right });
}

fn subtract(params: ArithmeticParams) json_rpc.HandlerError!ArithmeticResult {
    return .{ .difference = params.left - params.right };
}

fn fail_invalid_params(_: *json_rpc.Call) json_rpc.HandlerError!void {
    return error.InvalidParams;
}

fn fail_application(call: *json_rpc.Call) json_rpc.HandlerError!void {
    return call.fail(-32042, "account is locked");
}

const Counter = struct {
    value: usize = 0,

    fn increment(context: *anyopaque, call: *json_rpc.Call) json_rpc.HandlerError!void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.value += 1;
        try call.result(self.value);
    }

    fn add_amount(
        self: *Counter,
        params: AmountParams,
    ) json_rpc.HandlerError!usize {
        self.value += params.amount;
        return self.value;
    }
};

test "rpc: registration owns method names and seals mutation" {
    var service = json_rpc.Service{};
    var name = "math.add".*;
    try service.register(&name, add);
    @memset(&name, 'x');

    var output: [512]u8 = undefined;
    const response = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"math.add\",\"params\":{\"left\":2,\"right\":3},\"id\":1}",
        &output,
    )).?;
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":{\"sum\":5},\"id\":1}",
        response,
    );

    service.seal();
    try std.testing.expectError(error.RegistryLocked, service.register("later", add));
}

test "rpc: typed registration decodes parameters and serializes results" {
    var service = json_rpc.Service{};
    try service.register_typed(
        "math.subtract",
        ArithmeticParams,
        ArithmeticResult,
        subtract,
    );

    var output: [512]u8 = undefined;
    const response = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"math.subtract\",\"params\":{\"left\":9,\"right\":4},\"id\":3}",
        &output,
    )).?;
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":{\"difference\":5},\"id\":3}",
        response,
    );
}

test "rpc: typed context registration keeps state explicit" {
    var counter = Counter{};
    var service = json_rpc.Service{};
    try service.register_typed_context(
        "counter.add",
        &counter,
        AmountParams,
        usize,
        Counter.add_amount,
    );

    var output: [512]u8 = undefined;
    const response = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"counter.add\",\"params\":{\"amount\":4},\"id\":1}",
        &output,
    )).?;
    try std.testing.expectEqual(@as(usize, 4), counter.value);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":4") != null);
}

test "rpc: registration rejects duplicates, reserved names, and capacity overflow" {
    const SmallService = json_rpc.configured_service(1, 8, 256);
    var service = SmallService{};
    try service.register("one", add);
    try std.testing.expectError(error.DuplicateProcedure, service.register("one", add));
    try std.testing.expectError(error.InvalidMethodName, service.register("rpc.test", add));
    try std.testing.expectError(error.ProcedureCapacityReached, service.register("two", add));
}

test "rpc: application mount registers POST and seals procedures" {
    const TestApp = support.app.app(1);
    var application: TestApp = undefined;
    application.router = support.radix.Router.init();
    application.shutting_down = false;
    application.routes_locked = false;
    application.deinitialized = false;

    var service = json_rpc.Service{};
    try service.register("math.add", add);
    _ = try application.rpc("/rpc", &service);

    try std.testing.expect(service.sealed);
    try std.testing.expectError(error.RegistryLocked, service.register("later", add));
    const matched = application.router.match("/rpc", .post).?;
    try std.testing.expect(matched.handler.? == .contextual);
}

test "rpc: protocol failures use standard codes and preserve valid ids" {
    var service = json_rpc.Service{};
    try service.register("invalid", fail_invalid_params);
    try service.register("locked", fail_application);
    var output: [1024]u8 = undefined;

    const malformed = (try service.dispatch("{", &output)).?;
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\"code\":-32700") != null);

    const invalid = (try service.dispatch(
        "{\"jsonrpc\":\"1.0\",\"method\":\"invalid\",\"id\":7}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.endsWith(u8, invalid, "\"id\":null}"));

    const missing = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"missing\",\"id\":\"a\"}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.endsWith(u8, missing, "\"id\":\"a\"}"));

    const bad_params = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"invalid\",\"params\":[],\"id\":8}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, bad_params, "\"code\":-32602") != null);

    const application = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"locked\",\"id\":9}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, application, "\"code\":-32042") != null);
    try std.testing.expect(std.mem.indexOf(u8, application, "account is locked") != null);
}

test "rpc: batches omit notifications and retain invalid elements" {
    var counter = Counter{};
    var service = json_rpc.Service{};
    try service.register_context("counter", &counter, Counter.increment);
    var output: [2048]u8 = undefined;

    const response = (try service.dispatch(
        "[" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"counter\"}," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"counter\",\"id\":2}," ++
            "17," ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"missing\"}" ++
            "]",
        &output,
    )).?;
    try std.testing.expectEqual(@as(usize, 2), counter.value);
    try std.testing.expect(std.mem.startsWith(u8, response, "["));
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "-32601") == null);

    const notification = try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"counter\"}",
        &output,
    );
    try std.testing.expect(notification == null);
    try std.testing.expectEqual(@as(usize, 3), counter.value);
}

test "rpc: malformed batches never execute valid prefixes" {
    var counter = Counter{};
    var service = json_rpc.Service{};
    try service.register_context("counter", &counter, Counter.increment);
    var output: [1024]u8 = undefined;

    const response = (try service.dispatch(
        "[{\"jsonrpc\":\"2.0\",\"method\":\"counter\",\"id\":1},",
        &output,
    )).?;
    try std.testing.expectEqual(@as(usize, 0), counter.value);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
}

test "rpc: escaped method names and duplicate members are handled safely" {
    var service = json_rpc.Service{};
    try service.register("math.add", add);
    var output: [1024]u8 = undefined;

    const escaped = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"math\\u002eadd\",\"params\":{\"left\":5,\"right\":7},\"id\":4}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\"sum\":12") != null);

    const duplicate = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"math.add\",\"method\":\"math.add\",\"id\":4}",
        &output,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "\"code\":-32600") != null);
}

test "rpc: HTTP adapter enforces JSON media type and maps notifications to 204" {
    var counter = Counter{};
    var service = json_rpc.Service{};
    try service.register_context("counter", &counter, Counter.increment);

    var request = Request{
        .method = "POST",
        .body = "{\"jsonrpc\":\"2.0\",\"method\":\"counter\"}",
    };
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try support.json_rpc_http.serve(&service, &request, &response);
    try std.testing.expectEqualStrings("415 Unsupported Media Type", capture.status);

    request.header_names[0] = "Content-Type";
    request.header_values[0] = "application/json; charset=utf-8";
    request.header_count = 1;
    capture = .{};
    response = .{ .target = .{ .http3 = capture.target() } };
    try support.json_rpc_http.serve(&service, &request, &response);
    try std.testing.expectEqualStrings("204 No Content", capture.status);
    try std.testing.expectEqual(@as(usize, 1), counter.value);
}
