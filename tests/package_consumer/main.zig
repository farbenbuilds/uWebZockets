//! Compiles the README Quick Start snippet against the package module surface.
//!
//! `zig build check` proves a downstream consumer can fetch the package,
//! import `uWebZockets`, and build a real `App` with a route, listener, and
//! run call.

const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.end_with_headers_best_effort("200 OK", "Content-Type: text/plain; charset=utf-8\r\n", "hello from a dependency");
}

/// Compiles the documented cluster lifecycle without starting a server.
fn cluster_surface(init: std.process.Init, allocator: std.mem.Allocator) !void {
    try request_body_surface(allocator);
    try streaming_route_surface(init);
    const options: uz.ClusterOptions = .{};
    var group = try uz.Server.builder(init.io)
        .with_max_clients(8)
        .build_cluster(allocator, 4, options);
    defer group.deinit();

    const Group = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Group.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
            _ = try worker.trace("/probe", hello);
        }
    }.routes);
    try group.configure(struct {
        fn narrow_routes(_: *Group.Worker, _: usize) error{OutOfMemory}!void {}
    }.narrow_routes);

    const state: uz.ClusterState = group.state();
    const phases = [_]uz.FailurePhase{ .spawn, .run, .cleanup };
    _ = state;
    _ = phases;
    _ = group.worker_count();
    _ = group.worker_capacity();
    _ = group.first_failure();
    _ = group.failure_count();
    _ = group.worker(0);
    _ = group.threads;
    _ = group.active_workers;
    _ = group.thread_count;
    _ = group.worker_failed;
    _ = group.deinitialized;
    _ = try group.publish("topic", "payload", true);
    const report: uz.PublishReport = try group.publish_report("topic", "payload", true);
    _ = report.attempted();
    _ = report.all_delivered();

    const run_fn: *const fn (*Group) uz.cluster.RunError!void = &Group.run;
    _ = run_fn;
    const file_fn: *const fn (*uz.Response, []const u8, []const u8, uz.FileSource) anyerror!void = &uz.Response.stream_file;
    _ = file_fn;
    const encoding_fn: *const fn (uz.fetch.HeadersView, uz.negotiate.EncodingAvailability) ?uz.negotiate.Encoding = &uz.negotiate.select_encoding_headers;
    _ = encoding_fn;

    try group.enable_https_ephemeral();
    try group.listen("127.0.0.1", 0);
    try group.catch_shutdown_signals();
    try group.deinit_checked();
}

const LegacyFormError = error{
    MissingContentType,
    TooManyQueryParameters,
    QueryComponentTooLong,
    UnsupportedMediaType,
};

fn narrow_legacy_form(request: *const uz.Request) LegacyFormError!uz.query.QueryParams {
    return try request.form();
}

fn exhaustive_legacy_form(request: *const uz.Request) ?uz.query.QueryParams {
    return request.form() catch |err| switch (err) {
        error.MissingContentType => null,
        error.TooManyQueryParameters => null,
        error.QueryComponentTooLong => null,
        error.UnsupportedMediaType => null,
    };
}

/// Compiles new sink metadata and unchanged legacy helpers without a live route.
fn request_body_surface(allocator: std.mem.Allocator) !void {
    try multipart_surface();
    try multipart_sink_surface();
    const begin: uz.BodyBeginFn = body_begin;
    const chunk: uz.BodyChunkFn = body_chunk;
    const end: uz.BodyEndFn = body_end;
    const cancel: uz.BodyCancelFn = body_cancel;
    var context: u8 = 0;
    const route = uz.BodyRoute{
        .sink = uz.BodySink{ .context = &context, .begin = begin, .chunk = chunk, .end = end, .cancel = cancel },
        .limits = uz.BodyLimits{ .max_body_bytes = 100_000_000, .max_active = 1 },
    };
    const policy: uz.BodyMiddlewarePolicy = route.middleware_policy;
    const resume_fn: *const fn (uz.BodyControl) uz.BodyControlError!void = &uz.BodyControl.@"resume";
    const cancel_fn: *const fn (uz.BodyControl) uz.BodyControlError!void = &uz.BodyControl.cancel;
    _ = policy;
    _ = resume_fn;
    _ = cancel_fn;
    var request = uz.Request{ .body = "name=buffered" };
    try request.add_header("Content-Type", "application/x-www-form-urlencoded");
    const form = try narrow_legacy_form(&request);
    if (!std.mem.eql(u8, form.get("name").?, "buffered")) return error.UnexpectedForm;
    if (exhaustive_legacy_form(&request) == null) return error.UnexpectedForm;
    const streaming = uz.StreamingRequest.from_request(&request);
    const params: uz.RouteParamsView = streaming.params;
    _ = params;
    var owned: uz.OwnedStreamingRequest = try streaming.clone(allocator);
    defer owned.deinit();
    const snapshot = owned.view();
    const result: uz.BodyReadError!uz.query.QueryParams = snapshot.form();
    if (result) |_| return error.UnexpectedBufferedBody else |err| switch (err) {
        error.BodyNotBuffered => {},
    }
}

const LegacyMultipartError = error{
    MissingContentType,
    NotMultipartFormData,
    MissingMultipartBoundary,
    InvalidMultipartBoundary,
};

fn narrow_legacy_multipart(request: *const uz.Request) LegacyMultipartError!uz.multipart.Parser {
    return try request.multipart();
}

fn exhaustive_legacy_multipart(request: *const uz.Request) ?uz.multipart.Parser {
    return request.multipart() catch |err| switch (err) {
        error.MissingContentType => null,
        error.NotMultipartFormData => null,
        error.MissingMultipartBoundary => null,
        error.InvalidMultipartBoundary => null,
    };
}

