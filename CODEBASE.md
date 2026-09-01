# µWebZockets Codebase

## Scope

µWebZockets 1.0.0 is a Zig 0.16.0 HTTP/1.1, HTTP/2, WebSocket, and HTTP/3
server library with bounded HPACK protocol storage. It combines an
event-driven POSIX transport, fixed-capacity protocol state, a data-oriented
router, and C libraries for TLS, compression, and QUIC.

The 1.0.0 design makes bounded resource use explicit. Startup allocates one
contiguous connection slab, one WebSocket message region, and one output region.
Network callbacks then reuse those regions without general-purpose allocation.
WebSocket compression and HTTP/3 allocate their fixed slabs when the feature is
configured, before listening begins. Route arrays are immutable after either
listener starts, so callbacks never observe a structural mutation.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are expressed as small functions with explicit input
   and output state. Stateful I/O remains localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. POSIX non-blocking I/O and libxev drive callbacks. CMake and Ninja build the
   vendored C and C++ libraries with Zig compiler wrappers.
5. WebSocket masking operates on native SIMD vectors before handling the scalar
   tail.

## Layout

```text
uWebZockets/
├── build.zig                 # Zig and C/C++ build graph
├── build.zig.zon             # Zig 0.16 package manifest
├── flake.nix                 # native GNU/musl and macOS packages
├── include/uWebZockets.h     # versioned C ABI declarations
├── src/
│   ├── root.zig              # supported public API
│   ├── c_api.zig             # exported C ABI implementation
│   ├── udp.zig               # completion-owned UDP/QUIC transport
│   ├── core/                 # libxev loop, TCP, pool, context, timer
│   ├── crypto/               # bounded BoringSSL TLS adapter
│   ├── http/                 # strict HTTP/1.1 parser and response writer
│   ├── http2/                # bounded frames, stream slab, and HPACK
│   ├── router/               # fixed-capacity radix router and App API
│   ├── ws/                   # zslay integration, masking, UTF-8, pub/sub
│   ├── quic/                 # lsquic HTTP/3 and extension primitives
│   └── tests/                # centralized ordinary Zig unit tests
├── fuzz/                     # libFuzzer ABI targets and local smoke drivers
├── oss-fuzz/                 # Google OSS-Fuzz build and corpus metadata
├── tests/
│   ├── autobahn/             # RFC 6455 target, Deno runner, and config
│   └── h1spec/               # HTTP/1.1 compliance target
├── examples/                 # HTTP/1.1, WebSocket, and HTTP/3 examples
└── vendor/                   # pinned C/C++ and compliance submodules
```

## Runtime data flow

```text
libxev accept/read
      |
      v
fixed connection slot ----> optional bounded TLS BIO pair
      |
      v
HTTP request accumulator --> strict parser --> middleware --> radix route
                                      |                       |
                                      |                       +--> bounded HTTP writer
                                      |                       +--> one-shot async token
                                      v
                             WebSocket upgrade
                                      |
                                      v
                          zslay frame state machine
                                      |
                     SIMD unmask + streaming UTF-8
                                      |
                                      v
                         callback / bounded pub-sub

UDP read/timer --> lsquic engine --> bounded QPACK header set --> same router
                                   |                           |
                                   v                           v
                            bounded body slab          structured H3 response
```

The connection pool owns a contiguous `TcpConnection` slab and a separate
activity bitmap. `ConfiguredApp` divides contiguous message and write regions
into one slice per connection. This avoids one allocation per accepted socket
and makes cleanup deterministic. A closed slot is not returned to the freelist
until its close, read, and write completions have all drained, preventing an
old completion from observing a reused connection.

Shutdown reverses that ownership graph. The application first rejects new
work, stops recurring timers, cancels accept/read/write/UDP completions, closes
descriptors through libxev, and runs the loop until every callback is disarmed.
`src/udp.zig` owns its fixed receive buffer, QUIC engine, read, timer,
cancellation, and close completions as one unit. Only after both transports
drain are TLS state, QUIC state, the loop, and contiguous slabs released.

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, bodies, and unsupported expectations. Pipelined bytes
are retained and parsed again after a response completes.

The router is a fixed-capacity runtime radix tree represented by parallel
arrays for segments, child/sibling links, route bits, method handlers, and
WebSocket behaviors. Exact routes retain the radix fast path. Up to 64 pattern
routes accept `:name` for one nonempty segment and a terminal `*name` for the
remaining path, including an empty remainder. A request owns 16 borrowed
capture slots and exposes them
through `Request.get_param`. Static specificity wins over parameter and
wildcard matches; malformed patterns and duplicate names fail registration.

