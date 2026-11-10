const std = @import("std");
const uz = @import("uWebZockets");

/// Selects one public listener configuration per owned process.
const Mode = enum { plain, tls, h3 };

fn parse_mode(value: []const u8) !Mode {
    if (std.mem.eql(u8, value, "plain")) return .plain;
    if (std.mem.eql(u8, value, "tls")) return .tls;
    if (std.mem.eql(u8, value, "h3")) return .h3;
    return error.InvalidMode;
}

fn health(_: *uz.Request, response: *uz.Response) void {
    response.text("ok") catch |err| {
        std.log.err("static interop health response failed: {}", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    const mode = try parse_mode(init.environ_map.get("STATIC_INTEROP_MODE") orelse return error.MissingMode);
    const root = init.environ_map.get("STATIC_INTEROP_ROOT") orelse return error.MissingRoot;
    const port = try std.fmt.parseInt(u16, init.environ_map.get("STATIC_INTEROP_PORT") orelse return error.MissingPort, 10);
    const allocator = init.arena.allocator();
    const cert = try allocator.dupeZ(u8, init.environ_map.get("STATIC_INTEROP_CERT") orelse "");
    const key = try allocator.dupeZ(u8, init.environ_map.get("STATIC_INTEROP_KEY") orelse "");

    {
        var server = switch (mode) {
            .plain => try uz.App(8).init(init.io),
            .tls => try uz.App(8).init_https(init.io, cert, key),
            .h3 => try uz.App(8).init_http3(init.io, cert, key),
        };
        defer server.deinit();

        _ = try server.get("/health", health);
        _ = try server.static("/files", root, .{ .precompressed = true });
        _ = try server.static("/identity", root, .{});
        switch (mode) {
            .plain, .tls => try server.listen("127.0.0.1", port),
            .h3 => try server.listen_udp("127.0.0.1", port),
        }
        try server.catch_shutdown_signals();
        try server.run();
        try server.shutdown();
    }
    std.log.info("static interop shutdown drained", .{});
}
