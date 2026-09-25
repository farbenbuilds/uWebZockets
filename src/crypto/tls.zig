const std = @import("std");
const c = @import("c");

/// BoringSSL ALPN selection callback signature shared by the TCP and QUIC contexts.
const AlpnCallback = *const fn (
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int;

/// Subject names embedded in a generated certificate.
pub const CertificateNames = struct {
    common_name: []const u8 = "localhost",
    dns_names: []const []const u8 = &.{"localhost"},
    ip_addresses: []const []const u8 = &.{ "127.0.0.1", "::1" },
};

/// Server-side client-certificate verification policy.
pub const ClientAuth = enum {
    /// Do not request or verify a client certificate.
    none,
    /// Request a certificate and verify it when the client presents one;
    /// anonymous clients still complete the handshake.
    optional,
    /// Request a certificate and fail the handshake when the client presents
    /// none, or one that does not verify against the configured trust store.
    required,
};

/// Client-certificate authentication policy for `TlsContext.init_mtls`.
pub const ClientAuthConfig = struct {
    /// Verification policy applied to the server context.
    mode: ClientAuth,
    /// PEM bundle of trusted CA certificates. Required unless `mode` is
    /// `.none`; the file is read once at context creation.
    ca_path: [:0]const u8 = "",
};

/// Owning BoringSSL server context with a fixed ALPN policy.
pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    /// Loads an HTTPS context advertising `h2` then `http/1.1`.
    ///
    /// TLS 1.3 0-RTT is enabled. Early data is replayable by a network
    /// attacker, so the HTTP dispatcher admits only safe methods before the
    /// handshake is confirmed (see `TcpConnection.early_data_forbids`).
    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        return init_with_alpn(cert_path, key_path, .{ .mode = .none }, select_http_alpn, true);
    }

    /// Loads an HTTPS context that authenticates clients with certificates.
    ///
    /// ALPN (`h2` then `http/1.1`) and the safe-method 0-RTT replay policy
    /// match `init`. `.none` skips the trust store entirely: BoringSSL's
    /// default `SSL_VERIFY_NONE` sends no CertificateRequest, so `ca_path` is
    /// never opened. Any other mode rejects an empty `ca_path` with
    /// `error.InvalidClientAuthConfig` and a bundle that cannot be read or
    /// parsed with `error.TrustStoreLoadFailed`.
    pub fn init_mtls(
        cert_path: [:0]const u8,
        key_path: [:0]const u8,
        config: ClientAuthConfig,
    ) !TlsContext {
        return init_with_alpn(cert_path, key_path, config, select_http_alpn, true);
    }

    /// Loads an HTTP/3-only context advertising `h3`.
    ///
    /// lsquic owns QUIC 0-RTT replay protection, so the engine keeps early
    /// data disabled until that policy is defined end to end.
    pub fn init_http3(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        return init_with_alpn(cert_path, key_path, .{ .mode = .none }, select_http3_alpn, false);
    }

    /// Generates a self-signed P-256 certificate and key in memory, then
    /// returns an HTTPS context advertising `h2` then `http/1.1`.
    ///
    /// BoringSSL allocates only while the credentials are generated here; the
    /// handshake, record, and I/O paths add no allocation. TLS 1.3 0-RTT is
    /// enabled with the safe-method replay policy of `init`.
    pub fn init_ephemeral(names: CertificateNames) !TlsContext {
        const ctx = try new_server_context(select_http_alpn, true);
        errdefer c.SSL_CTX_free(ctx);
        try install_ephemeral_credentials(ctx, names);
        return TlsContext{ .ctx = ctx };
    }

    /// Generates a self-signed P-256 certificate and key in memory, then
    /// returns an HTTP/3-only context advertising `h3`.
    ///
    /// BoringSSL allocates only while the credentials are generated here; the
    /// handshake, record, and I/O paths add no allocation. Early data stays
    /// disabled for the replay-protection reason documented on `init_http3`.
    pub fn init_http3_ephemeral(names: CertificateNames) !TlsContext {
        const ctx = try new_server_context(select_http3_alpn, false);
        errdefer c.SSL_CTX_free(ctx);
        try install_ephemeral_credentials(ctx, names);
        return TlsContext{ .ctx = ctx };
    }

    fn init_with_alpn(
        cert_path: [:0]const u8,
        key_path: [:0]const u8,
        client_auth: ClientAuthConfig,
        callback: AlpnCallback,
        early_data: bool,
    ) !TlsContext {
        const ctx = try new_server_context(callback, early_data);
        errdefer c.SSL_CTX_free(ctx);

        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path.ptr) != 1) {
            return error.CertificateLoadFailed;
        }
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
            return error.PrivateKeyLoadFailed;
        }
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            return error.KeyMismatch;
        }
        try apply_client_auth(ctx, client_auth);
        return TlsContext{ .ctx = ctx };
    }

    /// Releases the owned BoringSSL context.
    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

