const std = @import("std");
const c = @import("c");

/// Non-blocking TLS handshake outcome for one BoringSSL step.
pub const HandshakeStatus = enum {
    success, // handshake complete, ready for cleartext data
    want_read, // tcp needs to read more bytes from network into rbio
    want_write, // tcp needs to flush bytes from wbio to network
    failed, // certificate error, protocol mismatch, or fatal error
};

/// Advances `ssl` once without waiting for socket readiness.
pub fn step(ssl: *c.SSL) HandshakeStatus {
    const ret = c.SSL_do_handshake(ssl);

    if (ret == 1) return .success;

    const err = c.SSL_get_error(ssl, ret);
    switch (err) {
        c.SSL_ERROR_WANT_READ => return .want_read,
        c.SSL_ERROR_WANT_WRITE => return .want_write,
        else => {
            // unrecoverable errors like syscall failures or protocol violations
            std.debug.print("tls handshake failed. boringssl error code: {d}\n", .{err});
            return .failed;
        },
    }
}
