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

test "required client authentication completes with a certificate from the configured ca" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("mtls test ca", 1);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 2, .server);
    defer free_test_credential(server_credential);
    const client_credential = try create_test_leaf_credential(authority, "client.test", 3, .client);
    defer free_test_credential(client_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(client_credential);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.server);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.client);
    try std.testing.expectEqual(@as(c_long, c.X509_V_OK), c.SSL_get_verify_result(pair.server.ssl));
}

test "required client authentication rejects an anonymous client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("anonymous test ca", 10);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 11, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(null);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.failed, outcome.server);
    try std.testing.expect(c.SSL_get_verify_result(pair.server.ssl) != @as(c_long, c.X509_V_OK));
}

test "optional client authentication completes without a client certificate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("optional test ca", 20);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 21, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .optional,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(null);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.server);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.client);
}

test "required client authentication rejects a certificate from another ca" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("trusted test ca", 30);
    defer free_test_authority(authority);
    const unrelated_authority = try create_test_authority("unrelated test ca", 40);
    defer free_test_authority(unrelated_authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 31, .server);
    defer free_test_credential(server_credential);
    const client_credential = try create_test_leaf_credential(unrelated_authority, "client.test", 41, .client);
    defer free_test_credential(client_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(client_credential);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.failed, outcome.server);
}

test "none mode ignores the trust store path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("none mode test ca", 50);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 51, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .none,
    });
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "client auth configuration errors fail before a context is returned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("misconfigured test ca", 60);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 61, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    try std.testing.expectError(error.InvalidClientAuthConfig, tls.TlsContext.init_mtls(
        paths.server_certificate,
        paths.server_key,
        .{ .mode = .required },
    ));
    const missing_ca: [:0]const u8 = "/nonexistent-uwebzockets-mtls-ca.pem";
    try std.testing.expectError(error.TrustStoreLoadFailed, tls.TlsContext.init_mtls(
        paths.server_certificate,
        paths.server_key,
        .{ .mode = .optional, .ca_path = missing_ca },
    ));
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

/// Both endpoints of one memory-BIO handshake.
const MemoryPair = struct {
    server: MemorySsl,
    client: MemorySsl,
};

/// Creates accepting and connecting endpoints with the given contexts.
fn create_memory_pair(server_ctx: *c.SSL_CTX, client_ctx: *c.SSL_CTX) !MemoryPair {
    const server = try create_memory_ssl(server_ctx);
    errdefer c.SSL_free(server.ssl);
    c.SSL_set_accept_state(server.ssl);

    const client = try create_memory_ssl(client_ctx);
    errdefer c.SSL_free(client.ssl);
    c.SSL_set_connect_state(client.ssl);
    return .{ .server = server, .client = client };
}

/// Releases both endpoints; each SSL owns its BIOs after `SSL_set_bio`.
fn free_memory_pair(pair: MemoryPair) void {
    c.SSL_free(pair.server.ssl);
    c.SSL_free(pair.client.ssl);
}

/// Terminal state of one handshake step.
const HandshakeOutcome = enum {
    /// The endpoint needs more records before it can finish.
    pending,
    /// The handshake finished (`SSL_is_init_finished`).
    complete,
    /// `SSL_do_handshake` reported a fatal error.
    failed,
};

/// Terminal states observed from both ends of one handshake.
const HandshakePairOutcome = struct {
    server: HandshakeOutcome,
    client: HandshakeOutcome,
};

fn drive_handshake(ssl: *c.SSL, outgoing: *c.BIO, incoming: *c.BIO) !void {
    if (try drive_handshake_step(ssl, outgoing, incoming) == .failed) {
        return error.HandshakeFailed;
    }
}

/// Drives one endpoint once and reports its terminal state.
fn drive_handshake_step(ssl: *c.SSL, outgoing: *c.BIO, incoming: *c.BIO) !HandshakeOutcome {
    const result = c.SSL_do_handshake(ssl);
    const outcome: HandshakeOutcome = switch (c.SSL_get_error(ssl, result)) {
        c.SSL_ERROR_NONE => if (c.SSL_is_init_finished(ssl) == 1) .complete else .pending,
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => .pending,
        else => .failed,
    };
    try transfer_pending_bytes(outgoing, incoming);
    return outcome;
}

/// Drives both endpoints until each reaches a terminal state. A failed or
/// finished endpoint is not driven again, and the round bound keeps a stalled
/// peer from spinning forever.
fn drive_handshake_pair(pair: MemoryPair) !HandshakePairOutcome {
    var outcome = HandshakePairOutcome{ .server = .pending, .client = .pending };
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        if (outcome.server != .pending and outcome.client != .pending) break;
        if (outcome.server == .pending) {
            // Server records flow to the client's incoming BIO, and the other
            // way around; each endpoint only ever writes to its own outgoing.
            outcome.server = try drive_handshake_step(
                pair.server.ssl,
                pair.server.outgoing,
                pair.client.incoming,
            );
        }
        if (outcome.client == .pending) {
            outcome.client = try drive_handshake_step(
                pair.client.ssl,
                pair.client.outgoing,
                pair.server.incoming,
            );
        }
    }
    return outcome;
}

