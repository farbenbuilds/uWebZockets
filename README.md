<p align="center">
  <img src="misc/uwebzockets-banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

[![Test](https://github.com/kiensony/uWebZockets/actions/workflows/test.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/test.yml)
[![Autobahn Compliance](https://github.com/kiensony/uWebZockets/actions/workflows/autobahn-compliance.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/autobahn-compliance.yml)
[![h1spec Compliance](https://github.com/kiensony/uWebZockets/actions/workflows/h1spec-compliance.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/h1spec-compliance.yml)
[![Benchmark](https://github.com/kiensony/uWebZockets/actions/workflows/benchmark.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/benchmark.yml)

µWebZockets is a bounded-memory, event-driven WebSocket and HTTP/1.1 server
library for Zig 0.16.0. The request, response, frame parsing, masking, routing,
and connection I/O paths use fixed-capacity storage after application startup.
BoringSSL provides TLS, libxev drives non-blocking POSIX I/O, and zslay 0.1.5
provides the WebSocket frame state machine.

Version `1.0.0-alpha` is intended for evaluation and controlled production
pilots. Its API may still change before 1.0.0.

## Features

- HTTP/1.1 GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, and fallback routes
- Request targets split into path and query slices without allocation
- Automatic 404, 405 with `Allow`, OPTIONS, HEAD fallback, and `100 Continue`
- Fixed-size request parsing with strict framing and header validation
- Fixed-capacity, backpressure-aware response queues and chunked responses
- RFC 6455 server framing, fragmentation, masking, close handling, and
  streaming UTF-8 validation
- SIMD WebSocket masking with a scalar tail
- Bounded WebSocket messages, frames, subscriptions, and topic ownership
- HTTPS with BoringSSL TLS 1.3 and HTTP/1.1 ALPN
- Contiguous connection pools and per-connection storage selected at compile
  time
- Native GNU/Linux, musl/Linux, and macOS release packages

The bundled Autobahn runner executes all 517 selected server cases. The
verified alpha baseline is 298 strict passes, 3 informational results, and 216
RFC 7692 compression cases reported as unimplemented. The strict CI gate stays
red until per-message deflate is exposed; no compression cases are hidden.

## Requirements

- Zig 0.16.0
- CMake 3.20 or newer
- Ninja
- A POSIX target supported by libxev
- zlib development headers and a static library
- Git submodules checked out recursively

The Nix flake pins Nixpkgs 26.05 and provides the supported Zig, CMake, Ninja,
Go, Python, Perl, and zlib toolchain on all release architectures.

## Build

```sh
git clone --recurse-submodules https://github.com/kiensony/uWebZockets.git
cd uWebZockets
nix develop
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

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

Until the alpha tag is published, a source checkout can be used as a path
dependency:

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
exe.root_module.addImport("uWebZockets", uz.module("uWebZockets"));
```

The dependency checkout must include the repository's recursive git
submodules.

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

Route strings are borrowed for the application's lifetime. Register static or
otherwise long-lived strings before calling `listen`. Do not move the `App`
value after `listen`; event-loop callbacks retain its address.

For incremental HTTP output, call `begin_chunked`, `write_chunk` as needed,
then `end_chunks`. A handler must finish one response before returning; async
handler suspension is not part of the alpha API. `Request` fields borrow the
connection's request buffer and are valid only until the handler returns.

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

The server negotiates TLS 1.3 and advertises only `http/1.1`.

## Capacity and protocol limits

The alpha defaults are deliberately finite:

| Resource | Limit |
| --- | ---: |
| Request line | 8 KiB |
| HTTP headers | 16 KiB total, 64 fields |
| HTTP request body | 16 KiB |
| Routes | 256 radix nodes |
| Route path | 2 KiB |
| WebSocket message | 16 KiB with `App` |
| WebSocket control payload | 125 bytes |
| Write queue | fixed per connection |
| Idle timeout | 120 seconds by default |

Oversized or ambiguous input is rejected rather than expanded dynamically.

## Current limitations

- HTTP/2 and HTTP/3 are unavailable. The Zig adapter is a fail-closed stub,
  raw callbacks are absent, and `init_http3` returns
  `error.Http3NotImplemented`. The lsquic vendor build remains packaged for
  integration testing only.
- RFC 7692 per-message deflate is not negotiated.
- Windows is not a supported alpha target.
- Route parameters, middleware, async handlers, and a stable C ABI are not yet
  exposed.
- The project has not yet published long-term performance guarantees.

See [CHANGELOG.md](CHANGELOG.md), [CODEBASE.md](CODEBASE.md), and
[CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) for release details, architecture, and
verification. Security reports must follow [SECURITY.md](SECURITY.md).

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
