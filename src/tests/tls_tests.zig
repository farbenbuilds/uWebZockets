const std = @import("std");
const c = @import("c");
const support = @import("test_support");

const tls = support.tls;

/// One SSL endpoint plus the memory BIOs that carry its handshake records.
/// The SSL owns the BIOs after `SSL_set_bio`; this struct holds aliases.
const MemorySsl = struct {
    ssl: *c.SSL,
    incoming: *c.BIO,
    outgoing: *c.BIO,
};

test "ephemeral tls context initializes and releases" {
    var context = try tls.TlsContext.init_ephemeral(.{});
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "ephemeral http3 context initializes and releases" {
    var context = try tls.TlsContext.init_http3_ephemeral(.{});
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "ephemeral certificate completes an in-memory handshake" {
    var server_context = try tls.TlsContext.init_ephemeral(.{});
    defer server_context.deinit();

    const client_context = c.SSL_CTX_new(c.TLS_method()) orelse return error.ClientContextCreationFailed;
    defer c.SSL_CTX_free(client_context);
    // The generated certificate is self-signed, so there is no chain to trust;
    // the assertions below check the certificate content directly.
    c.SSL_CTX_set_verify(client_context, c.SSL_VERIFY_NONE, null);

    const server = try create_memory_ssl(server_context.ctx);
    defer c.SSL_free(server.ssl);
    c.SSL_set_accept_state(server.ssl);

    const client = try create_memory_ssl(client_context);
    defer c.SSL_free(client.ssl);
    c.SSL_set_connect_state(client.ssl);
    if (c.SSL_set_alpn_protos(client.ssl, "\x02h2", 3) != 0) {
        return error.ClientAlpnConfigurationFailed;
    }

    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        try drive_handshake(server.ssl, server.outgoing, client.incoming);
        try drive_handshake(client.ssl, client.outgoing, server.incoming);
        if (c.SSL_is_init_finished(server.ssl) == 1 and c.SSL_is_init_finished(client.ssl) == 1) break;
    }

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_init_finished(server.ssl));
    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_init_finished(client.ssl));
    try std.testing.expectEqual(tls.ApplicationProtocol.http2, tls.negotiated_protocol(server.ssl));

    const certificate = c.SSL_get_peer_certificate(client.ssl) orelse {
        return error.MissingPeerCertificate;
    };
    defer c.X509_free(certificate);

    try std.testing.expect(c.X509_get0_notBefore(certificate) != null);
    try std.testing.expect(c.X509_get0_notAfter(certificate) != null);
    try expect_host_match(certificate, "localhost", 1);
    try expect_host_match(certificate, "example.test", 0);
    try expect_ip_match(certificate, "127.0.0.1", 1);
    try expect_ip_match(certificate, "::1", 1);
}

test "ephemeral certificate embeds caller names" {
    var context = try tls.TlsContext.init_ephemeral(.{
        .common_name = "api.example.test",
        .dns_names = &.{ "api.example.test", "localhost" },
        .ip_addresses = &.{"10.0.0.1"},
    });
    defer context.deinit();

    const certificate = c.SSL_CTX_get0_certificate(context.ctx) orelse {
        return error.MissingCertificate;
    };
    try expect_host_match(certificate, "api.example.test", 1);
    try expect_host_match(certificate, "localhost", 1);
    try expect_host_match(certificate, "other.example.test", 0);
    try expect_ip_match(certificate, "10.0.0.1", 1);
    try expect_ip_match(certificate, "127.0.0.1", 0);
}

fn expect_host_match(certificate: *c.X509, name: [*:0]const u8, expected: c_int) !void {
    try std.testing.expectEqual(
        expected,
        c.X509_check_host(
            certificate,
            name,
            std.mem.len(name),
            c.X509_CHECK_FLAG_NEVER_CHECK_SUBJECT,
            null,
        ),
    );
}

fn expect_ip_match(certificate: *c.X509, address: [*:0]const u8, expected: c_int) !void {
    try std.testing.expectEqual(
        expected,
        c.X509_check_ip_asc(certificate, address, 0),
    );
}

fn create_memory_ssl(ctx: *c.SSL_CTX) !MemorySsl {
    const ssl = c.SSL_new(ctx) orelse return error.SslCreationFailed;
    errdefer c.SSL_free(ssl);

    const incoming = c.BIO_new(c.BIO_s_mem()) orelse return error.BioCreationFailed;
    errdefer _ = c.BIO_free(incoming);

    const outgoing = c.BIO_new(c.BIO_s_mem()) orelse return error.BioCreationFailed;
    errdefer _ = c.BIO_free(outgoing);

    c.SSL_set_bio(ssl, incoming, outgoing);
    return .{ .ssl = ssl, .incoming = incoming, .outgoing = outgoing };
}

fn drive_handshake(ssl: *c.SSL, outgoing: *c.BIO, incoming: *c.BIO) !void {
    const result = c.SSL_do_handshake(ssl);
    switch (c.SSL_get_error(ssl, result)) {
        c.SSL_ERROR_NONE, c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {},
        else => return error.HandshakeFailed,
    }
    try transfer_pending_bytes(outgoing, incoming);
}

fn transfer_pending_bytes(source: *c.BIO, destination: *c.BIO) !void {
    var buffer: [4096]u8 = undefined;
    while (c.BIO_ctrl_pending(source) > 0) {
        const read = c.BIO_read(source, &buffer, buffer.len);
        if (read <= 0) return error.HandshakeIoFailed;
        if (c.BIO_write(destination, &buffer, read) != read) return error.HandshakeIoFailed;
    }
}