fn transfer_pending_bytes(source: *c.BIO, destination: *c.BIO) !void {
    var buffer: [4096]u8 = undefined;
    while (c.BIO_ctrl_pending(source) > 0) {
        const read = c.BIO_read(source, &buffer, buffer.len);
        if (read <= 0) return error.HandshakeIoFailed;
        if (c.BIO_write(destination, &buffer, read) != read) return error.HandshakeIoFailed;
    }
}

/// One generated test key pair and its X.509 certificate.
const TestCredential = struct {
    key: *c.EVP_PKEY,
    certificate: *c.X509,
};

/// A generated test CA: signing key plus self-signed CA certificate.
const TestAuthority = struct {
    key: *c.EVP_PKEY,
    certificate: *c.X509,
};

/// Extended key usage installed on a generated test leaf certificate.
const TestLeafUsage = enum {
    /// `serverAuth`, for the certificate the test server presents.
    server,
    /// `clientAuth`, for the certificate the test client presents.
    client,
};

/// NUL-terminated filesystem paths for one test's credentials.
const TestPaths = struct {
    ca: [:0]u8,
    server_certificate: [:0]u8,
    server_key: [:0]u8,

    fn deinit(self: TestPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.ca);
        allocator.free(self.server_certificate);
        allocator.free(self.server_key);
    }
};

/// Builds absolute paths inside the tmpDir made by `std.testing.tmpDir`, which
/// creates its random directory at `.zig-cache/tmp/<sub_path>` relative to the
/// process working directory.
fn make_test_paths(allocator: std.mem.Allocator, sub_path: []const u8) !TestPaths {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    const ca = try std.fs.path.joinZ(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, "ca.pem" });
    errdefer allocator.free(ca);
    const server_certificate = try std.fs.path.joinZ(
        allocator,
        &.{ cwd, ".zig-cache", "tmp", sub_path, "server.pem" },
    );
    errdefer allocator.free(server_certificate);
    return .{
        .ca = ca,
        .server_certificate = server_certificate,
        .server_key = try std.fs.path.joinZ(
            allocator,
            &.{ cwd, ".zig-cache", "tmp", sub_path, "server-key.pem" },
        ),
    };
}

/// Writes the CA bundle and server certificate/key PEM files consumed by
/// `TlsContext.init_mtls`.
fn write_server_credentials(dir: std.Io.Dir, authority: *c.X509, credential: TestCredential) !void {
    try write_certificate_pem(dir, "ca.pem", authority);
    try write_certificate_pem(dir, "server.pem", credential.certificate);
    try write_private_key_pem(dir, "server-key.pem", credential.key);
}

/// Writes one certificate to `sub_path` in the temporary test directory.
fn write_certificate_pem(dir: std.Io.Dir, sub_path: []const u8, certificate: *c.X509) !void {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.PemSerializationFailed;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_X509(bio, certificate) != 1) return error.PemSerializationFailed;
    try write_pem_bio(dir, sub_path, bio);
}

/// Writes one unencrypted PKCS#8 private key to `sub_path`.
fn write_private_key_pem(dir: std.Io.Dir, sub_path: []const u8, key: *c.EVP_PKEY) !void {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.PemSerializationFailed;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_PrivateKey(bio, key, null, null, 0, null, null) != 1) {
        return error.PemSerializationFailed;
    }
    try write_pem_bio(dir, sub_path, bio);
}

/// Copies a memory BIO holding one PEM block to a file.
fn write_pem_bio(dir: std.Io.Dir, sub_path: []const u8, bio: *c.BIO) !void {
    var buffer: [8192]u8 = undefined;
    const available = c.BIO_ctrl_pending(bio);
    if (available == 0 or available > buffer.len) return error.PemSerializationFailed;

    const length = c.BIO_read(bio, &buffer, buffer.len);
    if (length <= 0 or @as(usize, @intCast(length)) != available) {
        return error.PemSerializationFailed;
    }
    try dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = buffer[0..@intCast(length)],
    });
}

/// Creates a TLS client context. `credential` is null for an anonymous client
/// that answers the server's certificate request with an empty list.
fn new_client_context(credential: ?TestCredential) !*c.SSL_CTX {
    const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.ClientContextCreationFailed;
    errdefer c.SSL_CTX_free(ctx);

    // Server authenticity is not under test; client auth is one-directional.
    c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
    if (credential) |value| {
        if (c.SSL_CTX_use_certificate(ctx, value.certificate) != 1) {
            return error.ClientCertificateInstallFailed;
        }
        if (c.SSL_CTX_use_PrivateKey(ctx, value.key) != 1) {
            return error.ClientPrivateKeyInstallFailed;
        }
    }
    return ctx;
}

