<p align="center">
  <img src="misc/uwebzockets_banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

µWebZockets is a type-safe, transport-agnostic server framework for Zig 0.16.0.
It gives HTTP/1.1, HTTP/2, HTTP/3, WebSocket, and JSON-RPC applications one
pragmatic API backed by fixed-capacity, event-driven data paths.

The project favors explicit ownership and compile-time configuration over
hidden allocation. Request, response, routing, framing, and connection storage
remain bounded after startup.

Start with [HTTP](#http-example), [JSON-RPC](#json-rpc), or
[WebSocket](#websocket-example). See [Build](#build) for the full toolchain,
[C ABI](#c-abi) for non-Zig callers, and
[capacity limits](#capacity-and-protocol-limits) before production deployment.

## Quick start

With Nix installed, the shortest path to a running server is:

```sh
git clone --recurse-submodules https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
zig build hello_world -Doptimize=ReleaseSafe
```

In another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The `hello_world` build step compiles and starts the example on port 3000. For
a reusable application, add µWebZockets as a [Zig dependency](#use-as-a-zig-dependency)
and register handlers with `App` as shown below.

## Design goals

- **Type-safe:** typed handlers, native Zig errors, and compile-time capacities
  make contracts visible to the compiler.
- **Transport-agnostic:** the same `Request`, `Response`, router, and middleware
  work across HTTP/1.1, HTTP/2, and HTTP/3. JSON-RPC can also dispatch without
  HTTP.
- **Pragmatic:** common operations have direct helpers while lower-level APIs
  remain available for custom status, headers, streaming, and decoding.
- **Predictable:** hot paths use fixed storage, bounded queues, and explicit
  backpressure instead of dynamic overflow fallbacks.
- **Web-standard vocabulary:** `Request`, `Response`, `Headers`, body helpers,
  redirects, and byte streams follow familiar Fetch and Streams concepts where
  they map cleanly to Zig.

## Project status

The repository CI covers Zig builds and tests, RFC 6455 behavior, HTTP/3
interop, HTTP/1.1 conformance, deterministic fuzz smoke tests, and an
OSS-Fuzz/ClusterFuzzLite build. The throughput workflow compares the optimized
`hello_world` server with the main branch on the same runner; it is a regression
guard, not a universal performance claim. Released tags provide stable
snapshots, and the current source tree may include unreleased changes.

[![Test](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/test.yml)
[![Windows Build](https://github.com/farbenbuilds/uWebZockets/actions/workflows/windows.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/windows.yml)
[![Autobahn Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/autobahn_compliance.yml)
[![h1spec Compliance](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/h1spec_compliance.yml)
[![Benchmark](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml/badge.svg)](https://github.com/farbenbuilds/uWebZockets/actions/workflows/benchmark.yml)

BoringSSL provides TLS, libxev drives non-blocking I/O, zslay 0.1.5 provides the
WebSocket frame state machine, and lsquic provides QUIC. Use a released tag or
pin an exact source commit. Platform verification tiers are documented below.

## Feature map

| Area | Included |
| --- | --- |
| HTTP | GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, QUERY, fallback routes, strict framing, automatic 404/405/OPTIONS, and `100 Continue` |
| Routing | Exact paths, bounded `:name` and terminal `*name` captures, ordered middleware, explicit contexts, and one-shot async responses |
| Web APIs | Fetch-inspired request bodies and headers, response helpers, redirects, BYOB reads, writable byte streams, SSE, CORS, and security headers |
| Application helpers | Bounded static assets, multipart iteration, signed cookies and sessions, compile-time JSON constraints, and OpenAPI 3.1 |
| JSON-RPC | Typed and low-level procedures, explicit context, notifications, batches, standard errors, and transport-neutral dispatch |
| WebSocket | RFC 6455, RFC 7692, fragmentation, streaming UTF-8 validation, SIMD masking, backpressure, pub/sub, and heartbeat sweeps |
| Transports | Plaintext HTTP/1.1 and HTTP/2, BoringSSL TLS 1.3 with ALPN, and bounded HTTP/3 over lsquic |
| Runtime | Contiguous connection pools, fixed response queues, thread-per-core clusters, and completion-driven shutdown |
| Interop | Versioned C ABI for server lifecycle, HTTP, async responses, WebSocket, TLS, HTTP/3, and publish operations |
| Verification | Central tests, protocol conformance, fuzz targets, sanitizers, and a versioned throughput regression contract |

The bundled Autobahn runner executes all 517 selected server cases. The
verified baseline is 514 `OK` and 3 `INFORMATIONAL` results for both
protocol and close behavior. The strict gate accepts all 517 cases, including
RFC 7692 groups 12 and 13, with no exclusions.

## Requirements

- Zig 0.16.0
- CMake 3.20 or newer
- Ninja
- patch
- A build target: Linux, macOS, FreeBSD, NetBSD, OpenBSD, DragonFlyBSD, or Windows
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

Windows builds require a MinGW static zlib prefix. The native Windows CI uses
the pinned manifest under `scripts/windows`, the `x64-mingw-static` triplet,
and the following PowerShell flow:

```powershell
$zlib = "$env:TEMP\uwebzockets-zlib"
.\scripts\windows\prepare_zlib.ps1 -OutputDirectory $zlib
zig build test-compile -Dtarget=x86_64-windows-gnu "-Dzlib-prefix=$zlib" `
  -Doptimize=ReleaseSafe --summary all
zig build lib -Dtarget=x86_64-windows-gnu "-Dzlib-prefix=$zlib" `
  -Doptimize=ReleaseFast --summary all
```

Other cross-target builds must pass a zlib prefix built for the selected
target; the host `UWEBZOCKETS_ZLIB_PREFIX` is deliberately ignored for foreign
targets:

```sh
zig build lib -Dtarget=x86_64-windows-gnu \
  -Dzlib-prefix=/path/to/windows-zlib-prefix
```

`zig build lib -Doptimize=ReleaseFast` installs the µWebZockets, BoringSSL,
lsquic, and libdeflate static archives under `zig-out/lib`. Applications that
link these archives directly must also link libc, the C++ runtime, zlib, and
the platform networking libraries required by those dependencies (on Windows:
`ws2_32`, `mswsock`, `crypt32`, and `advapi32`).

## Use as a Zig dependency

### Zig package manager

From the consuming project, fetch an immutable release tag or commit:

```sh
zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag-or-commit>'
```

This adds the package to `build.zig.zon` under the `uWebZockets` name. Import it
from `build.zig`:

```zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
const uz_module = uz.module("uWebZockets");
exe.root_module.addImport("uWebZockets", uz_module);
```

Pin a tag or full commit rather than a moving branch so dependency resolution
remains reproducible.

### Local path dependency

For local development changes, reference an immutable checkout by path:

```sh
git submodule add https://github.com/farbenbuilds/uWebZockets.git vendor/uWebZockets
git -C vendor/uWebZockets checkout <release-tag-or-full-commit-hash>
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

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("Hello from \u{b5}WebZockets! Zero allocation achieved.") catch return;
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

Integration code may attach borrowed `extra_param_*` or `extra_header_*` slices
when adapting a different parser. Request lookup and iteration include the
paired portion of those slices without allocating. The built-in parsers do not
populate them or expand their fixed capacities dynamically.

Malformed patterns, duplicate parameter names, and nonterminal wildcards fail
registration instead of falling back to ambiguous matching.

`App.use` appends at most 32 global middleware callbacks. They run in order and
stop when they return `.stop` or start a response. `route_context` and
`get_context` retain an explicit caller-owned context pointer. `route_async`,
`get_async`, and their context variants receive a generation-checked response
token that completes exactly once. Completion is confined to the owning event
loop; marshal cross-thread results back to that loop. A pending token keeps the
TCP request buffer or HTTP/3 stream from being reused.

Request.clone(allocator) creates an owned snapshot for deferred worker work.
Call deinit on the returned OwnedRequest. The framework modules also expose
zero-allocation multipart part/chunk iteration, HMAC-SHA256 signed cookies,
comptime JSON field constraints, CORS and security-header middleware, and SSE.

App.static(prefix, root, options) mounts a directory with directory-relative
path confinement, symlinks disabled, MIME detection, ETag and Last-Modified
validation, cache control, and one RFC 9110 byte range. File contents use the
configured bounded write capacity; oversized files fail with 413 Content Too
Large. The pinned libxev revision does not expose a socket-to-file completion,
so every platform currently uses this bounded fallback.

App.openapi(path) serves an OpenAPI 3.1 JSON document generated from the
router's fixed route registry. Parameter and wildcard paths are emitted with
OpenAPI braces.

## JSON-RPC

`json_rpc.Service` is a type-safe, fixed-capacity JSON-RPC 2.0 registry. Mount
it on any `App` with one line, or call `dispatch` directly from another
transport. The protocol layer imports only Zig's standard library.

```zig
const std = @import("std");
const uz = @import("uWebZockets");

const AddParams = struct { left: i64, right: i64 };
const AddResult = struct { sum: i64 };

fn add(params: AddParams) uz.json_rpc.HandlerError!AddResult {
    return .{ .sum = params.left + params.right };
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init(init.io);
    defer server.deinit();

    var rpc = uz.json_rpc.Service{};
    try rpc.register_typed("math.add", AddParams, AddResult, add);
    _ = try server.rpc("/rpc", &rpc);

    try server.listen("0.0.0.0", 3000);
    try server.run();
}
```

Run it with `zig build rpc_server -Doptimize=ReleaseSafe`, then call it:

```sh
curl http://127.0.0.1:3000/rpc \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"math.add","params":{"left":2,"right":3},"id":1}'
```

The response is `{"jsonrpc":"2.0","result":{"sum":5},"id":1}`.

Behavior and ownership are explicit:

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

Typed adapters use 4 KiB of fixed stack scratch for decoded parameters. Use
the lower-level `register` API with `Call.parse_params` and an explicit
allocator when a parameter type can exceed that bound.

`configured_service(max_procedures, method_storage_capacity,
response_capacity)` adjusts the default limits of 64 procedures, 4 KiB of
copied method names, and a 16 KiB response. `dispatch` accepts caller-owned
output storage when RPC is embedded outside the HTTP adapter.

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
        .ping_interval_ms = 30_000,
        .pong_timeout_ms = 10_000,
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
Heartbeat-enabled routes reuse the connection sweeper: idle peers receive an
empty ping and are closed if the configured pong timeout expires.
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
dynamic allocation on the data path. RFC 8441 WebSocket tunneling is supported
via extended CONNECT. Because parsing and message storage are connection-owned,
each HTTP/2 connection permits one active WebSocket tunnel; additional tunnels
receive `503 Service Unavailable` without disturbing the active tunnel.

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
| OpenAPI route registry | 320 entries, 64 KiB of paths |
| JSON-RPC procedures | 64 by default |
| JSON-RPC method names | 4 KiB copied storage by default |
| JSON-RPC response | 16 KiB by default |
| Mounted static directories | 8 |
| Static file body | configured write queue minus 4 KiB |
| Cluster message queue | 64 messages per worker |
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

## Web-standard API conventions

The public HTTP surface uses familiar WHATWG Fetch and Streams concepts where
they fit Zig. It keeps the same vocabulary and expected behavior, while making
allocation, ownership, and fallible I/O explicit. It is not a JavaScript API or
a claim of full WHATWG conformance.

| Web concept | µWebZockets API | Storage model |
| --- | --- | --- |
| `Request.url` | `req.url()` | Borrowed request target |
| `Headers.get`, `has`, `entries` | `req.headers()` | Read-only view over bounded fields |
| Body `text`, bytes, JSON | `req.text()`, `req.bytes()`, `req.json(T, allocator)` | Borrowed bytes; explicit allocator for parsed JSON |
| Text, HTML, bytes, JSON responses | `res.text()`, `res.html()`, `res.bytes()`, `res.json()`, `res.json_buf()` | Direct bounded write or explicit temporary allocator |
| `Response.redirect` | `res.redirect(location, code)` | Validated `Location`; CR/LF rejected |
| Readable and writable byte streams | `uz.streams.ReadableByteStream`, `res.writable_stream()` | BYOB reads and transport-aware bounded writes |
| `pipeTo` | `uz.streams.pipe_to()` | Caller-owned transfer buffer and deterministic close |

These request and response types are the shared application boundary for
HTTP/1.1, HTTP/2, and HTTP/3. Lower-level methods such as `end_with_headers`,
`begin_chunked`, and `write_chunk` remain available when an application needs
precise protocol control.

## Standards and Platform Support

### Protocol coverage

- WebSocket: RFC 6455 and RFC 7692 per-message deflate.
- HTTP/2: bounded RFC 9113 routing and one RFC 8441 WebSocket tunnel per
  connection.
- HTTP/3: bounded RFC 9114 request/response routing. Extended CONNECT,
  WebTransport, push, and application datagrams are helper-only and rejected by
  the live listener.
- HTTP extensions: RFC 10008 `QUERY` routing with syntactic content-type checks.

### Platform support

- Tier 1: Linux and macOS on `x86_64` and `aarch64`; these targets are built,
  tested, and published by CI.
- Tier 2: `x86_64-windows-gnu`, FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD.
  Windows libraries and the complete test/ABI graph are compiled on a native
  Windows runner for tagged releases, with a manual pre-release trigger
  available; the resulting archive is published. Windows runtime tests remain
  a Tier 2 validation responsibility. Windows QUIC uses IOCP UDP receives and
  Winsock WSASendTo sends. The BSD targets share the build graph
  without dedicated CI.

Request fields, route captures, middleware, async tokens, and transport pools
have fixed capacities; there is no dynamic overflow fallback. Performance
guarantees are relative same-runner comparisons defined by
[`http-throughput-v1`](benchmarks/http_throughput_guarantee.md).

See [CHANGELOG.md](CHANGELOG.md), [CODEBASE.md](CODEBASE.md), and
[CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) for release details, architecture, and
verification. Security reports must follow [SECURITY.md](SECURITY.md).

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
