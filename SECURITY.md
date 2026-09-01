# Security Policy

## Supported versions

This source tree is preparing `1.0.0`; no `v1.0.0` release tag has been
published yet. Until publication, security fixes apply to the current
development revision. After publication, fixes apply to the latest `1.0.x`
patch release. Older snapshots and unsupported raw transport internals do not
receive backports.

| Version | Supported |
| --- | --- |
| Current development revision | Yes |
| Tagged releases | None published yet |
| Earlier snapshots | No |

## Reporting a vulnerability

Do not open a public issue, pull request, discussion, or Autobahn report that
contains an undisclosed vulnerability.

Send a private report to
[trananhquan1009@gmail.com](mailto:trananhquan1009@gmail.com) or
[noah1109.tran@gmail.com](mailto:noah1109.tran@gmail.com). Include:

- the affected revision and target platform;
- a minimal reproducer or packet sequence;
- expected and observed behavior;
- impact and preconditions;
- logs or sanitizer output with secrets removed; and
- any suggested mitigation.

The maintainers will acknowledge the report, reproduce and assess it, prepare a
fix and regression test, and coordinate disclosure. Response time depends on
severity and maintainer availability; no fixed service-level agreement is
offered.

## Security boundaries

The live network surface is HTTP/1.1, bounded HTTP/2, RFC 6455 WebSockets,
RFC 7692 per-message deflate, HTTPS, and bounded HTTP/3 request/response
routing. HTTP/2 accepts plaintext prior knowledge or TLS ALPN and caps each
connection at eight streams. Raw QUIC engine, stream, packet, and QPACK
callbacks under `src/quic` are internal and are not a supported consumer
interface.

`http3_extensions` and `webtransport` validate untrusted protocol metadata in
caller-owned bounds, but they are not connected to the live lsquic listener.
WebTransport implements draft-ietf-webtrans-http3-16 wire semantics. RFC 10008
is the separate HTTP `QUERY` method supported by the router. Live transports
reject QUERY requests without a syntactically valid `Content-Type` before the
route handler runs.
The pinned backend provides raw datagrams but not every extended CONNECT,
push, outgoing-stream, and reset-at callback needed to enable those features.

Deployments must set connection, WebSocket message, write-queue, and HTTP/3
response capacities appropriate for their traffic, select an appropriate idle
timeout, and apply normal operating-system resource limits. The default idle
timeout is 120 seconds; `ConfiguredAppWithTimeout` can change it or disable
idle sweeping with zero. HTTP/3 additionally bounds decoded headers, request
bodies, packet buffers, connections, and active streams.

Parameterized routing stores at most 16 borrowed captures per request and 64
patterns per router. Global middleware is capped at 32 entries. Asynchronous
response tokens are generation-checked and one-shot; they are confined to the
owning event loop, invalidate on transport reuse, and must not be completed
from another thread without first marshalling work to that loop.

Per-message deflate is disabled by default. When enabled, negotiation requires
client and server no-context-takeover, compressed input and output use separate
caller-owned scratch slices, and decompression cannot exceed the configured
message capacity. An 8-bit server compression window is declined because zlib
cannot emit it reliably; incoming 8-bit client streams retain the same
decompression bound.

Request and WebSocket message slices are borrowed from fixed connection
storage. Request and parameter slices remain valid until a synchronous handler
returns or its asynchronous token completes; WebSocket message slices remain
valid only for their callback. The application value itself must remain at a
stable address after `listen` or `listen_udp`.

The C ABI in `include/uWebZockets.h` uses opaque handles and copied route paths,
but returned `uwz_slice` values are still borrowed. Applications must destroy
opaque handles explicitly and handle every nonzero `uwz_error`. Copy request
fields and route parameters into caller-owned storage before a C callback
returns if asynchronous work needs them. Copy async tokens, marshal completion
to the owning event loop, and complete each generation at most once.

The project uses bounded buffers and protocol compliance tests to reduce risk,
but these controls do not guarantee the absence of defects. Consumers should
pin exact source or release hashes, review `THIRD_PARTY_NOTICES.md`, and test
the library under their own workload before production deployment.

Application teardown is completion-driven: stop accepting new work, cancel and
drain registered libxev operations, then release TLS, QUIC, event-loop, and slab
storage. Consumers should call `deinit` through `defer` and must not copy or move
an `App` after `listen` or `listen_udp` has registered callbacks.

CI runs the centralized Zig and C ABI graph with ASan, UBSan, and leak
detection on native Linux while instrumenting the pinned C/C++ dependencies
and local C shim. A separate, mutually exclusive x86_64 Linux
MemorySanitizer job rebuilds those C/C++ components with origin tracking and
executes a focused dependency-boundary smoke. It does not claim MSan
instrumentation of Zig code or full C ABI behavior. Google
OSS-Fuzz/libFuzzer entrypoints exercise HTTP
framing, WebSocket masking, and QUIC/WebTransport packet boundaries; local
deterministic smoke seeds are retained. Autobahn, h1spec, and the pinned
curl/ngtcp2 plus aioquic HTTP/3 gate add protocol coverage. Deployments should
still perform workload-specific QUIC load testing.

Only POSIX targets are supported. The configured publish and CI matrix covers
Linux and macOS. FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD are accepted by the
build but do not receive the same release-matrix coverage. Windows is outside
the security and compatibility support boundary.

## Disclosure

Please allow a reasonable remediation and release window before publication.
Security advisories will credit reporters who request attribution and will
describe affected versions, impact, and upgrade guidance without exposing
unnecessary exploit detail before a fix is available.
