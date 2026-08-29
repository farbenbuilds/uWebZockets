# µWebZockets Codebase

## Scope

µWebZockets is a Zig 0.16.0 HTTP/1.1 and WebSocket server library. It combines
an event-driven POSIX transport, fixed-capacity protocol state, a data-oriented
router, and C libraries for TLS and future transports.

The alpha release makes bounded resource use explicit. Startup allocates one
contiguous connection slab, one WebSocket message region, and one output region.
Network callbacks then reuse those regions without general-purpose allocation.

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
├── src/
│   ├── root.zig              # supported public API
│   ├── core/                 # libxev loop, TCP, pool, context, timer
│   ├── crypto/               # bounded BoringSSL TLS adapter
│   ├── http/                 # strict HTTP/1.1 parser and response writer
│   ├── router/               # fixed-capacity radix router and App API
│   ├── ws/                   # zslay integration, masking, UTF-8, pub/sub
│   ├── quic/                 # internal, fail-closed HTTP/3 stubs
│   └── tests/                # unit and adversarial protocol tests
├── tests/
│   ├── autobahn/             # RFC 6455 target, Deno runner, and config
│   └── h1spec/               # HTTP/1.1 compliance target
├── examples/                 # supported HTTP and WebSocket examples
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
HTTP request accumulator --> strict parser --> radix route
                                      |             |
                                      |             +--> bounded HTTP writer
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
```

The connection pool owns a contiguous `TcpConnection` slab and a separate
activity bitmap. `ConfiguredApp` divides contiguous message and write regions
into one slice per connection. This avoids one allocation per accepted socket
and makes cleanup deterministic. A closed slot is not returned to the freelist
until its close, read, and write completions have all drained, preventing an
old completion from observing a reused connection.

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, bodies, and unsupported expectations. Pipelined bytes
are retained and parsed again after a response completes.

The router is a fixed-capacity runtime radix tree represented by parallel
arrays for segments, child/sibling links, route bits, method handlers, and
WebSocket behaviors. It supports method-specific handlers, HEAD fallback,
OPTIONS, `Allow`, and an `any` fallback. Route strings are borrowed and must
outlive the application.

Response metadata is validated against control-character injection and
ambiguous `Content-Length` or `Transfer-Encoding`. Writes enter a bounded ring
queue and handle partial kernel writes. Producers observe `error.WouldBlock`
instead of causing unbounded memory growth. Chunk headers, bodies, and
terminators are copied into that ring as parts, so no per-connection chunk
scratch allocation or fixed 8 KiB chunk ceiling is needed.

## WebSocket

zslay 0.1.5 validates frame structure and size limits. µWebZockets adds strict
server-side handshake validation, fragmented-message assembly, streaming UTF-8
validation, close-code handling, SIMD unmasking, and bounded writes. Control
frames use a 125-byte inline buffer. Message storage is provided by the owning
application and reused for the connection lifetime. Application message slices
are callback-scoped and outgoing text, control, and close frames are validated
before entering the transport queue.

Pub/sub copies topic names into fixed internal storage, caps subscriptions, and
removes connection references during close. Published message bytes are never
retained after the callback returns.

## TLS and HTTP/3

HTTPS uses BoringSSL TLS 1.3 with an in-memory BIO pair sized to match the
bounded output policy. The adapter validates context creation, propagates
backpressure, performs shutdown, and advertises only HTTP/1.1 through ALPN.

The repository builds lsquic to keep dependency integration tested, but the
removed QUIC adapter did not meet the ownership and transport guarantees of
the public API. Only fail-closed Zig stubs remain: raw callbacks are absent,
`http3_available` is false, and `init_http3` fails with
`error.Http3NotImplemented`.

## Build graph

`build.zig` maps Zig optimization modes to CMake build types and invokes Ninja
for BoringSSL, lsquic, and libdeflate. The `zig-cc` and `zig-c++` wrappers pass
the selected target triple to cross builds. Vendor caches are separated by
target and optimization mode.

The Nix flake pins Nixpkgs 26.05, seeds Zig package dependencies
deterministically, and defines native and musl compile checks. Release archives
contain the µWebZockets, BoringSSL, lsquic, and libdeflate static libraries plus
their license texts.

## Supported and internal API

The supported surface is exported from `src/root.zig`: `App`, `ConfiguredApp`,
`ConfiguredAppWithTimeout`, `Request`, `Response`, `WebSocket`, `WsBehavior`,
`Opcode`, TLS configuration, chunked HTTP helpers, and WebSocket masking. Files
under `src/quic` are internal and must not be imported by consumers.
