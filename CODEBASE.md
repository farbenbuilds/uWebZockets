# uWebZockets Codebase

## Overview
`uWebZockets` is a high-performance, commercial-grade WebSocket and HTTP server API library written in Zig 0.16.0. It aims to replicate and surpass the performance capabilities of `uNetworking/uWebSockets` by leveraging Zig's explicit memory management, zero-allocation network fast-paths, and robust C interoperability.

## Core Paradigms
1. **Data-Oriented Design (DoD)**: Memory layout dictates performance. We employ Struct of Arrays (SoA) and tight data packing to maximize CPU cache utilization.
2. **Functional Programming (No OOP)**: Object-Oriented Programming is strictly forbidden. We separate pure data structures from the functions that transform them, favor pure functions without hidden state, and implement zero-allocation pipelines.
3. **Linux Kernel Coding Style**: We combine Zig's safety with Linux's pragmatic style, enforcing `snake_case` for variables and functions, shallow nesting via early returns, and an absolute ban on emojis in the codebase.

## Ecosystem & Dependencies
- **Event Loop**: `mitchellh/libxev` for high-performance, cross-platform asynchronous I/O.
- **Parser**: `farbenbuilds/zslay` integrated as the core WebSocket protocol parser.
- **C-Interop**: Zig's `translate-c` is utilized to safely and ergonomically wrap C libraries.
- **Vendored C/C++ Libraries**: `BoringSSL` (Crypto/TLS), `lsquic` (HTTP/3), and `libdeflate` (compression).
- **Tooling**: `natecraddock/zf` (fuzzy finder) integrated for development workflows.

## Project Structure

```
uWebZockets/
├── build.zig             # Zig build system configuration
├── build.zig.zon         # Zig package manifest
├── vendor/               # Contains git submodules (libdeflate, boringssl, lsquic, h1spec)
├── src/
│   ├── root.zig          # Library entry point (exports app, loop)
│   ├── core/             # I/O layer (loop.zig, tcp.zig, udp.zig) wrapper for libxev
│   ├── crypto/           # Security layer (tls.zig)
│   ├── http/             # Zero-alloc HTTP/1.1 FSM parser & response logic
│   ├── ws/               # WebSocket state machine (integrates `zslay`) & deflate
│   ├── quic/             # HTTP/3 module (lsquic integration)
│   ├── app.zig           # Developer-facing API
│   └── router.zig        # Static comptime routing logic
├── tests/
│   ├── autobahn/         # WS Target server for Autobahn Testsuite
│   └── h1spec/           # HTTP/1.1 Target server for h1spec testing
└── examples/
    ├── hello_world.zig   # Executable example (Basic usage)
    └── chat_server.zig   # Executable example (WebSocket Chat)
```

## Architecture Notes
- **`src/app.zig`**: The primary developer-facing interface. Must present a clean, ergonomic, and purely functional API.
- **`src/router.zig`**: Leverages Zig's `comptime` to resolve routes at compile-time, completely eliminating dynamic routing overhead at runtime.
- **`src/http/` & `src/ws/`**: The absolute critical paths. These layers must operate entirely without dynamic heap allocations during the request/response lifecycle.
