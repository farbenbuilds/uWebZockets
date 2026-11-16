const std = @import("std");
const support = @import("test_support");
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const radix = support.radix;

fn complete(_: *Request, response: *Response) void {
    response.end_best_effort("200 OK", "");
}

fn complete_context(_: *anyopaque, _: *Request, response: *Response) void {
    response.end_best_effort("200 OK", "");
}

test "WebTransport admission requires explicit CONNECT instead of any fallback" {
    var storage = radix.DefaultBundle{};
    var router = try radix.Router.init(storage.storage());
    try router.any("/session", complete);
    var request = Request{ .method = "CONNECT", .path = "/session" };
    try std.testing.expect(router.match_request(&request, .connect).?.handler != null);
    try std.testing.expect(router.match_explicit_request(&request, .connect).?.handler == null);
    try router.route_context(.connect, "/session", &storage, complete_context);
    try std.testing.expect(router.match_explicit_request(&request, .connect).?.handler != null);
}

test "WebTransport admission explicit selection preserves captures and rejects HEAD fallback" {
    var storage = radix.DefaultBundle{};
    var router = try radix.Router.init(storage.storage());
    try router.get("/session/:room", complete);
    try router.route_context(.connect, "/session/:room", &storage, complete_context);
    var request = Request{ .method = "CONNECT", .path = "/session/room42" };
    try std.testing.expect(router.match_explicit_request(&request, .connect).?.handler != null);
    try std.testing.expectEqualStrings("room42", request.get_param("room").?);
    request.method = "HEAD";
    try std.testing.expect(router.match_request(&request, .head).?.handler != null);
    try std.testing.expect(router.match_explicit_request(&request, .head).?.handler == null);
    try std.testing.expectEqualStrings("room42", request.get_param("room").?);
    request.path = "/missing";
    try std.testing.expect(router.match_explicit_request(&request, .connect) == null);
    try std.testing.expectEqual(@as(usize, 0), request.route_param_count);
}

test "WebTransport admission preserves configured datagram storage when enabling HTTP3" {
    var app = try support.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_webtransport_datagrams(1200, 4)
        .build(std.testing.allocator);
    defer app.deinit();
    try app.enable_http3_ephemeral();
    try std.testing.expect(app.http3_enabled);
    try std.testing.expectEqual(@as(usize, 2), app.datagram_rings.len);
    try std.testing.expectEqual(@as(usize, 4), app.datagram_rings[0].capacity());
    try std.testing.expectEqual(@as(usize, 1200), app.datagram_rings[0].payload_stride);
    const tcp = app.tls_ctx.?.ctx;
    const quic = app.quic_tls_ctx.?.ctx;
    try std.testing.expect(tcp != quic);
    try std.testing.expectError(error.TlsAlreadyEnabled, app.enable_http3_ephemeral());
    try std.testing.expectEqual(tcp, app.tls_ctx.?.ctx);
    try std.testing.expectEqual(quic, app.quic_tls_ctx.?.ctx);
}

test "WebTransport admission TLS enable failure preserves retry and shutdown state" {
    var app = try support.Server.builder(std.testing.io).with_max_clients(2).build(std.testing.allocator);
    defer app.deinit();
    try std.testing.expectError(error.CertificateLoadFailed, app.enable_http3(
        "/nonexistent-uwz-certificate.pem",
        "/nonexistent-uwz-private-key.pem",
    ));
    try std.testing.expect(app.tls_ctx == null);
    try std.testing.expect(app.quic_tls_ctx == null);
    try std.testing.expect(!app.http3_enabled);
    try app.enable_http3_ephemeral();
    const quic = app.quic_tls_ctx.?.ctx;
    try app.shutdown();
    try std.testing.expectError(error.ApplicationUnavailable, app.enable_http3_ephemeral());
    try std.testing.expectEqual(quic, app.quic_tls_ctx.?.ctx);
}