/// Creates a TLS 1.3-only server context with the given ALPN policy and
/// early-data setting.
fn new_server_context(callback: AlpnCallback, early_data: bool) !*c.SSL_CTX {
    c.CRYPTO_library_init();
    c.SSL_load_error_strings();

    const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse {
        return error.TlsContextCreationFailed;
    };
    errdefer c.SSL_CTX_free(ctx);

    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
        return error.ProtocolConfigurationFailed;
    }
    if (c.SSL_CTX_set_max_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
        return error.ProtocolConfigurationFailed;
    }
    c.SSL_CTX_set_alpn_select_cb(ctx, callback, null);
    c.SSL_CTX_set_early_data_enabled(ctx, @intFromBool(early_data));
    return ctx;
}

/// Applies the client-certificate policy to a server context.
///
/// `.none` leaves BoringSSL's default `SSL_VERIFY_NONE` in place: no
/// CertificateRequest is sent and the trust store is never opened. Every other
/// mode requires a CA bundle and asks BoringSSL to verify client chains
/// against it, failing closed when the bundle cannot be loaded.
fn apply_client_auth(ctx: *c.SSL_CTX, config: ClientAuthConfig) !void {
    if (config.mode == .none) return;
    if (config.ca_path.len == 0) return error.InvalidClientAuthConfig;
    if (c.SSL_CTX_load_verify_locations(ctx, config.ca_path.ptr, null) != 1) {
        return error.TrustStoreLoadFailed;
    }

    // SSL_VERIFY_PEER requests the certificate and makes verification errors
    // fatal; the extra flag rejects clients that decline to send one.
    const fail_without_certificate: c_int = if (config.mode == .required)
        c.SSL_VERIFY_FAIL_IF_NO_PEER_CERT
    else
        0;
    c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER | fail_without_certificate, null);
}

/// Generates a P-256 key with a matching self-signed certificate and installs
/// both on `ctx`. The context takes its own references; the local key and
/// certificate are released before returning.
fn install_ephemeral_credentials(ctx: *c.SSL_CTX, names: CertificateNames) !void {
    const pkey = try generate_p256_key();
    defer c.EVP_PKEY_free(pkey);

    const certificate = try create_self_signed_certificate(pkey, names);
    defer c.X509_free(certificate);

    if (c.SSL_CTX_use_certificate(ctx, certificate) != 1) {
        return error.EphemeralCertificateInstallFailed;
    }
    if (c.SSL_CTX_use_PrivateKey(ctx, pkey) != 1) {
        return error.EphemeralCertificateInstallFailed;
    }
    if (c.SSL_CTX_check_private_key(ctx) != 1) {
        return error.EphemeralCertificateInstallFailed;
    }
}

fn generate_p256_key() !*c.EVP_PKEY {
    const keygen = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null) orelse {
        return error.EphemeralKeyGenerationFailed;
    };
    defer c.EVP_PKEY_CTX_free(keygen);

    if (c.EVP_PKEY_keygen_init(keygen) != 1) {
        return error.EphemeralKeyGenerationFailed;
    }
    if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(keygen, c.NID_X9_62_prime256v1) != 1) {
        return error.EphemeralKeyGenerationFailed;
    }

    var pkey: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(keygen, &pkey) != 1) {
        return error.EphemeralKeyGenerationFailed;
    }
    return pkey orelse error.EphemeralKeyGenerationFailed;
}

fn create_self_signed_certificate(pkey: *c.EVP_PKEY, names: CertificateNames) !*c.X509 {
    const certificate = c.X509_new() orelse return error.EphemeralCertificateCreationFailed;
    errdefer c.X509_free(certificate);

    // Version 2 is X.509v3, the minimum version that carries extensions.
    if (c.X509_set_version(certificate, 2) != 1) {
        return error.EphemeralCertificateCreationFailed;
    }
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(certificate), 1) != 1) {
        return error.EphemeralCertificateCreationFailed;
    }
    // Backdate an hour for clock skew; expire after 90 days.
    if (c.X509_gmtime_adj(c.X509_getm_notBefore(certificate), -3600) == null) {
        return error.EphemeralCertificateCreationFailed;
    }
    if (c.X509_gmtime_adj(c.X509_getm_notAfter(certificate), 90 * 24 * 3600) == null) {
        return error.EphemeralCertificateCreationFailed;
    }

    const subject = c.X509_get_subject_name(certificate) orelse {
        return error.EphemeralCertificateCreationFailed;
    };
    // Explicit length: the caller slice is not guaranteed to be NUL-terminated.
    if (c.X509_NAME_add_entry_by_txt(
        subject,
        "CN",
        c.MBSTRING_UTF8,
        names.common_name.ptr,
        @intCast(names.common_name.len),
        -1,
        0,
    ) != 1) {
        return error.EphemeralCertificateCreationFailed;
    }
    // Self-signed: the issuer is the subject.
    if (c.X509_set_issuer_name(certificate, subject) != 1) {
        return error.EphemeralCertificateCreationFailed;
    }
    if (c.X509_set_pubkey(certificate, pkey) != 1) {
        return error.EphemeralCertificateCreationFailed;
    }

    try add_certificate_extension(certificate, c.NID_basic_constraints, "critical,CA:FALSE");
    try add_certificate_extension(certificate, c.NID_key_usage, "critical,digitalSignature");
    try add_certificate_extension(certificate, c.NID_ext_key_usage, "serverAuth");
    try add_subject_alt_name_extension(certificate, names);

    if (c.X509_sign(certificate, pkey, c.EVP_sha256()) == 0) {
        return error.EphemeralCertificateSigningFailed;
    }
    return certificate;
}

