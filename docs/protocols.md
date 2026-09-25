# Protocols

µWebZockets exposes one application boundary (`Request`, `Response`, router,
middleware) across HTTP/1.1, HTTP/2, and HTTP/3, plus WebSocket and JSON-RPC.
This document covers wire behavior, ownership rules, and compliance status.
See [architecture.md](architecture.md) for the runtime and
[memory_model.md](memory_model.md) for capacities.

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, and bodies, and unsupported expectations. Pipelined
bytes are retained and parsed again after a response completes. Responses
validate control-character injection and ambiguous `Content-Length` /
`Transfer-Encoding` before writing.

Request bodies default to 16 KiB and are configurable through
`ServerConfig.max_body_size`. A body above the limit returns
`413 Payload Too Large`; headers above the limit return `431 Request Header
Fields Too Large`. Both carry the structured JSON documents described in
[memory_model.md](memory_model.md). `100 Continue` is handled automatically.

For incremental output, call `begin_chunked`, `write_chunk` as needed, then
`end_chunks`. `Request` fields and route-parameter values borrow the
connection's request buffer and stay valid through a synchronous callback or
until an asynchronous response completes; copy them into bounded application
storage for longer work.

## Routing and middleware

Exact routes stay on the radix fast path. A `:name` segment captures one
nonempty path segment, and a terminal `*name` captures the remaining path
including an empty remainder. `Request.get_param` reads up to 16 borrowed
captures.

- Static routes win over parameter and wildcard matches.
- Malformed patterns, duplicate parameter names, and nonterminal wildcards fail
  registration instead of falling back to ambiguous matching.
- `App.use` appends at most 32 global middleware callbacks. They run in order
  and stop when they return `.stop` or start a response.
- `route_context` and `get_context` retain an explicit caller-owned context
  pointer.
- `route_async`, `get_async`, and their context variants receive a
  generation-checked response token that completes exactly once. Completion is
  confined to the owning event loop; marshal cross-thread results back to that
  loop. A pending token keeps the TCP request buffer or HTTP/3 stream from
  being reused.

Integration code may attach borrowed `extra_param_*` or `extra_header_*` slices
when adapting a different parser. The built-in parsers do not populate them or
expand their fixed capacities dynamically.

`App.static(prefix, root, options)` mounts a directory with directory-relative
path confinement, symlinks disabled, MIME detection, ETag and Last-Modified
validation, cache control, and one RFC 9110 byte range. Plaintext `GET` and
`HEAD` responses stream the file with the kernel `sendfile` boundary
(`Response.send_file`), so assets are not capped by the per-route file buffer.
TLS, HTTP/2, and HTTP/3 remain on the bounded buffered path. `App.openapi(path)`
serves a generated OpenAPI 3.1 document; parameter and wildcard paths are
emitted with OpenAPI braces.

`Request.clone(allocator)` creates an owned snapshot for deferred worker work;
call `deinit` on the returned `OwnedRequest`. Framework modules also expose
zero-allocation query/form parsing with SIMD slicing and compile-time
capacities, streaming chunked JSON (`Response.begin_json`), drain-driven
producer bodies that resume past write-queue and flow-control backpressure
(`Response.begin_stream`), multipart iteration, HMAC-SHA256 signed cookies
with rotating keys and HTTP-date `Expires`, comptime JSON field constraints
with typed parse issues, canonical status lines, typed JSON error documents,
`Accept` negotiation, ETag and conditional-GET helpers, CORS and
security-header middleware, and SSE.

## JSON-RPC

`json_rpc.Service` is a type-safe, fixed-capacity JSON-RPC 2.0 registry. Mount
it on any `App` with one line, or call `dispatch` directly from another
transport. The protocol layer imports only Zig's standard library.

- Clients send exactly one `Content-Type: application/json` or
  `application/json-rpc` header.
- Single calls, notifications, and batches are supported. Notification-only
  requests return HTTP 204; protocol responses use HTTP 200.
