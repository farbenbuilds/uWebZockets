const std = @import("std");
const support = @import("test_support");
const uz = support.public_api;
const LegacyFormError = error{
    MissingContentType,
    TooManyQueryParameters,
    QueryComponentTooLong,
    UnsupportedMediaType,
};

fn narrow_form(request: *const uz.Request) LegacyFormError!uz.query.QueryParams {
    return try request.form();
}

fn exhaustive_form(request: *const uz.Request) ?uz.query.QueryParams {
    return request.form() catch |err| switch (err) {
        error.MissingContentType => null,
        error.TooManyQueryParameters => null,
        error.QueryComponentTooLong => null,
        error.UnsupportedMediaType => null,
    };
}

test "streaming request: old narrow and exhaustive form consumers remain unchanged" {
    var request = uz.Request{ .body = "name=buffered" };
    try request.add_header("Content-Type", "application/x-www-form-urlencoded");
    const narrow = try narrow_form(&request);
    try std.testing.expectEqualStrings("buffered", narrow.get("name").?);
    const exhaustive = exhaustive_form(&request).?;
    try std.testing.expectEqualStrings("buffered", exhaustive.get("name").?);
    request.body = "";
    try std.testing.expect((try narrow_form(&request)).get("name") == null);
}

// Instantiating Zig's JSON parser for an untagged union is a compile error.
const Payload = union { value: []const u8, count: u64 };

test "streaming request: dedicated helpers refuse before parsing allocation content type or issue changes" {
    var request = uz.Request{ .body = "{broken", .target = "/upload?name=ok" };
    const view = uz.StreamingRequest.from_request(&request);
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    const memory = allocator.allocator();
    try std.testing.expectEqualStrings("", view.text());
    try std.testing.expectEqualStrings("", view.bytes());
    const json_result: uz.BodyReadError!std.json.Parsed(Payload) = view.json(Payload, memory);
    try std.testing.expectError(error.BodyNotBuffered, json_result);
    const validated: uz.BodyReadError!std.json.Parsed(Payload) = view.validate_json(Payload, memory);
    try std.testing.expectError(error.BodyNotBuffered, validated);
    var issue = uz.schema.Issue{ .field = "untouched", .kind = .too_deep };
    const detailed: uz.BodyReadError!std.json.Parsed(Payload) = view.validate_json_detailed(Payload, memory, &issue);
    try std.testing.expectError(error.BodyNotBuffered, detailed);
    try std.testing.expectEqualStrings("untouched", issue.field);
    try std.testing.expectEqual(uz.schema.IssueKind.too_deep, issue.kind);
    const form_result: uz.BodyReadError!uz.query.QueryParams = view.form();
    const multipart_result: uz.BodyReadError!uz.multipart.Parser = view.multipart();
    try std.testing.expectError(error.BodyNotBuffered, form_result);
    try std.testing.expectError(error.BodyNotBuffered, multipart_result);
    try std.testing.expectEqual(@as(usize, 0), allocator.end_index);
    const query = try view.query_params();
    try std.testing.expectEqualStrings("ok", query.get("name").?);
    try std.testing.expect(!@hasField(uz.StreamingRequest, "body"));
    try std.testing.expect(!@hasField(uz.StreamingRequest, "request"));
}

const Fixture = struct {
    bytes: [4096]u8 = undefined,
    length: usize = 0,
    request: uz.Request = .{},
    header_names: [2][]const u8 = undefined,
    header_values: [2][]const u8 = undefined,
    param_names: [2][]const u8 = undefined,
    param_values: [2][]const u8 = undefined,

    fn put(self: *Fixture, input: []const u8) []const u8 {
        std.debug.assert(input.len <= self.bytes.len - self.length);
        const result = self.bytes[self.length..][0..input.len];
        @memcpy(result, input);
        self.length += input.len;
        return result;
    }

    fn init(self: *Fixture) !void {
        self.* = .{};
        self.request.method = self.put("POST");
        self.request.target = self.put("/upload?q=ok");
        self.request.path = self.put("/upload");
        self.request.protocol = self.put("webtransport");
        self.request.query = self.put("q=ok");
        self.request.body = self.put("ignored future body");
        self.request.extra_header_names = &self.header_names;
        self.request.extra_header_values = &self.header_values;
        self.request.extra_param_names = &self.param_names;
        self.request.extra_param_values = &self.param_values;
        try self.request.add_header(self.put("Content-Type"), self.put("application/octet-stream"));
        for (1..63) |_| try self.request.add_header(self.put("x-inline"), self.put("inline-value"));
        try self.request.add_header(self.put("x-dup"), self.put("first"));
        try self.request.add_header(self.put("x-extra"), self.put("extra-value"));
        try self.request.add_header(self.put("X-Dup"), self.put("second"));
        try self.request.add_param(self.put("Id"), self.put("42"));
        for (1..16) |_| try self.request.add_param(self.put("segment"), self.put("inline-capture"));
        try self.request.add_param(self.put("Tail"), self.put("rest/of/path"));
        try self.request.add_param(self.put("extra"), self.put("overflow"));
    }

    fn poison(self: *Fixture) void {
        @memset(&self.bytes, '!');
        @memset(&self.request.header_names, "poison");
        @memset(&self.request.header_values, "poison");
        @memset(&self.request.route_param_names, "poison");
        @memset(&self.request.route_param_values, "poison");
        @memset(&self.header_names, "poison");
        @memset(&self.header_values, "poison");
        @memset(&self.param_names, "poison");
        @memset(&self.param_values, "poison");
        self.request.body = "future payload after clone";
    }
};

