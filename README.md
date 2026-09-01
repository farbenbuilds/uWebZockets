<p align="center">
  <img src="misc/uwebzockets_banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

µWebZockets is a Zig 0.16 WebSocket server library with HTTP/1.1, WebSocket,
and optional HTTP/3/QUIC support. It is designed for low-allocation,
event-driven services; production deployments should still validate their own
traffic, limits, TLS configuration, and observability requirements.

## Status and validation

The repository CI covers Zig builds and tests, RFC 6455 behavior, HTTP/3
interop, HTTP/1.1 conformance, deterministic fuzz smoke tests, and an
OSS-Fuzz/ClusterFuzzLite build. The throughput workflow compares the optimized
`hello_world` server with the main branch on the same runner; it is a regression
guard, not a universal performance claim. APIs and integrations may change
until the 1.0 release is finalized.

[![Test](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml)
[![Autobahn Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml)
[![h1spec Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml)
[![Benchmark](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml)

µWebZockets is a bounded-memory, event-driven WebSocket, HTTP/1.1, HTTP/2,
and HTTP/3 server library for Zig 0.16.0. This source tree is preparing version
1.0.0. The request, response, frame
parsing, masking, routing,
and connection I/O paths use fixed-capacity storage after application startup.
BoringSSL provides TLS, libxev drives non-blocking POSIX I/O, zslay 0.1.5
provides the WebSocket frame state machine, and lsquic provides QUIC.

The manifest and C ABI report version `1.0.0`, but a release is not published
until the `v1.0.0` tag completes the publish workflow. Pin an exact source
commit until that tag exists. Only POSIX targets are supported.

## Features

- HTTP/1.1 GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, QUERY, and fallback routes
- Request targets split into path and query slices without allocation
- Exact routes plus bounded `:name` segment and terminal `*name` captures
- Ordered fixed-capacity middleware, context callbacks, and one-shot async
  response tokens for Zig handlers
- Automatic 404, 405 with `Allow`, OPTIONS, HEAD fallback, and `100 Continue`
- Fixed-size request parsing with strict framing and header validation
- Fixed-capacity, backpressure-aware response queues and chunked responses
- RFC 6455 server framing, fragmentation, masking, close handling, and
  streaming UTF-8 validation
- RFC 7692 per-message deflate with strict extension parsing, bounded expansion,
  and mandatory client/server no-context-takeover
- SIMD WebSocket masking with a scalar tail
- Bounded WebSocket messages, frames, subscriptions, and topic ownership
- HTTPS with BoringSSL TLS 1.3 and `h2`/`http/1.1` ALPN
- HTTP/3 request/response routing over lsquic with bounded QPACK, stream,
  body, response, and packet storage
- Live bounded HTTP/2 routing with eight-stream multiplexing, flow control,
  and caller-owned HPACK decoding/encoding storage
- RFC 9220 extended CONNECT validation, push and 0-RTT policy helpers, and
  WebTransport-over-HTTP/3 draft-16 wire primitives
- Contiguous connection pools and per-connection storage selected at compile
  time
- Completion-driven shutdown that drains accept, read, write, close, timer,
  and UDP operations before releasing their slabs
- Versioned C ABI and `include/uWebZockets.h` for HTTP routes, middleware,
  one-shot async responses, WebSocket, TLS, HTTP/3, publish, and lifecycle
  operations
- Centralized unit tests, Google OSS-Fuzz/libFuzzer targets, protocol
  compliance gates, and a versioned HTTP throughput regression contract
- Native GNU/Linux, musl/Linux, and macOS release packages

The bundled Autobahn runner executes all 517 selected server cases. The
verified baseline is 514 `OK` and 3 `INFORMATIONAL` results for both
protocol and close behavior. The strict gate accepts all 517 cases, including
RFC 7692 groups 12 and 13, with no exclusions.

## Requirements

- Zig 0.16.0
- CMake 3.20 or newer
- Ninja
- patch
- A POSIX target: Linux, macOS, FreeBSD, NetBSD, OpenBSD, or DragonFlyBSD
- zlib development headers and a static library
- Recursive git submodules for the repository's h1spec development suite

The Nix flake pins Nixpkgs 26.05 and provides the supported Zig, CMake, Ninja,
patch, Go, Python, Perl, and zlib toolchain on all release architectures.

## Build

```sh
git clone --recurse-submodules https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

The Nix shell also exposes a coherent LLVM sanitizer runtime, matching glibc,
and dynamic linker. Run the complete test graph with ASan, UBSan,
LeakSanitizer, Zig C-UB checks, and frame pointers:

```sh
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
```

Run the separate x86_64 Linux MemorySanitizer dependency-boundary smoke with
origin tracking:

```sh
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
```

Address/undefined sanitizer mode and MemorySanitizer mode are mutually
exclusive. The ASan/UBSan mode runs the centralized test and C ABI graph while
instrumenting the pinned C/C++ libraries and local C shim. The MSan mode
rebuilds those C/C++ components with origin tracking and executes a focused C
dependency-boundary smoke; it does not instrument Zig code or run the complete
C ABI suite. The modes use isolated vendor caches and run as separate CI steps.

Outside Nix, also pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. If
that runtime requires a different glibc than the host, pass the matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths together.
Sanitizer builds are intentionally restricted to native Linux, set coherent
runtime RPATHs, and use a separate vendor cache.

`zig build test` runs the ordinary unit suite from the dedicated
`src/tests/main.zig` root; production modules do not import that suite.
Protocol fuzzing has two layers:

```sh
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe
zig build oss-fuzz-smoke -Doptimize=ReleaseSafe
```

The Smith harness retains HTTP, zslay, extension-negotiation, and HTTP/3
validation coverage. The OSS-Fuzz objects export `LLVMFuzzerTestOneInput` for
HTTP framing, WebSocket masking, and QUIC/WebTransport packet boundaries;
`oss-fuzz-smoke` runs deterministic seeds without libFuzzer. A reusable
ClusterFuzzLite workflow links and executes all three targets with the
OSS-Fuzz ASan/libFuzzer environment on the exact revision under test. This is
an OSS-Fuzz compatibility gate, not a claim of enrollment in the hosted
service; `oss-fuzz/README.md` documents the Zig sanitizer boundary.

Without Nix, install the requirements above and run the same Zig commands. If
zlib is not in the compiler's default search path, pass a prefix containing
`include/` and `lib/libz.a`:

```sh
zig build -Dzlib-prefix=/path/to/zlib-prefix
```

`zig build lib -Doptimize=ReleaseFast` installs the µWebZockets, BoringSSL,
lsquic, and libdeflate static archives under `zig-out/lib`. Applications that
link these archives directly must also link libc, the C++ runtime, zlib, and
the platform networking libraries required by those dependencies.

## Use as a Zig dependency

Until `v1.0.0` is published, pin an exact commit in your repository and
reference that immutable checkout by path. After publication, the tag may be
used instead:

```sh
git submodule add https://github.com/farbenbuilds/uWebZockets.git vendor/uWebZockets
git -C vendor/uWebZockets checkout <full-commit-hash>
git add .gitmodules vendor/uWebZockets
```

```zig
// build.zig.zon
.dependencies = .{
    .uWebZockets = .{ .path = "vendor/uWebZockets" },
},
```

```zig
// build.zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
const uz_module = uz.module("uWebZockets");
exe.root_module.addImport("uWebZockets", uz_module);
```

Commit the Git submodule revision or otherwise pin the directory contents; do
not point a release build at a moving branch. The package manifest fetches
zslay, libxev, BoringSSL, lsquic, ls-qpack, ls-hpack, and libdeflate from
immutable URLs or commits with Zig package hashes, so a downstream path
dependency does not need µWebZockets' vendor submodules.
The public module carries native link metadata, orders dependency builds, and
supplies the C shim through its clean static-library edge. The
`tests/package_consumer` fixture compiles this path-dependency contract in CI
against the release module surface.

## C ABI

The package includes [`include/uWebZockets.h`](include/uWebZockets.h),
and both `zig build install` and `zig build lib` install it as
`zig-out/include/uWebZockets.h` by default.
The ABI uses opaque handles, `uwz_slice` byte views, and the versioned `uwz_error`
integer mapping. `uwz_app_create`, `uwz_app_shutdown`, and
`uwz_app_destroy` make ownership explicit; destroy nulls the caller's handle.
Shutdown requested from a callback is drained by the active `uwz_app_run` call.
Destroying from a callback returns `UWZ_ERROR_INVALID_STATE` and leaves the
handle valid for destruction after the run returns.
The current ABI has fixed capacities of 1,024 connections and 64 copied route
paths. Request fields or parameters needed after a C callback returns must be
copied into caller-owned storage; WebSocket message slices are callback-scoped.

Synchronous and one-shot asynchronous HTTP routes, ordered middleware, borrowed
route parameters, bounded responses, WebSocket callbacks and pub/sub, TLS,
HTTP/3 UDP listening, and lifecycle functions are implemented. Async tokens
are copyable generation-checked values that must be completed exactly once on
the owning event loop.

The C ABI covers the high-level fixed-capacity server operations listed above.
It is not a one-to-one binding for compile-time Zig configuration types or the
low-level `udp`, HTTP/2, HPACK, HTTP/3-extension, and WebTransport helper
modules exported from `src/root.zig`; those surfaces remain Zig-only.

## HTTP example

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(req: *uz.Request, res: *uz.Response) void {
    const name = if (req.query.len == 0) "world" else req.query;
    res.end_with_headers(
        "200 OK",
        "Content-Type: text/plain\r\n",
        name,
    ) catch return;
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(1024).init(init.io);
    defer server.deinit();

    _ = try server.get("/hello", hello);
    try server.listen("0.0.0.0", 3000);
    try server.run();
}
```

Route strings are copied into fixed router storage during registration and may
be temporary or mutable caller buffers. Registration returns
`error.RoutesLocked` after `listen` or `listen_udp` starts. Do not move the
`App` value after listening; event-loop callbacks retain its address.

For incremental HTTP output, call `begin_chunked`, `write_chunk` as needed,
then `end_chunks`. `Request` fields and route-parameter values borrow the
connection's request buffer. They are valid through a synchronous callback or
until an asynchronous response completes; copy them into bounded application
storage for longer work.

## Routing, middleware, and asynchronous handlers

Exact routes remain on the radix fast path. A `:name` segment captures one
nonempty path segment and a terminal `*name` captures the remaining path,
including an empty remainder.
`Request.get_param` reads up to 16 borrowed captures. The router holds at most
64 parameterized patterns, and static routes win over parameter and wildcard
matches.

Malformed patterns, duplicate parameter names, and nonterminal wildcards fail
registration instead of falling back to ambiguous matching.

`App.use` appends at most 32 global middleware callbacks. They run in order and
stop when they return `.stop` or start a response. `route_context` and
`get_context` retain an explicit caller-owned context pointer. `route_async`,
`get_async`, and their context variants receive a generation-checked response
token that completes exactly once. Completion is confined to the owning event
loop; marshal cross-thread results back to that loop. A pending token keeps the
TCP request buffer or HTTP/3 stream from being reused.

## WebSocket example

```zig
const std = @import("std");
const uz = @import("uWebZockets");
fn echo(ws: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    ws.send(message, opcode) catch {
        ws.send_close(1011, "write failed") catch return;
    };
}

pub fn main(init: std.process.Init) !void {
    const max_message_size = 1024 * 1024;
    const write_queue_size = max_message_size + 64 * 1024;
    var server = try uz.ConfiguredApp(
        1024,
        max_message_size,
        write_queue_size,
    ).init(init.io);
    defer server.deinit();

    _ = try server.ws("/echo", .{
        .message = echo,
        .compression = .permessage_deflate,
        .max_frame_size = max_message_size,
        .max_message_size = max_message_size,
    });
    try server.listen("0.0.0.0", 3000);
    try server.run();
}
```

`App` defaults to 16 KiB WebSocket messages. `ConfiguredApp` changes the
compile-time connection count, message capacity, and write-queue capacity.
`send` returns `error.WouldBlock` if bounded output storage is exhausted. Use
the WebSocket `drain` callback and `buffered_amount` to resume producers.
Incoming `message` slices are valid only for the duration of the callback.
Outgoing text and close data are validated; `send_close` closes after the
frame drains, while `terminate` performs an immediate transport close.

Compression is opt-in per WebSocket route. Enabling `.permessage_deflate`
allocates separate bounded receive and send scratch slices per connection
during route registration; message processing itself does not allocate.
Negotiation always selects
`server_no_context_takeover` and `client_no_context_takeover`, accepts window
sizes 9 through 15 for server output and 8 through 15 for client input, and
rejects compressed expansion beyond `max_message_size`.

The default idle timeout is 120 seconds and is refreshed by successful reads
and writes. Use `ConfiguredAppWithTimeout` to select another compile-time
timeout, or zero to disable idle sweeping:

```zig
const Server = uz.ConfiguredAppWithTimeout(
    1024,
    1024 * 1024,
    1024 * 1024 + 64 * 1024,
    300_000,
);
```

## HTTPS

Use `init_https` with PEM certificate and private-key paths:

```zig
var server = try uz.App(1024).init_https(
    init.io,
    "certs/cert.pem",
    "certs/key.pem",
);
```

The server negotiates TLS 1.3 and prefers ALPN `h2`, then `http/1.1`.
Plaintext listeners also detect the HTTP/2 prior-knowledge preface; h2c Upgrade
is not required.

## HTTP/2 and HPACK

`uz.http2` exposes strict frame headers, peer settings, a fixed-capacity
structure-of-arrays stream slab, and a server-side connection state machine.
It validates the client preface, frame sizes and sequencing, stream lifecycle,
settings, and flow-control windows. `uz.http2_hpack` exposes a bounded HPACK
decoder/encoder with caller-owned dynamic-table, header, and byte storage,
including Huffman and pseudo-header validation.

`App.listen` dispatches plaintext prior-knowledge HTTP/2, while `init_https`
selects it through ALPN. Each TCP connection embeds an eight-stream request,
body, response, and async-token slab. SETTINGS, PING, GOAWAY, RST_STREAM,
trailers, partial DATA, and connection/stream flow control are handled without
dynamic allocation on the data path. RFC 8441 WebSocket tunneling is not
advertised; WebSockets remain an HTTP/1.1 upgrade feature.

## HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises `h2` and
`http/1.1`, while QUIC advertises only `h3`. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`:

```zig
var server = try uz.App(128).init_http3(
    init.io,
    "certs/cert.pem",
    "certs/key.pem",
);
defer server.deinit();

_ = try server.get("/", hello);
try server.listen_udp("0.0.0.0", 8443);
try server.run();
```

The adapter decodes HTTP/3 pseudo-headers directly into the existing `Request`
shape and writes structured QPACK response headers without converting through
HTTP/1.1 text. QUIC connections, streams, header sets, packet buffers, request
bodies, and responses come from startup-allocated contiguous pools. The `App`
value must remain at a stable address after `listen_udp`. The live listener
explicitly rejects TLS 0-RTT so replayable application requests never reach a
handler; pure early-data policy helpers remain available for a future backend
that exposes per-request early-data state.

The cross-implementation gate uses pinned curl/ngtcp2 and aioquic clients to
verify the normal request path, a valid trailing field section, and malformed
pseudo-header/connection-field rejection with `H3_MESSAGE_ERROR`. Malformed
and healthy sibling streams share one connection so connection-wide aborts
fail the gate. `uz.http3_extensions` supplies RFC
9220 extended CONNECT validation, push bookkeeping, and replay-aware early-data
policy. `uz.webtransport`
supplies bounded draft-16 settings, CONNECT/origin checks, sessions, stream and
datagram association, capsules, flow control, and error mapping.

Those extension modules are not connected to the live lsquic listener. The
pinned backend exposes raw datagrams but not the complete extended CONNECT,
push, outgoing unidirectional stream, or reset-at interfaces they require.
WebTransport therefore models draft-16 only and is not a claim of deployed
WebTransport interoperability. RFC 10008 defines the separate HTTP `QUERY`
method, which is supported by both routing APIs and rejects a missing or
syntactically invalid `Content-Type`; resource-specific media-type and content
consistency remain the route handler's policy.

## Performance contract

The versioned [`http-throughput-v1`](benchmarks/http_throughput_guarantee.md)
contract compares three same-runner `wrk` samples for a pull request and its
base revision. The candidate median must remain at least 90 percent of the
baseline median. Scheduled and manual mainline runs append structured records
and raw evidence to the `benchmark-data` branch. This is a relative regression
guarantee; it is not an absolute requests-per-second claim across different
hardware or toolchain cohorts.

## Capacity and protocol limits

The defaults are deliberately finite:

| Resource | Limit |
| --- | ---: |
| Request line | 8 KiB |
| HTTP headers | 16 KiB total, 64 fields |
| HTTP request body | 16 KiB |
| Routes | 256 radix nodes |
| Parameterized routes | 64 patterns, 16 captures per request |
| Middleware | 32 callbacks |
| Route path | 2 KiB |
| WebSocket message | 16 KiB with `App` |
| WebSocket control payload | 125 bytes |
| HTTP/3 decoded headers | 16 KiB total, 64 fields |
| HTTP/3 request body | 16 KiB |
| HTTP/3 response metadata | 4 KiB, 64 fields |
| HTTP/3 response body | configured write-queue capacity |
| QUIC UDP payload | 2 KiB |
| QUIC connections and active streams | configured connection capacity |
| HTTP/2 active streams | caller-selected compile-time slab capacity |
| HPACK table, fields, and decoded bytes | caller-owned capacities |
| C ABI | 1,024 connections, 64 copied route paths |
| Write queue | fixed per connection |
| Idle timeout | 120 seconds by default |

Oversized or ambiguous input is rejected rather than expanded dynamically.

## Current limitations

- HTTP/2 WebSocket extended CONNECT is not advertised; WebSocket upgrades use
  HTTP/1.1 because message/compression state is connection-owned.
- The live HTTP/3 server handles request/response routing and passes the
  cross-implementation gate. It rejects TLS 0-RTT. Extended CONNECT, server
  push, and WebTransport remain helper modules rather than live features.
- WebTransport follows draft-ietf-webtrans-http3-16 wire semantics; RFC 10008
  is the separately implemented HTTP `QUERY` method.
- Per-message deflate deliberately uses no-context-takeover. An offered 8-bit
  server compression window is declined because zlib cannot emit it reliably;
  8-bit client compression is accepted and decoded within the configured
  output bound.
- Windows is unsupported by design. The configured publish and CI matrix
  covers Linux and macOS; BSD targets are accepted by the build but are not
  publish targets.
- Zig and C route parameters, middleware, and one-shot async tokens are
  implemented with fixed capacities and event-loop-confined lifetimes.
- The versioned [`http-throughput-v1`](benchmarks/http_throughput_guarantee.md)
  guarantee is relative to a same-runner baseline, not an absolute capacity
  guarantee across different hardware cohorts.

See [CHANGELOG.md](CHANGELOG.md), [CODEBASE.md](CODEBASE.md), and
[CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) for release details, architecture, and
verification. Security reports must follow [SECURITY.md](SECURITY.md).

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