fn add_certificate_extension(certificate: *c.X509, nid: c_int, value: [*:0]const u8) !void {
    // The decrepit X509V3_EXT_conf_nid wrapper is not compiled into the
    // pinned BoringSSL; call the exported function it forwards to.
    const extension = c.X509V3_EXT_nconf_nid(null, null, nid, value) orelse {
        return error.EphemeralCertificateExtensionFailed;
    };
    defer c.X509_EXTENSION_free(extension);

    if (c.X509_add_ext(certificate, extension, -1) != 1) {
        return error.EphemeralCertificateExtensionFailed;
    }
}

/// Returns the subjectAltName value length excluding the terminator, or null
/// when no names are configured.
fn subject_alt_name_length(names: CertificateNames) ?usize {
    const count = names.dns_names.len + names.ip_addresses.len;
    if (count == 0) return null;

    var length = (count - 1) * ", ".len;
    for (names.dns_names) |name| length += "DNS:".len + name.len;
    for (names.ip_addresses) |address| length += "IP:".len + address.len;
    return length;
}

fn write_subject_alt_name(buffer: []u8, names: CertificateNames) void {
    var offset: usize = 0;
    for (names.dns_names) |name| {
        offset = append_subject_alt_name_entry(buffer, offset, "DNS:", name);
    }
    for (names.ip_addresses) |address| {
        offset = append_subject_alt_name_entry(buffer, offset, "IP:", address);
    }
}

fn append_subject_alt_name_entry(
    buffer: []u8,
    offset: usize,
    prefix: []const u8,
    value: []const u8,
) usize {
    var cursor = offset;
    if (cursor != 0) {
        @memcpy(buffer[cursor..][0..2], ", ");
        cursor += 2;
    }
    @memcpy(buffer[cursor..][0..prefix.len], prefix);
    cursor += prefix.len;
    @memcpy(buffer[cursor..][0..value.len], value);
    return cursor + value.len;
}

fn add_subject_alt_name_extension(certificate: *c.X509, names: CertificateNames) !void {
    const value_length = subject_alt_name_length(names) orelse return;

    const value = try std.heap.page_allocator.allocSentinel(u8, value_length, 0);
    defer std.heap.page_allocator.free(value);

    write_subject_alt_name(value, names);
    try add_certificate_extension(certificate, c.NID_subject_alt_name, value.ptr);
}

/// Application protocol negotiated on the TLS TCP listener.
pub const ApplicationProtocol = enum(u8) {
    http2,
    http1,
    none,
};

/// Selects `h2` ahead of `http/1.1` from an ALPN wire-format list.
///
/// Malformed length-prefixed input fails closed with `null`.
pub fn select_http_protocol(offered: []const u8) ?ApplicationProtocol {
    var supports_http1 = false;
    var supports_http2 = false;
    var offset: usize = 0;
    while (offset < offered.len) {
        const protocol_length = offered[offset];
        offset += 1;
        if (protocol_length == 0 or protocol_length > offered.len - offset) return null;
        const protocol = offered[offset .. offset + protocol_length];
        offset += protocol_length;
        if (std.mem.eql(u8, protocol, "h2")) supports_http2 = true;
        if (std.mem.eql(u8, protocol, "http/1.1")) supports_http1 = true;
    }
    if (supports_http2) return .http2;
    if (supports_http1) return .http1;
    return null;
}

/// Reads the protocol selected by BoringSSL after a successful handshake.
pub fn negotiated_protocol(ssl: *c.SSL) ApplicationProtocol {
    var selected: [*c]const u8 = null;
    var selected_length: c_uint = 0;
    c.SSL_get0_alpn_selected(ssl, &selected, &selected_length);
    if (selected == null or selected_length == 0) return .none;
    const protocol = selected[0..selected_length];
    if (std.mem.eql(u8, protocol, "h2")) return .http2;
    if (std.mem.eql(u8, protocol, "http/1.1")) return .http1;
    return .none;
}

fn select_http_alpn(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;

    const protocols = "\x02h2\x08http/1.1";

    if (c.SSL_select_next_proto(@ptrCast(out), outlen, protocols, protocols.len, in, inlen) != c.OPENSSL_NPN_NEGOTIATED) {
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return c.SSL_TLSEXT_ERR_OK;
}

fn select_http3_alpn(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;

    const protocols = "\x02h3";
    if (c.SSL_select_next_proto(@ptrCast(out), outlen, protocols, protocols.len, in, inlen) != c.OPENSSL_NPN_NEGOTIATED) {
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return c.SSL_TLSEXT_ERR_OK;
}