fn check_metadata(view: uz.StreamingRequest) !void {
    try std.testing.expectEqualStrings("POST", view.method);
    try std.testing.expectEqualStrings("/upload?q=ok", view.target);
    try std.testing.expectEqualStrings("/upload", view.path);
    try std.testing.expectEqualStrings("webtransport", view.protocol);
    try std.testing.expectEqualStrings("q=ok", view.query);
    try std.testing.expectEqualStrings("application/octet-stream", view.headers.get("CONTENT-TYPE").?);
    try std.testing.expect(view.headers.has("x-extra"));
    try std.testing.expectEqualStrings("first", view.headers.get("x-dup").?);
    var entries = view.headers.entries();
    var count: usize = 0;
    while (entries.next()) |entry| : (count += 1) {
        switch (count) {
            0 => try std.testing.expectEqualStrings("Content-Type", entry.name),
            63 => {
                try std.testing.expectEqualStrings("x-dup", entry.name);
                try std.testing.expectEqualStrings("first", entry.value);
            },
            64 => {
                try std.testing.expectEqualStrings("x-extra", entry.name);
                try std.testing.expectEqualStrings("extra-value", entry.value);
            },
            65 => {
                try std.testing.expectEqualStrings("X-Dup", entry.name);
                try std.testing.expectEqualStrings("second", entry.value);
            },
            else => {
                try std.testing.expectEqualStrings("x-inline", entry.name);
                try std.testing.expectEqualStrings("inline-value", entry.value);
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 66), count);
    try std.testing.expectEqualStrings("42", view.params.get("Id").?);
    try std.testing.expect(view.params.get("id") == null);
    try std.testing.expectEqualStrings("inline-capture", view.params.get("segment").?);
    try std.testing.expectEqualStrings("rest/of/path", view.params.get("Tail").?);
    try std.testing.expect(view.params.get("tail") == null);
    try std.testing.expectEqualStrings("overflow", view.params.get("extra").?);
    var param_index: usize = 0;
    for (view.params.names, view.params.values) |name, value| {
        try check_param(param_index, name, value);
        param_index += 1;
    }
    for (view.params.extra_names, view.params.extra_values) |name, value| {
        try check_param(param_index, name, value);
        param_index += 1;
    }
    try std.testing.expectEqual(@as(usize, 18), param_index);
    const query = try view.query_params_of(1);
    try std.testing.expectEqualStrings("ok", query.get("q").?);
    try std.testing.expectError(error.BodyNotBuffered, view.form());
}

fn check_param(index: usize, name: []const u8, value: []const u8) !void {
    const expected_name = switch (index) {
        0 => "Id",
        16 => "Tail",
        17 => "extra",
        else => "segment",
    };
    const expected_value = switch (index) {
        0 => "42",
        16 => "rest/of/path",
        17 => "overflow",
        else => "inline-capture",
    };
    try std.testing.expectEqualStrings(expected_name, name);
    try std.testing.expectEqualStrings(expected_value, value);
}

test "streaming request: projection borrows all bounded metadata without copying arrays" {
    var fixture = Fixture{};
    try fixture.init();
    const view = uz.StreamingRequest.from_request(&fixture.request);
    try check_metadata(view);
    try std.testing.expectEqual(fixture.request.method.ptr, view.method.ptr);
    try std.testing.expect(@intFromPtr(&fixture.request.header_names[0]) == @intFromPtr(view.headers.names.ptr));
    try std.testing.expect(@intFromPtr(&fixture.header_names[0]) == @intFromPtr(view.headers.extra_names.ptr));
    try std.testing.expect(@intFromPtr(&fixture.request.route_param_names[0]) == @intFromPtr(view.params.names.ptr));
    try std.testing.expect(@intFromPtr(&fixture.param_names[0]) == @intFromPtr(view.params.extra_names.ptr));
}

test "streaming request: capture views and projection clamp malformed extra capacities" {
    var names = [_][]const u8{ "Id", "missing-value" };
    var values = [_][]const u8{"42"};
    const params = uz.RouteParamsView{ .names = &names, .values = &values, .extra_names = &names, .extra_values = &.{} };
    try std.testing.expectEqualStrings("42", params.get("Id").?);
    try std.testing.expect(params.get("missing-value") == null);
    var request = uz.Request{
        .header_count = std.math.maxInt(usize),
        .route_param_count = std.math.maxInt(usize),
        .extra_header_names = &names,
        .extra_header_values = &values,
        .extra_header_count = std.math.maxInt(usize),
        .extra_param_names = &names,
        .extra_param_values = &values,
        .extra_param_count = std.math.maxInt(usize),
    };
    @memset(&request.header_names, "h");
    @memset(&request.header_values, "v");
    @memset(&request.route_param_names, "p");
    @memset(&request.route_param_values, "v");
    const view = uz.StreamingRequest.from_request(&request);
    try std.testing.expectEqual(@as(usize, 64), view.headers.names.len);
    try std.testing.expectEqual(@as(usize, 1), view.headers.extra_names.len);
    try std.testing.expectEqual(@as(usize, 16), view.params.names.len);
    try std.testing.expectEqual(@as(usize, 1), view.params.extra_names.len);
}

fn moved_snapshot(allocator: std.mem.Allocator) !uz.OwnedStreamingRequest {
    var source = Fixture{};
    try source.init();
    const snapshot = try uz.StreamingRequest.from_request(&source.request).clone(allocator);
    source.poison();
    return snapshot;
}

fn check_owned(allocator: std.mem.Allocator) !void {
    var owned = try moved_snapshot(allocator);
    defer owned.deinit();
    const view = owned.view();
    try check_metadata(view);
    try std.testing.expectEqual(owned.header_names.ptr, view.headers.names.ptr);
    try std.testing.expectEqual(owned.header_values.ptr, view.headers.values.ptr);
    try std.testing.expectEqual(owned.param_names.ptr, view.params.names.ptr);
    try std.testing.expectEqual(owned.param_values.ptr, view.params.values.ptr);
    for ([_][]const u8{ view.method, view.target, view.path, view.protocol, view.query }) |slice| {
        try std.testing.expect(@intFromPtr(slice.ptr) >= @intFromPtr(owned.storage.ptr));
        try std.testing.expect(@intFromPtr(slice.ptr) + slice.len <= @intFromPtr(owned.storage.ptr) + owned.storage.len);
    }
    try std.testing.expectEqualStrings("", view.text());
    try std.testing.expectEqualStrings("", view.bytes());
}

test "streaming request: returned moved snapshot owns bytes and arrays after source poisoning" {
    try check_owned(std.testing.allocator);
}

test "streaming request: snapshot cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_owned, .{});
}

