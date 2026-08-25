const std = @import("std");
const c = @import("c");

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    // initializes tls context and loads certificates.
    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        c.CRYPTO_library_init();
        c.SSL_load_error_strings();

        const method = c.TLS_server_method();
        const ctx = c.SSL_CTX_new(method) orelse {
            return error.TlsContextCreationFailed;
        };
        errdefer c.SSL_CTX_free(ctx);

        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

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

    // frees the tls context.
    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};