Up to 32 global middleware callbacks execute in registration order and stop
explicitly or when a response starts. Routes can use the original synchronous
callback, an explicit context pointer, or a generation-checked asynchronous
token. A pending token prevents request-buffer or HTTP/3 stream reuse and can
complete exactly once on its owning event loop. The router also supports HEAD
fallback, OPTIONS, `Allow`, and an `any` fallback. Route strings and callback
contexts have different ownership: route strings are copied during
registration, while callback contexts remain borrowed and must outlive the
application.

Response metadata is validated against control-character injection and
ambiguous `Content-Length` or `Transfer-Encoding`. Writes enter a bounded ring
queue and handle partial kernel writes. A fully drained ring normalizes its head
to keep the next logical write contiguous instead of creating a delayed-ACK
wrap split. Producers observe `error.WouldBlock` instead of causing unbounded
memory growth. Chunk headers, bodies, and terminators are copied into that ring
as parts, so no per-connection chunk scratch allocation or fixed 8 KiB chunk
ceiling is needed.

## WebSocket

zslay 0.1.5 validates frame structure and size limits. µWebZockets adds strict
server-side handshake validation, fragmented-message assembly, streaming UTF-8
validation, close-code handling, SIMD unmasking, and bounded writes. Control
frames use a 125-byte inline buffer. Message storage is provided by the owning
application and reused for the connection lifetime. Application message slices
are callback-scoped and outgoing text, control, and close frames are validated
before entering the transport queue.

RFC 7692 is opt-in through `WsBehavior.compression`. Extension negotiation is a
pure bounded parser that ignores malformed alternatives independently and
always selects client/server no-context-takeover. Full-window messages use
libdeflate; negotiated 9-14 bit server windows use preinitialized zlib streams
backed by fixed arenas. Incoming 8-15 bit client windows are decoded by the
bounded libdeflate path. Compressed input and decompressed output are capped by
per-connection receive scratch, send scratch, and message slices, so expansion
never causes a hot-path allocation and an outbound callback cannot corrupt an
in-progress compressed receive.

Pub/sub copies topic names into fixed internal storage, caps subscriptions, and
removes connection references during close. Published message bytes are never
retained after the callback returns.

## HTTP/2 and HPACK

`src/http2/connection.zig` provides a server-side frame state machine with a
fixed-capacity structure-of-arrays stream slab. It validates the client
preface, frame sizes and stream identifiers, CONTINUATION sequencing, padding,
SETTINGS, connection and stream flow-control windows, resets, ping, and GOAWAY.
Unknown extension frames are ignored according to HTTP/2 rules, while illegal
client push and state transitions fail closed.

`src/http2/hpack.zig` decodes HPACK requests and encodes responses into
caller-owned header, byte, entry, and dynamic-table storage. Integer and
Huffman decoding, table-size changes, pseudo-header ordering, field names,
connection-specific metadata, and header-list limits are checked before
dispatch. No HTTP/2 parser input is retained after its caller storage is
reused.

`src/core/tcp.zig` embeds one eight-stream server session per connection and
routes decoded requests through the same middleware and sync/async handlers as
HTTP/1.1. Plaintext sockets recognize the prior-knowledge preface; TLS prefers
ALPN `h2` and falls back to `http/1.1`. Peer resets invalidate retained async
tokens. RFC 8441 WebSocket tunneling is not advertised.

## TLS, UDP, and HTTP/3

HTTPS uses BoringSSL TLS 1.3 with an in-memory BIO pair sized to match the
bounded output policy. The adapter validates context creation, propagates
backpressure, performs shutdown, and prefers HTTP/2 through ALPN.

`init_http3` creates transport-isolated TLS 1.3 contexts: the TCP context
advertises `h2` and `http/1.1`, and the QUIC context advertises only `h3`.
`listen_udp` constructs the completion-driven UDP transport and lsquic engine
in place only after the `App` has a stable address. The engine uses contiguous
freelist pools for streams, header sets, and outgoing packets, plus parallel
byte regions for decoded QPACK data, request bodies, response headers, and
response bodies. Pool capacity is the configured connection count; packet
capacity is
`max(16, connections * 4)`.

The header decoder validates pseudo-header ordering and uniqueness, lowercase
HTTP/3 names, URI targets, authority/Host agreement, connection-specific
fields, and content-length. It fills the existing `Request` directly rather
than producing temporary HTTP/1.1 text. Responses reuse the public `Response`
API and emit structured QPACK headers while preserving partial stream writes.
The QUIC TLS context explicitly disables 0-RTT, so replayable application data
is rejected before route dispatch.
QUIC global initialization is reference-counted under a small atomic lock. The
pinned curl/ngtcp2 and aioquic gate verifies a successful request, a valid
trailing field section, and `H3_MESSAGE_ERROR` rejection of malformed headers
while a healthy sibling stream completes on the same connection. Server push
and WebTransport are deliberately excluded.

