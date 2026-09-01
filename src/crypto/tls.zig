const std = @import("std");
const c = @import("c");

const AlpnCallback = *const fn (
    ?*c.SSL,
    [*c][*c]const u8,
    [*c]u8,
    [*c]const u8,
    c_uint,
    ?*anyopaque,
) callconv(.c) c_int;

/// Owning BoringSSL server context with a fixed ALPN policy.
pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    /// Loads an HTTPS context advertising `h2` then `http/1.1`.
    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        return init_with_alpn(cert_path, key_path, select_http_alpn);
    }

    /// Loads an HTTP/3-only context advertising `h3` and rejecting 0-RTT.
    pub fn init_http3(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        const context = try init_with_alpn(cert_path, key_path, select_http3_alpn);
        c.SSL_CTX_set_early_data_enabled(context.ctx, 0);
        return context;
    }

    fn init_with_alpn(
        cert_path: [:0]const u8,
        key_path: [:0]const u8,
        callback: AlpnCallback,
    ) !TlsContext {
        c.CRYPTO_library_init();
        c.SSL_load_error_strings();

        const method = c.TLS_server_method();
        const ctx = c.SSL_CTX_new(method) orelse {
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

        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path.ptr) != 1) {
            return error.CertificateLoadFailed;
        }

        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
            return error.PrivateKeyLoadFailed;
        }

        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            return error.KeyMismatch;
        }

        return TlsContext{ .ctx = ctx };
    }

    /// Releases the owned BoringSSL context.
    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

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
