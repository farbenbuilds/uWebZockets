# µWebZockets Codebase

## Scope

µWebZockets 1.1.9 is a Zig 0.16.0 HTTP/1.1, HTTP/2, WebSocket, and HTTP/3
server library with bounded HPACK protocol storage. It combines an
event-driven cross-platform transport (POSIX and Windows IOCP), fixed-capacity
protocol state, a data-oriented router, and C libraries for TLS, compression, and QUIC.

The current design makes bounded resource use explicit. Startup allocates one
contiguous slab that holds the connection pool, per-connection HTTP/1.1 request
buffers, WebSocket message regions, response write queues, and optional
compression scratch. `ServerConfig` presets and `Server.builder` compute that
slab from named limits before allocating it once. The `max_body_size` limit
sizes the HTTP/1.1 request buffers; HTTP/2 stream bodies and HTTP/3 request
bodies keep their compiled 16 KiB transport slabs. Network callbacks then reuse
those regions without general-purpose allocation. WebSocket compression and
HTTP/3 allocate their fixed slabs when the feature is configured, before
listening begins. Route arrays are immutable after either listener starts, so
callbacks never observe a structural mutation.

Thread-per-core cluster workers each own one such slab, run one libxev loop,
and coordinate only through lock-free sequence rings. Physical-core affinity,
`SO_REUSEPORT`, `TCP_DEFER_ACCEPT`, and `TCP_QUICKACK` are applied during
startup and accept; no mutex or spinlock remains on the steady-state I/O path.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are expressed as small functions with explicit input
   and output state. Stateful I/O remains localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. Non-blocking I/O (epoll, io_uring, kqueue, and IOCP via libxev) drive callbacks.
   CMake and Ninja build the vendored C and C++ libraries with Zig compiler wrappers.
5. WebSocket masking operates on native SIMD vectors before handling the scalar
   tail.

## Type readability

Type surfaces are named, explicit, and flat. Union payloads, callback fields,
and partial-configuration records are declared once with a one-line doc comment
instead of appearing inline: the HTTP/2 `Event` union uses `HeadersEvent`,
`DataEvent`, `GoAwayEvent`, `StreamResetEvent`, `WindowUpdateEvent`, and
`DiscardedDataEvent`; `Response` fields use `Http2EndFn`, `Http3WriteFn`, and
`AsyncCompleteFn`; `WsBehavior` uses the named `Ws*Callback` aliases;
`ServerConfig.with` takes the explicit `ServerConfig.Overrides` record instead
of reflection over `anytype`; transport callback fields use `CloseCallback` and
`TickCallback`. Aliases are zero-cost and additive: exported names, field
order, defaults, wire behavior, and capacities are unchanged. Comptime
factories remain for capacity and platform specialization only.

## Layout

