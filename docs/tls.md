# TLS

µWebZockets terminates TLS with BoringSSL. There are two ways to give a
server its certificate and key:

| Situation | API | Credentials |
| --- | --- | --- |
| Local development, tests, demos | `init_https_ephemeral` / `init_http3_ephemeral` | Generated in memory at startup |
| Production and shared environments | `init_https` / `init_http3` | PEM files you provide |

Both paths produce the same `TlsContext`, use TLS 1.3 only, and pick the
application protocol through ALPN. The difference is only where the key
material comes from.

## Development: HTTPS with no certificate files

`App.init_https_ephemeral` generates an ECDSA P-256 key and a self-signed
X.509 certificate with BoringSSL, entirely in memory. There is no `openssl`
command to run, no `.pem` files to manage, and no configuration to keep in
sync with a teammate. A complete HTTPS server is:

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn index(_: *uz.Request, response: *uz.Response) void {
    response.text("hello from ephemeral TLS") catch {};
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init_https_ephemeral(init.io);
    defer server.deinit();

    _ = try server.get("/", index);
    try server.listen("0.0.0.0", 3443);
    try server.run();
}
```

```sh
zig build https_server -Doptimize=ReleaseSafe
curl -k https://127.0.0.1:3443/
```

`zig build http3_server` starts the same thing over QUIC on UDP port 8443
using `init_http3_ephemeral`.

### What the generated certificate contains

- ECDSA P-256 key, signed with SHA-256.
- Subject `CN=localhost` and subjectAltName entries for `localhost`,
  `127.0.0.1`, and `::1`.
- `serverAuth` extended key usage, `digitalSignature` key usage, and
  `CA:FALSE` basic constraints, which is what browsers require for a leaf
  certificate.
- Validity from one hour before startup to 90 days after startup. The
  backdating tolerates small clock differences between machines.
- A self-signed issuer identical to the subject.

Pass `tls.CertificateNames` when a project uses a different local hostname:

```zig
const names = uz.tls.CertificateNames{
    .common_name = "api.example.test",
    .dns_names = &.{ "api.example.test", "localhost" },
    .ip_addresses = &.{ "127.0.0.1", "::1" },
};
const credentials = try uz.tls.TlsContext.init_ephemeral(names);
```

The HTTP/3 variant is `TlsContext.init_http3_ephemeral(names)`.

### Why `curl -k` (and what to use instead)

The certificate is self-signed, so no client trusts it automatically. `curl
-k` and the browser "proceed anyway" button skip verification, which is fine
for local smoke tests. When a workflow needs a trusted local certificate
(service workers, HTTP/3 clients with strict verification, mobile devices on
the same LAN), generate one with [`mkcert`](https://github.com/FiloSottile/mkcert)
or your internal CA and pass the files to `init_https`; ephemeral credentials
are deliberately not exportable.

### Lifecycle and allocation

Generation runs once inside `init_*_ephemeral`, before the event loop starts.
BoringSSL allocates while the key and certificate are built, and the library
releases every object it owns (the `SSL_CTX` keeps its own references). After
the call returns, connection setup, handshakes, record processing, and every
request path allocate nothing. Nothing is ever written to disk.

Creating a fresh certificate on every start means restarting invalidates
cached handshakes. That is the right trade-off for development; production
servers should keep long-lived PEM files.

## Production: PEM files

```zig
var server = try uz.App(128).init_https(
    init.io,
    "certs/fullchain.pem",
    "certs/privkey.pem",
);
defer server.deinit();
```

`init_http3` additionally creates the QUIC context and loads the same
certificate and key into both contexts.

- The certificate argument is a PEM chain, leaf first.
- The key argument is a PEM private key. `SSL_CTX_check_private_key` runs at
  startup, so a mismatched pair fails fast with `error.KeyMismatch` instead of
  failing during the first handshake.
- Paths are NUL-terminated Zig slices (`[:0]const u8`).

## Client certificates (mTLS)

Use client-certificate authentication when the caller's identity must be
proven before a request reaches a route: service-to-service APIs, internal
admin surfaces, or device fleets that already hold certificates from a private
CA. The server verifies the client chain against a CA bundle you provide, and
the TLS layer fails the handshake closed before any HTTP parser sees a byte.

```zig
var server = try uz.App(128).init_https_mtls(
    init.io,
    "certs/fullchain.pem",
    "certs/privkey.pem",
    .{ .mode = .required, .ca_path = "certs/client-ca.pem" },
);
defer server.deinit();
```

`tls.TlsContext.init_mtls(cert_path, key_path, config)` is the context-level
entry point and `App.init_https_mtls` is the application-level one. Both keep
the `init`/`init_https` ALPN policy (`h2`, then `http/1.1`) and the safe-method
0-RTT replay policy. `ClientAuthConfig.ca_path` accepts a NUL-terminated
(`[:0]const u8`) path and defaults to empty.

### Modes

`tls.ClientAuth` selects one of three policies:

| Mode | Requests a certificate | Verifies it | Anonymous clients |
| --- | --- | --- | --- |
| `tls.ClientAuth.none` | No | No | Allowed |
| `tls.ClientAuth.optional` | Yes | When presented | Allowed |
| `tls.ClientAuth.required` | Yes | Yes; a missing certificate fails the handshake | Rejected |

`none` is the `init`/`init_https` default and skips the trust store entirely:
no certificate is requested, so BoringSSL never opens `ca_path` and the field
may stay empty. The other modes require a non-empty `ca_path` and reject the
configuration with `error.InvalidClientAuthConfig` otherwise. A bundle that
BoringSSL cannot read or parse fails context creation with
`error.TrustStoreLoadFailed`; a context is never returned with a partially
configured trust store.

### CA bundle format

`ca_path` points at a PEM file of trust anchors for client chains. One file
may hold a single CA certificate or several concatenated in any order;
BoringSSL loads them all, along with any CRLs in the file. The bundle is read
once when the context is created, so replacing it requires a restart.

### HTTP/3

Client authentication is TCP-only in 1.7.0. The HTTP/3 context created by
`init_http3` advertises `h3`, keeps early data disabled, and does not request a
client certificate. Wiring client certificates through the QUIC transport is
future work.

## Protocol policy

- TLS 1.3 only; older protocol versions are rejected at the context.
- HTTP/1.1 and HTTP/2 share one context advertising `h2`, then `http/1.1`.
  `ApplicationProtocol` and `select_http_protocol` expose the negotiation
  result.
- HTTP/3 uses a separate context advertising `h3`.
- 0-RTT early data is enabled on the TCP context. The HTTP dispatcher admits
  only safe methods until the handshake is confirmed, because early data is
  replayable by a network attacker. QUIC keeps early data disabled until
  lsquic's replay policy is wired end to end. Ephemeral contexts inherit both
  policies unchanged.

## C ABI

The equivalent C entry points are declared in
[`include/uWebZockets.h`](../include/uWebZockets.h):

```c
uwz_app *app = NULL;
if (uwz_app_create_tls_ephemeral(&app) != UWZ_OK) {
    /* generation failed */
}
/* register routes, listen, run, destroy as usual */
```

`uwz_app_create_http3_ephemeral` mirrors the Zig HTTP/3 variant. Both generate
the same localhost certificate, so treat them as development tools. When a
generated credential cannot be created, the C layer reports
`UWZ_ERROR_INTERNAL`; the Zig layer returns the specific
`error.Ephemeral*` value.

## Zig error reference

| Error | Meaning |
| --- | --- |
| `CertificateLoadFailed` | The PEM chain could not be read or parsed |
| `PrivateKeyLoadFailed` | The PEM key could not be read or parsed |
| `KeyMismatch` | Certificate and key do not belong together |
| `InvalidClientAuthConfig` | A client-auth mode other than `.none` was given with an empty `ca_path` |
| `TrustStoreLoadFailed` | The client CA bundle could not be read or parsed |
| `TlsContextCreationFailed` | BoringSSL could not allocate the context |
| `ProtocolConfigurationFailed` | TLS 1.3 bounds could not be applied |
| `EphemeralKeyGenerationFailed` | P-256 key generation failed |
| `EphemeralCertificateCreationFailed` | X.509 field population failed |
| `EphemeralCertificateExtensionFailed` | SAN or usage extension rejected |
| `EphemeralCertificateSigningFailed` | Self-signature failed |
| `EphemeralCertificateInstallFailed` | The context rejected the credentials |

## Related reading

- [Memory model](memory_model.md) for how TLS connections fit into the
  startup slab.
- [Architecture](architecture.md) for the TCP/QUIC transport and event-loop
  layout behind the handshake.
- [Protocols](protocols.md) for ALPN selection and the HTTP/2, HTTP/3, and
  WebSocket state machines that run after the handshake.