`http3_extensions` exposes pure validators and bounded bookkeeping for RFC
9220 WebSocket extended CONNECT, server push IDs, and replay-aware early-data
policy. `webtransport` exposes draft-16 settings, CONNECT/origin checks,
sessions, stream and datagram association, capsules, flow control, and error
mapping. The pinned lsquic backend advertises only raw datagrams from the
required capability set, so these helpers are not connected to the live
HTTP/3 listener. The WebTransport constants model
draft-ietf-webtrans-http3-16 and do not claim live interoperability. RFC 10008
is the separate HTTP `QUERY` method supported by the router. All live
transports reject QUERY requests without a syntactically valid `Content-Type`;
the selected route enforces resource-specific media-type and content rules.

## Build graph

`build.zig` maps Zig optimization modes to CMake build types and invokes Ninja
for BoringSSL, lsquic, and libdeflate. The `zig-cc` and `zig-c++` wrappers pass
the selected target triple to cross builds. Vendor caches are separated by
target and optimization mode. Sanitizer mode adds another isolated cache,
instruments BoringSSL, lsquic, libdeflate, and the local C shim with ASan/UBSan,
enables Zig's full C-UB checks, and preserves frame pointers. A mutually
exclusive x86_64 Linux MemorySanitizer mode rebuilds the pinned C/C++ graph
and local C shim with origin tracking in a separate cache, then runs a focused
C dependency-boundary smoke. It does not instrument Zig code or execute the
complete C ABI test graph.

The Nix flake pins Nixpkgs 26.05, seeds Zig package dependencies
deterministically, and defines native and musl compile checks. `build.zig.zon`
pins zslay, libxev, BoringSSL, lsquic, ls-qpack, ls-hpack, and libdeflate by
immutable URL or commit plus Zig package hash. A downstream project can pin an
exact checkout at a local path without inheriting the repository's vendor
submodules. Release archives contain the µWebZockets, BoringSSL, lsquic, and
libdeflate static libraries, `uWebZockets.h`, and their license texts.
`tests/package_consumer` imports the public module from a pinned local path in
CI. That module carries native link metadata and a clean static-library edge
that orders vendor builds without nesting dependency archives. The fixture
catches package-root and exported-name drift.
The build rejects any non-object member in the µWebZockets static archive.

Unit tests live only under `src/tests/`; `src/tests/main.zig` imports every
test file for `zig build test`. Its `fuzz_main.zig` Smith corpus also serves as
the dedicated root for extended `zig build fuzz` runs. Three
`LLVMFuzzerTestOneInput` targets cover HTTP framing, WebSocket masking, and
QUIC/WebTransport packet boundaries. `oss-fuzz/build.sh` links them with the
Google-provided fuzzing engine, while `zig build oss-fuzz-smoke` exercises
fixed local seeds. The reusable ClusterFuzzLite gate runs the OSS-Fuzz builder,
bad-build validation, and bounded execution for all three targets without
assuming hosted-service enrollment. It advertises address builds only: Zig
objects carry sanitizer coverage and `ReleaseSafe` checks, while the separate
library sanitizer matrix instruments the C/C++ graph with ASan/UBSan/MSan.

## Supported and internal API

The Zig surface exported from `src/root.zig` includes `App`, `ConfiguredApp`,
`ConfiguredAppWithTimeout`, `Request`, `Response`, `WebSocket`, `WsBehavior`,
`Opcode`, TLS configuration, chunked HTTP helpers, and WebSocket masking. The
surface also includes `WsCompression`, completion-driven `udp`, bounded
`http2`, `http2_hpack`, `http3_extensions`, `webtransport`, `http3_available`,
`init_http3`, and `listen_udp` through the application type. Live lsquic
engine, stream, packet, and QPACK callbacks remain internal.

The C ABI is declared by `include/uWebZockets.h` and implemented by
`src/c_api.zig`. It provides versioned opaque handles, versioned integer error
codes, explicit create/shutdown/destroy, synchronous and one-shot asynchronous
HTTP, ordered middleware, borrowed route parameters, bounded response,
WebSocket, TLS, HTTP/3, and publish operations. The ABI uses fixed capacities
of 1,024 connections, 64 copied route paths, and 32 middleware callbacks.
Async response tokens carry a generation and can complete exactly once on the
owning event loop.
This is a high-level server ABI rather than a one-to-one projection of the Zig
surface. Compile-time application configuration and the low-level `udp`,
HTTP/2, HPACK, HTTP/3-extension, and WebTransport helpers remain Zig-only.
