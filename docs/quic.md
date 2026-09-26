# QUIC and HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises `h2` and
`http/1.1`, while QUIC advertises only `h3`. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`. The `App` value must remain at a
stable address after `listen_udp`.

```zig
var server = try uz.App(128).init_http3(init.io, "certs/fullchain.pem", "certs/privkey.pem");
defer server.deinit();

_ = try server.get("/", hello);
try server.listen("0.0.0.0", 3443);      // TCP/TLS
try server.listen_udp("0.0.0.0", 8443);  // QUIC
try server.run();
```

For local development, `init_http3_ephemeral` generates an in-memory
certificate; see [tls.md](tls.md).

## Request path

The adapter decodes HTTP/3 pseudo-headers directly into the existing `Request`
shape and writes structured QPACK response headers without converting through
HTTP/1.1 text. QUIC connections, streams, header sets, packet buffers, and
bodies come from startup-allocated contiguous pools.

- The live listener explicitly rejects TLS 0-RTT so replayable application
  requests never reach a handler. Pure early-data policy helpers remain
  available for a future backend that exposes per-request early-data state.
- Congestion control is pinned to BBRv1 with per-connection pacing.
- The engine enforces decoded header limits, request bodies, packet buffers,
  connections, and active streams through `ServerConfig`.

## Observability

HTTP/3 emits one `http_request` development-log record per completed
request/response cycle through the owning thread's sink. The QUIC path does not
advance the counter registry in this release.

## RFC 10008 `QUERY`

Both routing APIs support the `QUERY` method. It rejects a missing or
syntactically invalid `Content-Type`; resource-specific media-type and content
consistency remain the handler's policy.

## Extended CONNECT, WebTransport, and datagrams

`uz.http3_extensions` supplies RFC 9220 extended CONNECT validation, push
bookkeeping, and replay-aware early-data policy. `uz.webtransport` supplies
bounded draft-16 settings, CONNECT/origin checks, sessions, stream and datagram
association, capsules, flow control, and error mapping.

Those extension modules are **not connected to the live lsquic listener**. The
pinned backend exposes raw datagrams but not the complete extended CONNECT,
outgoing unidirectional stream, or reset-at interfaces they require, and the
pinned build does not enable the WebTransport server compile option. The live
listener rejects CONNECT with `501 Not Implemented`, and WebTransport models
draft-16 only: it is not a claim of deployed interoperability.

[adr/0001-http3-datagram-and-webtransport.md](adr/0001-http3-datagram-and-webtransport.md)
records the exact backend blockers, what is already available, and the
capability-gated activation path for when upstream exposes the missing
interfaces.

## Verification

The cross-implementation gate uses pinned curl/ngtcp2 and aioquic clients to
verify the normal request path, a valid trailing field section, and malformed
pseudo-header/connection-field rejection with `H3_MESSAGE_ERROR`. Malformed and
healthy sibling streams share one connection so connection-wide aborts fail the
gate. The gate retains server logs, traces, versions, results, and qlogs; see
[operations.md](operations.md) and [CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md).
