# Roadmap and Boundaries

This page is the honest map of what µWebZockets does, what it deliberately does
not do, and why. It exists so a developer can decide whether a missing feature
is a defect, a scoped decision, or pending work.

## Closed in 1.7.0

| Boundary | Resolution |
| --- | --- |
| No client API | Bounded HTTP/1.1 client over TCP and TLS with fixed slots, timeouts, and loopback tests ([client.md](client.md)) |
| No mutual TLS | `init_https_mtls` with `none` / `optional` / `required` verification against a caller CA bundle ([tls.md](tls.md#client-certificates-mtls)) |
| No auth or rate limiting | `middleware.Auth` (Basic/Bearer, constant-time) and `middleware.RateLimit` (fixed token buckets, rotation-resistant) ([http.md](http.md#middleware)) |
| No graceful shutdown helper | `App.catch_shutdown_signals()` and `Cluster.catch_shutdown_signals()` for SIGINT/SIGTERM and Windows console control |
| HTTP/2 and HTTP/3 were invisible in the dev log | One `http_request` record per completed exchange on both, plus HTTP/2 counter increments |
| Docs could drift | `scripts/check_docs.sh` validates every relative markdown link in CI |
| Stale supported-version policy | [SECURITY.md](../SECURITY.md) tracks the latest released minor line |
| Monolithic protocol documentation | Split into [http.md](http.md), [http2.md](http2.md), [quic.md](quic.md), [websocket.md](websocket.md), and [json_rpc.md](json_rpc.md) |

## Deliberate boundaries

These are decisions, not omissions. Each has a reason and, where relevant, the
condition that would change it.

| Boundary | Reason |
| --- | --- |
| TLS 1.2 is not supported | TLS 1.3-only is a deliberate security posture; adding 1.2 would re-enable obsolete cipher suites for no functional gain |
| No dynamic capacity overflow | Fixed startup slabs are the architecture. Exhaustion returns a structured error; silently allocating would reintroduce heap behavior on the hot path |
| Request bodies are buffered, not streamed to handlers | Handlers are synchronous; true upload streaming needs an async body-reader contract. Response streaming already exists (`begin_stream`) |
| HTTP/2 server push is not implemented | Deprecated in practice and removed from lsquic upstream; no browser consumes it |
| h2c Upgrade is not implemented | RFC 9113 removed the Upgrade mechanism; cleartext HTTP/2 uses prior knowledge and TLS uses ALPN |
| HTTP/2 caps at 8 concurrent streams and one WebSocket tunnel per connection | Stream and tunnel storage is connection-owned and carved from the slab. Raising the defaults requires specializing the connection type |
| WebTransport is not live | The pinned lsquic build exposes raw datagrams but not extended CONNECT, server-initiated unidirectional streams, or reset-at; see [ADR 0001](adr/0001-http3-datagram-and-webtransport.md) |
| HTTP/3 does not advance the metrics registry | The engine has no registry handle without new plumbing through the transport; records are emitted instead |
| kTLS is a standalone helper, not an integrated offload | The pinned BoringSSL has no kernel-TLS support, so the connection path cannot hand keys to the kernel. `uz.ktls` remains available to applications that manage their own records |
| MemorySanitizer does not instrument Zig code | Zig 0.16 emits no MSan instrumentation. The MSan gate covers the pinned C/C++ dependency boundary |
| BSD targets have no runtime CI | No hosted GitHub runners exist for the BSDs; the shared build graph is compiled but not executed in CI |
| Windows runtime validation is blocked upstream | The pinned libxev IOCP backend submits `AcceptEx` with a zero local-address length; `windows-2025` rejects it with `WSAEINVAL (10022)` on the first accept and libxev then panics mapping the unmapped error code. Every Windows listener uses that path. The workflow stays compile-only until libxev is fixed or a Windows accept fallback lands |
| macOS workers are unpinned | The platform exposes no hard-affinity API |
| The client is HTTP/1.1 only | It is deliberately small: no DNS resolution (numeric addresses only), no redirects, no cookies, no proxy support, no connection pooling, no mTLS, and no HTTP/2 or HTTP/3 client |
| The C ABI is a high-level subset | Opaque handles and fixed capacities target C/C++ consumers; the low-level HTTP/2, HPACK, HTTP/3-extension, WebTransport, UDP, and client modules are Zig-only |
| Zig 0.16.0 is the only supported toolchain | It is the latest usable release without known breaking defects for this codebase. Pre-1.0 toolchains churn; pin the exact compiler |

## Near-term direction

Candidates for the next minor releases, in rough dependency order:

1. **WebSocket client** over the existing client transport, using the zslay
   client role for framing and masking.
2. **Incremental request bodies** for HTTP/1.1: a bounded, async body reader
   that lets large uploads bypass `max_body_size` per connection.
3. **Configurable HTTP/2 stream and tunnel counts** through connection-type
   specialization.
4. **HTTP/3 counter parity** by threading the metrics registry into the engine.
5. **WebTransport activation** behind the capability gate recorded in
   [ADR 0001](adr/0001-http3-datagram-and-webtransport.md), once the pinned
   lsquic exposes the required server interfaces.
6. **kTLS integration** if BoringSSL gains a supported key-handoff API.

## How to influence the roadmap

Open an issue describing the use case, or a pull request following
[CONTRIBUTE.md](../CONTRIBUTE.md). The project accepts additive changes that
preserve bounded behavior; proposals that add unbounded allocation to the hot
path or weaken a compliance gate are declined by policy, not by preference.