- Complete JSON syntax is validated before a batch invokes its first procedure.
- Method names are copied during registration, and mounting seals the registry.
- Parameters are borrowed only for the callback. Results serialize into bounded
  caller- or service-owned output storage.
- `register_context` and `register_typed_context` carry explicit application
  state. `register` supports custom decoding, and `Call.fail` returns an
  application-defined error.
- One mounted service owns one HTTP response buffer and belongs to one event
  loop. Create one service per cluster worker.

Typed adapters use 4 KiB of fixed stack scratch for decoded parameters. Use the
lower-level `register` API with `Call.parse_params` and an explicit allocator
when a parameter type can exceed that bound.
`configured_service(max_procedures, method_storage_capacity,
response_capacity)` adjusts the defaults of 64 procedures, 4 KiB of copied
method names, and a 16 KiB response.

## WebSocket

`App` defaults to 16 KiB WebSocket messages. `ConfiguredApp` changes the
compile-time connection count, message capacity, and write-queue capacity.
`send` returns `error.WouldBlock` when bounded output storage is exhausted; the
`drain` callback and `buffered_amount` resume producers. Incoming `message`
slices are valid only for the callback. Outgoing text and close data are
validated; `send_close` closes after the frame drains, while `terminate` closes
immediately.

Compression is opt-in per route through `.compression = .permessage_deflate`.
Negotiation always selects `server_no_context_takeover` and
`client_no_context_takeover`, accepts window sizes 9 through 15 for server
output and 8 through 15 for client input, and rejects compressed expansion
beyond `max_message_size`. Enabling compression allocates paired receive and
send scratch per connection during route registration; message processing does
not allocate. Set `ServerConfig.compression = true` to reserve that scratch
inside the startup slab instead.

Heartbeat-enabled routes reuse the connection sweeper: idle peers receive an
empty ping and are closed if the configured pong timeout expires. The default
idle timeout is 120 seconds, refreshed by successful reads and writes. Use
`ConfiguredAppWithTimeout` to select another compile-time timeout, or zero to
disable idle sweeping.

## HTTPS

`init_https` loads PEM certificate and private-key paths. The server negotiates
TLS 1.3 and prefers ALPN `h2`, then `http/1.1`. Plaintext listeners also detect
the HTTP/2 prior-knowledge preface; h2c Upgrade is not required. For local
development, `init_https_ephemeral` skips the files and generates a self-signed
P-256 certificate in memory at startup; [tls.md](tls.md) covers both credential
paths.

The HTTPS context enables TLS 1.3 0-RTT (early data). Early data is replayable
by a network attacker, so only safe methods (`GET`, `HEAD`, `OPTIONS`) are
dispatched before the handshake is confirmed. Any other method receives
`425 Too Early`: HTTP/1.1 closes the connection, and HTTP/2 rejects the stream.
Early data that BoringSSL does not accept is dropped server side and the full
handshake completes in place, so the client resends under 1-RTT. The HTTP/3
context keeps early data disabled.

## HTTP/2 and HPACK

`uz.http2` exposes strict frame headers, peer settings, a fixed-capacity
structure-of-arrays stream slab, and a server-side connection state machine. It
validates the client preface, frame sizes and sequencing, stream lifecycle,
settings, and flow-control windows. `uz.http2_hpack` exposes a bounded HPACK
decoder/encoder with caller-owned dynamic-table, header, and byte storage,
including Huffman and pseudo-header validation.

`App.listen` dispatches plaintext prior-knowledge HTTP/2, while `init_https`
selects it through ALPN. Each TCP connection embeds an eight-stream request,
body, response, and async-token slab. SETTINGS, PING, GOAWAY, RST_STREAM,
trailers, partial DATA, and connection/stream flow control are handled without
dynamic allocation. RFC 8441 WebSocket tunneling is supported via extended
CONNECT; because parsing and message storage are connection-owned, each
connection permits one active tunnel and additional tunnels receive
`503 Service Unavailable` without disturbing it.

## HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises `h2` and
`http/1.1`, while QUIC advertises only `h3`. `init_http3_ephemeral` performs
the same setup with an in-memory certificate. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`. The adapter decodes HTTP/3
pseudo-headers directly into the existing `Request` shape and writes structured
QPACK response headers without converting through HTTP/1.1 text. The `App`
value must remain at a stable address after `listen_udp`.

The live listener explicitly rejects TLS 0-RTT so replayable application
requests never reach a handler; pure early-data policy helpers remain available
for a future backend that exposes per-request early-data state.

The cross-implementation gate uses pinned curl/ngtcp2 and aioquic clients to
verify the normal request path, a valid trailing field section, and malformed
pseudo-header/connection-field rejection with `H3_MESSAGE_ERROR`. Malformed and
healthy sibling streams share one connection so connection-wide aborts fail the
gate.

`uz.http3_extensions` supplies RFC 9220 extended CONNECT validation, push
bookkeeping, and replay-aware early-data policy. `uz.webtransport` supplies
bounded draft-16 settings, CONNECT/origin checks, sessions, stream and datagram
association, capsules, flow control, and error mapping. Those extension modules
are not connected to the live lsquic listener: the pinned backend exposes raw
datagrams but not the complete extended CONNECT, push, outgoing unidirectional
stream, or reset-at interfaces they require. WebTransport therefore models
draft-16 only and is not a claim of deployed interoperability.

RFC 10008 defines the separate HTTP `QUERY` method, supported by both routing
APIs. It rejects a missing or syntactically invalid `Content-Type`;
resource-specific media-type and content consistency remain the handler's
policy.

## Web-standard API conventions

The public HTTP surface uses familiar WHATWG Fetch and Streams concepts where
they fit Zig, with allocation, ownership, and fallible I/O made explicit. It is
not a JavaScript API or a claim of full WHATWG conformance.

| Web concept | µWebZockets API | Storage model |
| --- | --- | --- |
| `Request.url` | `req.url()` | Borrowed request target |
| `Headers.get`, `has`, `entries` | `req.headers()` | Read-only view over bounded fields |
| Body `text`, bytes, JSON | `req.text()`, `req.bytes()`, `req.json(T, allocator)` | Borrowed bytes; explicit allocator for parsed JSON |
| Text, HTML, bytes, JSON responses | `res.text()`, `res.html()`, `res.bytes()`, `res.json()`, `res.json_buf()` | Direct bounded write or explicit temporary allocator |
| `Response.redirect` | `res.redirect(location, code)` | Validated `Location`; CR/LF rejected |
| Readable and writable byte streams | `uz.streams.ReadableByteStream`, `res.writable_stream()` | BYOB reads and transport-aware bounded writes |
| `pipeTo` | `uz.streams.pipe_to()` | Caller-owned transfer buffer and deterministic close |

These types are the shared application boundary for HTTP/1.1, HTTP/2, and
HTTP/3. Lower-level methods such as `end_with_headers`, `begin_chunked`, and
`write_chunk` remain available for precise protocol control.

## Standards and compliance

### Protocol coverage

- WebSocket: RFC 6455 and RFC 7692 per-message deflate.
- HTTP/2: bounded RFC 9113 routing and one RFC 8441 WebSocket tunnel per
  connection.
- HTTP/3: bounded RFC 9114 request/response routing. Extended CONNECT,
  WebTransport, push, and application datagrams are helper-only and rejected by
  the live listener.
- HTTP extensions: RFC 10008 `QUERY` routing with syntactic content-type checks.

### Verification

The bundled Autobahn runner executes all 517 selected server cases. The verified
baseline is 514 `OK` and 3 `INFORMATIONAL` results for both protocol and close
behavior. The strict gate accepts all 517 cases, including RFC 7692 groups 12
and 13, with no exclusions.

The h1spec suite, HTTP/3 cross-implementation gate, deterministic fuzz smoke
tests, and OSS-Fuzz compatibility build run in CI. See
[operations.md](operations.md) for the full verification matrix.
