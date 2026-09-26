//! BoringSSL client-side TLS context and session plumbing.
//!
//! This module owns only BoringSSL objects and pure name classification. It
//! performs no I/O and no allocation after `ClientContext.init` and
//! `Session.init`; the transport drives the memory BIO pair exactly like the
//! server path in `src/core/tcp.zig`.

const std = @import("std");
const c = @import("c");

/// Ciphertext capacity of each side of the memory BIO pair.
pub const bio_capacity = 32 * 1024;
/// Maximum accepted SNI and verification name length.
pub const max_server_name_bytes = 255;
/// Maximum accepted CA bundle path length.
pub const max_ca_path_bytes = 4096;

/// Trust policy for one client TLS context.
pub const ContextOptions = struct {
    /// Verifies the server chain and name. Requires `ca_path`.
    verify: bool = true,
    /// PEM bundle loaded into the BoringSSL trust store.
    ca_path: ?[:0]const u8 = null,
};

/// Failure modes of `ClientContext.init`.
pub const ContextError = error{
    CaPathRequired,
    CertificateLoadFailed,
    TlsContextCreationFailed,
};

/// Owning BoringSSL client context with a fixed trust policy.
pub const ClientContext = struct {
    ctx: *c.SSL_CTX,
    verify: bool,

    /// Creates a client context.
    ///
    /// BoringSSL ships no default trust store, so `verify = true` with a null
    /// `ca_path` fails closed with `error.CaPathRequired`. `verify = false`
    /// disables chain and name checking and is a development-only mode.
    pub fn init(options: ContextOptions) ContextError!ClientContext {
        if (options.verify and options.ca_path == null) return error.CaPathRequired;

        c.CRYPTO_library_init();
        c.SSL_load_error_strings();

        const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse {
            return error.TlsContextCreationFailed;
        };
        errdefer c.SSL_CTX_free(ctx);

        if (options.verify) {
            if (c.SSL_CTX_load_verify_locations(ctx, options.ca_path.?.ptr, null) != 1) {
                return error.CertificateLoadFailed;
            }
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        } else {
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
        }
        return .{ .ctx = ctx, .verify = options.verify };
    }

    /// Releases the owned context.
    pub fn deinit(self: *ClientContext) void {
        c.SSL_CTX_free(self.ctx);
        self.ctx = undefined;
    }
};

/// Failure modes of `Session.init`.
pub const SessionError = error{
    ServerNameEmpty,
    ServerNameTooLong,
    SslAllocationFailed,
    BioAllocationFailed,
    SniConfigurationFailed,
    AlpnConfigurationFailed,
    HostnameVerificationFailed,
};

/// One non-blocking client TLS session with a paired memory BIO.
pub const Session = struct {
    ssl: ?*c.SSL = null,
    network_bio: ?*c.BIO = null,

    /// Allocates the BoringSSL session and arms a connect-state handshake.
    ///
    /// The SNI and verification names are copied into BoringSSL, so
    /// `server_name` may be a borrowed slice.
    pub fn init(
        self: *Session,
        ctx: *c.SSL_CTX,
        server_name: []const u8,
        verify: bool,
    ) SessionError!void {
        if (server_name.len == 0) return error.ServerNameEmpty;
        if (server_name.len > max_server_name_bytes) return error.ServerNameTooLong;

        var name_buffer: [max_server_name_bytes + 1]u8 = undefined;
        @memcpy(name_buffer[0..server_name.len], server_name);
        name_buffer[server_name.len] = 0;
        const name_z: [:0]const u8 = name_buffer[0..server_name.len :0];

        const ssl = c.SSL_new(ctx) orelse return error.SslAllocationFailed;
        errdefer c.SSL_free(ssl);

        var ssl_bio: ?*c.BIO = null;
        var network_bio: ?*c.BIO = null;
        if (c.BIO_new_bio_pair(&ssl_bio, bio_capacity, &network_bio, bio_capacity) != 1) {
            return error.BioAllocationFailed;
        }
        errdefer {
            if (ssl_bio) |bio| _ = c.BIO_free(bio);
            if (network_bio) |bio| _ = c.BIO_free(bio);
        }

        c.SSL_set_bio(ssl, ssl_bio.?, ssl_bio.?);
        ssl_bio = null;
        c.SSL_set_connect_state(ssl);

        if (c.SSL_set_tlsext_host_name(ssl, name_z.ptr) != 1) {
            return error.SniConfigurationFailed;
        }
        // HTTP/1.1 is the only application protocol this client speaks.
        const alpn = "\x08http/1.1";
        if (c.SSL_set_alpn_protos(ssl, alpn, alpn.len) != 0) {
            return error.AlpnConfigurationFailed;
        }
        if (verify and !configure_name_verification(ssl, name_z.ptr)) {
            return error.HostnameVerificationFailed;
        }

        self.ssl = ssl;
        self.network_bio = network_bio.?;
    }

    /// Releases the session and its paired BIO.
    pub fn deinit(self: *Session) void {
        if (self.ssl) |ssl| c.SSL_free(ssl);
        if (self.network_bio) |bio| _ = c.BIO_free(bio);
        self.* = .{};
    }
};

/// Requires the leaf certificate to match `name` during verification.
///
/// IPv4 and IPv6 literals use the IP SAN parameter; other names use the DNS
/// SAN parameter with the deprecated subject CN fallback disabled.
fn configure_name_verification(ssl: *c.SSL, name: [*:0]const u8) bool {
    if (is_ip_literal(std.mem.span(name))) {
        const param = c.SSL_get0_param(ssl) orelse return false;
        return c.X509_VERIFY_PARAM_set1_ip_asc(param, name) == 1;
    }
    c.SSL_set_hostflags(ssl, c.X509_CHECK_FLAG_NEVER_CHECK_SUBJECT);
    return c.SSL_set1_host(ssl, name) == 1;
}

/// Reports whether `name` is an IPv4 or IPv6 address literal.
pub fn is_ip_literal(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, ':') != null) return true;

    var groups: usize = 0;
    var digits_in_group: usize = 0;
    for (name) |byte| {
        if (byte == '.') {
            if (digits_in_group == 0) return false;
            groups += 1;
            digits_in_group = 0;
            continue;
        }
        if (byte < '0' or byte > '9') return false;
        digits_in_group += 1;
    }
    return groups == 3 and digits_in_group > 0;
}