/// Exercises incremental events through the supported package namespace.
fn multipart_surface() !void {
    const entity = "--a\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ny\r\n--a--";
    var request = uz.Request{ .body = entity };
    try request.add_header("Content-Type", "multipart/form-data; boundary=a");
    var buffered = try narrow_legacy_multipart(&request);
    const part = (try buffered.next_part()) orelse return error.MissingPart;
    if (!std.mem.eql(u8, part.data, "y")) return error.UnexpectedPart;
    if (exhaustive_legacy_multipart(&request) == null) return error.MissingPart;

    var headers: [64]u8 = undefined;
    var carry: [5]u8 = undefined;
    const limits = uz.multipart.StreamingLimits{
        .max_body_bytes = entity.len,
        .max_parts = 1,
        .max_part_headers = 1,
    };
    const storage = uz.multipart.StreamingStorage{ .headers = &headers, .carry = &carry };
    var parser = try uz.multipart.StreamingParser.init("a", limits, storage);
    var offset: usize = 0;
    var data_bytes: usize = 0;
    while (offset < entity.len) {
        const step: uz.multipart.StreamingStep = try parser.next(entity[offset..]);
        offset += step.consumed;
        const event: uz.multipart.StreamingEvent = step.event orelse continue;
        switch (event) {
            .part_begin => |metadata| {
                const view: uz.multipart.PartMeta = metadata;
                if (!std.mem.eql(u8, view.name, "x")) return error.UnexpectedPart;
            },
            .part_data => |data| {
                if (!std.mem.eql(u8, data, "y")) return error.UnexpectedPart;
                data_bytes += data.len;
                offset += try parser.accept_data(data.len);
            },
            .part_end => {},
        }
    }
    try parser.finish();
    if (data_bytes != 1) return error.UnexpectedPart;
}

const MultipartConsumerState = struct {
    parts: usize = 0,
    data_bytes: usize = 0,
    cancellations: usize = 0,
};

fn multipart_sink_surface() !void {
    const entity = "--a\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ny\r\n--a--";
    var headers: [64]u8 = undefined;
    var carry: [5]u8 = undefined;
    var state: MultipartConsumerState = .{};
    const begin: uz.multipart.PartBeginFn = part_begin;
    const write: uz.multipart.PartWriteFn = part_write;
    const end: uz.multipart.PartEndFn = part_end;
    const cancel: uz.multipart.PartCancelFn = part_cancel;
    const sink = uz.multipart.PartSink{
        .context = &state,
        .begin_part = begin,
        .write_chunk = write,
        .end_part = end,
        .cancel_part = cancel,
    };
    var adapter = uz.multipart.MultipartSink{
        .parser = try uz.multipart.StreamingParser.init("a", .{
            .max_body_bytes = entity.len,
            .max_parts = 1,
            .max_part_headers = 1,
        }, .{ .headers = &headers, .carry = &carry }),
        .sink = sink,
    };
    const progress: uz.BodyProgress = try adapter.consume(entity);
    if (progress.consumed != entity.len or progress.readiness != .ready) return error.UnexpectedProgress;
    try adapter.finish();
    adapter.cancel(.sink_failure);
    if (state.parts != 1 or state.data_bytes != 1 or state.cancellations != 0) return error.UnexpectedPart;
}

fn part_begin(_: *anyopaque, metadata: uz.multipart.PartMeta) !uz.BodyReadiness {
    if (!std.mem.eql(u8, metadata.name, "x")) return error.UnexpectedPart;
    return .ready;
}

fn part_write(context: *anyopaque, input: []const u8) !uz.BodyProgress {
    const state: *MultipartConsumerState = @ptrCast(@alignCast(context));
    state.data_bytes += input.len;
    return .{ .consumed = input.len, .readiness = .ready };
}

fn part_end(context: *anyopaque) !uz.BodyReadiness {
    const state: *MultipartConsumerState = @ptrCast(@alignCast(context));
    state.parts += 1;
    return .ready;
}

fn part_cancel(context: *anyopaque, _: uz.BodyCancelReason) void {
    const state: *MultipartConsumerState = @ptrCast(@alignCast(context));
    state.cancellations += 1;
}

fn body_begin(context: *anyopaque, _: *const uz.StreamingRequest, _: uz.BodyControl) !uz.BodyBinding {
    return .{ .context = context, .readiness = uz.BodyReadiness.ready };
}

fn body_chunk(_: *anyopaque, input: []const u8) !uz.BodyProgress {
    return .{ .consumed = input.len, .readiness = .ready };
}

fn body_end(_: *anyopaque, _: *const uz.StreamingRequest, response: *uz.Response) !void {
    try response.end("204 No Content", "");
}

fn body_cancel(_: *anyopaque, reason: uz.BodyCancelReason) void {
    _ = reason;
}

fn streaming_route_surface(init: std.process.Init) !void {
    var app = try uz.Server.builder(init.io)
        .with_max_clients(1)
        .build(std.heap.page_allocator);
    defer app.deinit();
    var context: u8 = 0;
    const route = uz.BodyRoute{
        .sink = uz.BodySink{
            .context = &context,
            .begin = body_begin,
            .chunk = body_chunk,
            .end = body_end,
            .cancel = body_cancel,
        },
        .limits = uz.BodyLimits{ .max_body_bytes = 1024 * 1024, .max_active = 1 },
        .middleware_policy = .headers_only,
    };
    _ = try app.post_stream("/upload", &route);
    _ = try app.put_stream("/upload", &route);
    _ = try app.patch_stream("/upload", &route);
}

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("UWZ_PACKAGE_CONSUMER_CLUSTER") != null) {
        try cluster_surface(init, std.heap.page_allocator);
    }

    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.get("/", hello);
    try app.listen("0.0.0.0", 3000);
    try app.run();
}
