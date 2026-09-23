<p align="center">
  <img src="misc/uwebzockets_banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

A zero-allocation, shared-nothing server framework for Zig 0.16.0. One type-safe
`Request`/`Response` API serves HTTP/1.1, HTTP/2, HTTP/3, WebSocket, and
JSON-RPC from bounded slabs that are allocated once at startup, owned by one
thread each, and reused without locking.

- **Zero allocation:** no request, parse, route, or write path allocates.
- **Shared-nothing:** every worker runs its own libxev loop, slab set, and
  pinned physical core, coordinated only through lock-free rings.
- **Data-oriented:** struct-of-arrays pools, parallel router arrays, and
  compile-time capacities that make exhaustion explicit.
- **Readable types:** named callback, event, and override types instead of
  inline anonymous structs, reflection-driven shapes, or type gymnastics.
- **Cross-platform:** Tier 1 Linux and macOS, with a `x86_64-windows-gnu`
  fallback for reuse-port and affinity behavior.

[Quick start](#quick-start) | [Architecture](docs/architecture.md) |
[Memory model](docs/memory_model.md) | [Protocols](docs/protocols.md) |
[Operations](docs/operations.md)

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

The `hello_world` build step compiles and starts the example on port 3000.

## Shared-nothing by default

`App.cluster(worker_count)` gives every worker its own loop, connection pool,
request buffers, message regions, and queues. There is no shared I/O ring and
no lock on the steady-state path.

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a pinned worker") catch {};
}

pub fn main(init: std.process.Init) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .build_cluster(std.heap.page_allocator, 4, .{});
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Cluster.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    try group.listen("0.0.0.0", 3000);
    try group.run();
}
```

Workers share the port through `SO_REUSEPORT` (Linux/macOS) or `SO_REUSEADDR`
(Windows fallback), are pinned to distinct physical cores where the platform
allows it, and set `TCP_DEFER_ACCEPT` and `TCP_QUICKACK` to keep the loop
asleep through handshakes and to avoid delayed-ACK stalls. Details and the
platform matrix are in [docs/architecture.md](docs/architecture.md).

## Configure capacities, not bytes

`ServerConfig` presets and the fluent builder replace byte arithmetic with named
limits. `build` performs exactly one application allocation: the contiguous
slab behind the pool, request buffers, message regions, write queues, and
optional compression scratch.

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();

_ = try server.get("/health", health);
try server.listen("0.0.0.0", 3000);
try server.run();
```

| Preset | Connections | WebSocket message | Write queue | Request body |
| --- | ---: | ---: | ---: | ---: |
| `Presets.microservice` | 256 | 8 KiB | 16 KiB | 64 KiB |
| `Presets.websocket_chat` | 512 | 32 KiB | 32 KiB | 4 KiB |
| `Presets.file_server` | 128 | 4 KiB | 512 KiB | 8 KiB |

Oversized input gets a structured rejection instead of a dropped connection:

```json
{"error":{"code":"payload_too_large","message":"Request body exceeded the 64KB limit. Consider increasing 'max_body_size' in ServerConfig.","limit_bytes":65536}}
```

The full capacity table, slab layout, and backpressure model are in
[docs/memory_model.md](docs/memory_model.md).

## Examples

| Step | Shows |
| --- | --- |
| `zig build hello_world` | Minimal HTTP/1.1 route on `App` |
| `zig build shared_nothing_cluster` | Four pinned workers, one slab each |
| `zig build basic_microservice` | `Presets.microservice` with JSON helpers |
| `zig build custom_builder` | Fluent overrides and the 50 MiB body path |
| `zig build chat_server` | WebSocket pub/sub with bounded topics |
| `zig build rpc_server` | Typed JSON-RPC procedures |
| `zig build http3_server` | HTTP/3 over QUIC with TLS |

Every step appends `-Doptimize=ReleaseSafe` for production builds. Sources live
in [`examples/`](examples/), with walkthroughs in
[`examples/readme_examples_test.md`](examples/readme_examples_test.md).

## Documentation

| Document | Contents |
| --- | --- |
| [Architecture](docs/architecture.md) | Shared-nothing workers, affinity, TCP tuning, transports, shutdown |
| [Memory model](docs/memory_model.md) | Startup slab, SoA layouts, capacity limits, backpressure, rejections |
| [Protocols](docs/protocols.md) | HTTP/1.1/2/3, WebSocket, JSON-RPC, compliance status |
| [Operations](docs/operations.md) | Build, sanitizers, fuzzing, C ABI, dependency use, platform tiers |
| [Codebase](CODEBASE.md) | File-by-file map of the implementation |
| [CI pipeline](CI_CD_PIPELINE.md) | Workflow gates and verification matrix |

## Platform support

- Tier 1: Linux and macOS on `x86_64` and `aarch64`; built, tested, and
  published by CI.
- Tier 2: `x86_64-windows-gnu`, FreeBSD, NetBSD, OpenBSD, and DragonFlyBSD.
  Windows libraries and the full test/ABI graph are compiled on a native
  Windows runner; runtime validation is a Tier 2 responsibility.
- Shared-nothing clustering is fully supported on Linux; Windows uses the
  reuse-address fallback, and macOS runs unpinned because the platform exposes
  no hard-affinity API.

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

BoringSSL provides TLS, libxev drives non-blocking I/O, zslay 0.2.0 provides the
WebSocket frame state machine, and lsquic provides QUIC. Use a released tag or
pin an exact source commit.

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Security reports must follow
[SECURITY.md](SECURITY.md).