```text
uWebZockets/
├── build.zig                 # thin versioned graph injector
├── build.zig.zon             # Zig 0.16 package manifest
├── builds/
│   ├── orchestrator.zig        # target selection and aggregate steps
│   ├── vendor.zig              # CMake/Ninja C and C++ dependencies
│   ├── sanitizers.zig          # ASan/MSan runtime configuration
│   ├── testing.zig             # unit, C ABI, h1spec, and Autobahn steps
│   ├── fuzzing.zig             # deterministic and OSS-Fuzz targets
│   ├── examples.zig            # example executables and run steps
│   └── targets/
│       ├── native.zig         # TCP, io_uring/IOCP, TLS, and QUIC graph
│       ├── wasm.zig           # freestanding and WASI edge graph
│       └── ebpf.zig           # XDP redirect and latency histogram objects
├── flake.nix                 # native GNU/musl and macOS packages
├── docs/                     # architecture, memory model, protocols, operations
├── include/uWebZockets.h     # versioned C ABI declarations
├── src/
│   ├── root.zig              # supported public API
│   ├── version.zig           # single Zig source of truth for the release version
│   ├── c_api.zig             # exported C ABI facade (handlers in c_api/)
│   ├── core/                 # libxev I/O plus transport-neutral protocol core
│   │   ├── affinity.zig      # physical-core selection and thread pinning
│   │   ├── ktls.zig          # Linux kTLS and zero-copy file transfer
│   │   └── udp.zig           # completion-owned UDP/QUIC transport
│   ├── crypto/               # bounded BoringSSL TLS and Web Crypto
│   ├── edge/                 # WinterCG-compatible edge surface
│   ├── ffi/                  # bounded generation-checked shared memory
│   ├── http/                 # strict HTTP/1.1 parser and response writer
│   ├── http2/                # bounded frames, stream slab, and HPACK
│   ├── router/               # fixed-capacity radix router, App API, config, builder
│   ├── rpc/                  # bounded JSON-RPC registry and dispatcher
│   ├── ws/                   # streams, pure backpressure, framing, pub/sub
│   ├── observability/        # Prometheus registry and pinned eBPF histogram reader
│   ├── xdp/                  # AF_XDP UMEM rings, TX path, and bypass policy
│   ├── quic/                 # lsquic HTTP/3, WebTransport, and datagram ring
│   └── tests/                # centralized ordinary Zig unit tests
├── fuzz/                     # libFuzzer ABI targets and local smoke drivers
├── oss-fuzz/                 # Google OSS-Fuzz build and corpus metadata
├── tests/
│   ├── autobahn/             # RFC 6455 target, Deno runner, and config
│   └── h1spec/               # HTTP/1.1 compliance target
├── examples/                 # HTTP, WebSocket, JSON-RPC, builder, and cluster examples
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
activity bitmap. `src/router/config.zig` sizes one larger contiguous region:
pool state, request buffers, WebSocket message storage, write queues, and
optional compression scratch. `ConfiguredApp` and the `Server.builder` carve
per-connection slices from that region. This avoids one allocation per accepted
socket and makes cleanup deterministic. A closed slot is not returned to the
freelist until its close, read, and write completions have all drained,
preventing an old completion from observing a reused connection.

Shutdown reverses that ownership graph. The application first rejects new
work, stops recurring timers, cancels accept/read/write/UDP completions, closes
descriptors through libxev, and runs the loop until every callback is disarmed.
`src/core/udp.zig` owns its fixed receive buffer, QUIC engine, read, timer,
cancellation, and close completions as one unit. Only after both transports
drain are TLS state, QUIC state, the loop, and contiguous slabs released.

The registration-to-handler map for native callbacks is in
[docs/callback_lifecycle.md](docs/callback_lifecycle.md).

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

## JSON-RPC

`src/rpc/json_rpc.zig` implements transport-independent JSON-RPC 2.0 single
requests, notifications, and batches. `src/rpc/http.zig` adapts it to the
existing POST router. Procedure metadata is stored in
parallel fixed-capacity arrays, method bytes are copied into contiguous owned
storage, and an open-addressed index avoids allocation and pointer chasing on
dispatch. Registration is sealed at mount time so event-loop callbacks only
read the registry.

The protocol scanner borrows method parameters and IDs from the bounded HTTP
request body, while escaped member and method names use fixed local scratch.
Batches take a bounded syntax-only pass before dispatch so a malformed tail
cannot follow an already-committed procedure side effect. The pure dispatcher
accepts caller-owned output storage; the HTTP adapter uses one service-owned
bounded buffer and copies the final response into the connection's existing
write queue. Procedure handlers may parse parameters with an explicit
allocator, emit typed JSON results, or return standard and application-defined
faults. Each mounted service instance belongs to one event loop, so cluster
workers keep independent response buffers.

## WebSocket

zslay 0.2.0 validates frame structure and size limits and provides the pure
close-payload validator. µWebZockets adds strict server-side handshake
validation, fragmented-message assembly, streaming UTF-8 validation, close-code
handling, SIMD unmasking, and bounded writes. Control frames use a 125-byte
inline buffer. Message storage is provided by the owning
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
tokens. RFC 8441 WebSocket tunneling is supported via extended CONNECT. The
parser and message buffers are connection-owned, so one HTTP/2 connection may
carry one active WebSocket tunnel alongside ordinary request streams.

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

Windows QUIC datagrams are received through libxev IOCP UDP completions and
sent with the Winsock `WSASendTo` adapter. The native Windows workflow compiles
this path, while runtime interoperability remains Tier 2.

## Build graph

`src/version.zig` is the single Zig source of truth for the release version;
the root `build.zig` derives its `std.SemanticVersion` from it and delegates
directly to `builds/orchestrator.zig`. `scripts/bump_version.sh` rewrites the
package manifest, the C ABI macros, the C/C++ tests, the documentation
headers, and the changelog skeleton, and `scripts/check_release_version.sh`
fails the lint workflow if any copy drifts. Focused modules map Zig optimization modes to CMake
build types and invoke Ninja for BoringSSL, lsquic, and libdeflate. The
`zig-cc` and `zig-c++` wrappers pass
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
surface also includes `WsCompression`, fixed-capacity `json_rpc`,
completion-driven `udp`, bounded
`http2`, `http2_hpack`, `http3_extensions`, `webtransport`, `http3_available`,
`WebSocketStream`, BYOB and compression streams, abort controllers, Web Crypto,
shared memory, kTLS, AF_XDP, and the transport-independent protocol core.
It also exposes `init_http3` and `listen_udp` through the application type. Live lsquic
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