test "streaming request: snapshot rejects size overflow before allocation or reading" {
    var byte: u8 = 'x';
    const huge = @as([*]const u8, @ptrCast(&byte))[0..std.math.maxInt(usize)];
    var source = uz.Request{ .method = huge, .target = "x" };
    const view = uz.StreamingRequest.from_request(&source);
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.StreamingRequestSnapshotTooLarge, view.clone(allocator.allocator()));
    try std.testing.expectEqual(@as(usize, 0), allocator.end_index);
}

fn assert_open_body_error(comptime Return: type) void {
    const Errors = @typeInfo(Return).error_union.error_set;
    const candidate: Errors = error.BodyNotComplete;
    if (!std.mem.eql(u8, @errorName(candidate), "BodyNotComplete")) @compileError("unexpected response error tag");
}

test "streaming request: baseline response error memberships stay compatible" {
    const response: *uz.Response = undefined;
    comptime {
        assert_open_body_error(@TypeOf(response.begin_chunked("", "")));
        assert_open_body_error(@TypeOf(response.begin_stream("", "", undefined, undefined)));
        assert_open_body_error(@TypeOf(response.stream_file("", "", undefined)));
        assert_open_body_error(@TypeOf(response.begin_json()));
        assert_open_body_error(@TypeOf(response.sse()));
    }
    const FileErrors = @typeInfo(@TypeOf(response.send_file("", "", undefined, 0, 0))).error_union.error_set;
    const allowed: FileErrors = error.BodyNotAllowed;
    try std.testing.expectEqualStrings("BodyNotAllowed", @errorName(allowed));
    const members = @typeInfo(FileErrors).error_set.?;
    try std.testing.expectEqual(@as(usize, 11), members.len);
    for (members) |member| try std.testing.expect(!std.mem.eql(u8, member.name, "BodyNotComplete"));
}
