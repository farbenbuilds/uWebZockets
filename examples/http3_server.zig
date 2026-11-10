const std = @import("std");
const uz = @import("uWebZockets");

fn index(_: *uz.Request, response: *uz.Response) void {
    response.end_with_headers(
        "200 OK",
        "Content-Type: text/plain\r\n",
        "Hello from bounded HTTP/3",
    ) catch |err| std.log.err("response failed: {}", .{err});
}

/// Counts a live HTTP/3 upload without retaining body bytes.
const Upload = struct {
    bytes: u64 = 0,

    fn begin(context: *anyopaque, request: *const uz.StreamingRequest, _: uz.BodyControl) !uz.BodyBinding {
        const self: *Upload = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.method, "POST")) return error.UnexpectedMethod;
        if (!std.mem.eql(u8, request.path, "/upload")) return error.UnexpectedPath;
        self.bytes = 0;
        return .{ .context = self, .readiness = .ready };
    }

    fn chunk(context: *anyopaque, input: []const u8) !uz.BodyProgress {
        const self: *Upload = @ptrCast(@alignCast(context));
        self.bytes += input.len;
        return .{ .consumed = input.len, .readiness = .ready };
    }

    fn end(context: *anyopaque, _: *const uz.StreamingRequest, response: *uz.Response) !void {
        const self: *Upload = @ptrCast(@alignCast(context));
        var buffer: [32]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer, "{d}", .{self.bytes});
        try response.end("200 OK", body);
    }

    fn cancel(_: *anyopaque, _: uz.BodyCancelReason) void {}
};

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init_http3_ephemeral(init.io);
    defer server.deinit();

    _ = try server.get("/", index);
    var upload = Upload{};
    var upload_route = uz.BodyRoute{
        .sink = .{
            .context = &upload,
            .begin = Upload.begin,
            .chunk = Upload.chunk,
            .end = Upload.end,
            .cancel = Upload.cancel,
        },
        .limits = .{ .max_body_bytes = 128 * 1024 * 1024, .max_active = 1 },
        .middleware_policy = .headers_only,
    };
    _ = try server.post_stream("/upload", &upload_route);
    try server.listen_udp("0.0.0.0", 8443);
    // SIGINT/SIGTERM must reach the normal drain path so `deinit` can assert
    // that every engine pool was returned.
    try server.catch_shutdown_signals();
    try server.run();
}