/// Generates a P-256 key pair for one test credential.
fn generate_test_key() !*c.EVP_PKEY {
    const keygen = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null) orelse {
        return error.TestKeyGenerationFailed;
    };
    defer c.EVP_PKEY_CTX_free(keygen);

    if (c.EVP_PKEY_keygen_init(keygen) != 1) return error.TestKeyGenerationFailed;
    if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(keygen, c.NID_X9_62_prime256v1) != 1) {
        return error.TestKeyGenerationFailed;
    }

    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(keygen, &key) != 1) return error.TestKeyGenerationFailed;
    return key orelse error.TestKeyGenerationFailed;
}

/// Creates a self-signed P-256 CA certificate suitable for signing leaves.
fn create_test_authority(common_name: []const u8, serial: c_long) !TestAuthority {
    const key = try generate_test_key();
    errdefer c.EVP_PKEY_free(key);

    const certificate = try open_test_certificate(key, serial, common_name);
    errdefer c.X509_free(certificate);

    try add_test_extension(certificate, c.NID_basic_constraints, "critical,CA:TRUE");
    try add_test_extension(certificate, c.NID_key_usage, "critical,keyCertSign,cRLSign");

    const subject = c.X509_get_subject_name(certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_set_issuer_name(certificate, subject) != 1) return error.TestCertificateCreationFailed;
    if (c.X509_sign(certificate, key, c.EVP_sha256()) == 0) return error.TestCertificateSigningFailed;
    return .{ .key = key, .certificate = certificate };
}

/// Creates a P-256 leaf certificate signed by `authority`.
fn create_test_leaf_credential(
    authority: TestAuthority,
    common_name: []const u8,
    serial: c_long,
    usage: TestLeafUsage,
) !TestCredential {
    const key = try generate_test_key();
    errdefer c.EVP_PKEY_free(key);

    const certificate = try open_test_certificate(key, serial, common_name);
    errdefer c.X509_free(certificate);

    try add_test_extension(certificate, c.NID_basic_constraints, "critical,CA:FALSE");
    try add_test_extension(certificate, c.NID_key_usage, "critical,digitalSignature");
    try add_test_extension(certificate, c.NID_ext_key_usage, switch (usage) {
        .server => "serverAuth",
        .client => "clientAuth",
    });

    const issuer = c.X509_get_subject_name(authority.certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_set_issuer_name(certificate, issuer) != 1) return error.TestCertificateCreationFailed;
    if (c.X509_sign(certificate, authority.key, c.EVP_sha256()) == 0) {
        return error.TestCertificateSigningFailed;
    }
    return .{ .key = key, .certificate = certificate };
}

/// Allocates an X.509v3 certificate with serial, validity window, subject
/// common name, and public key; the caller adds the issuer and extensions.
fn open_test_certificate(key: *c.EVP_PKEY, serial: c_long, common_name: []const u8) !*c.X509 {
    const certificate = c.X509_new() orelse return error.TestCertificateCreationFailed;
    errdefer c.X509_free(certificate);

    // Version 2 is X.509v3, the minimum version that carries extensions.
    if (c.X509_set_version(certificate, 2) != 1) return error.TestCertificateCreationFailed;
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(certificate), serial) != 1) {
        return error.TestCertificateCreationFailed;
    }
    // Backdate an hour for clock skew; expire after 90 days.
    if (c.X509_gmtime_adj(c.X509_getm_notBefore(certificate), -3600) == null) {
        return error.TestCertificateCreationFailed;
    }
    if (c.X509_gmtime_adj(c.X509_getm_notAfter(certificate), 90 * 24 * 3600) == null) {
        return error.TestCertificateCreationFailed;
    }

    const subject = c.X509_get_subject_name(certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_NAME_add_entry_by_txt(
        subject,
        "CN",
        c.MBSTRING_UTF8,
        common_name.ptr,
        @intCast(common_name.len),
        -1,
        0,
    ) != 1) {
        return error.TestCertificateCreationFailed;
    }
    if (c.X509_set_pubkey(certificate, key) != 1) return error.TestCertificateCreationFailed;
    return certificate;
}

fn add_test_extension(certificate: *c.X509, nid: c_int, value: [*:0]const u8) !void {
    const extension = c.X509V3_EXT_nconf_nid(null, null, nid, value) orelse {
        return error.TestCertificateExtensionFailed;
    };
    defer c.X509_EXTENSION_free(extension);
    if (c.X509_add_ext(certificate, extension, -1) != 1) {
        return error.TestCertificateExtensionFailed;
    }
}

fn free_test_credential(credential: TestCredential) void {
    c.X509_free(credential.certificate);
    c.EVP_PKEY_free(credential.key);
}

fn free_test_authority(authority: TestAuthority) void {
    c.X509_free(authority.certificate);
    c.EVP_PKEY_free(authority.key);
}
