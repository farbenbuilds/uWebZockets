# µWebZockets Codebase

## Overview
`µWebZockets` is a high-performance, commercial-grade WebSocket and HTTP server API library written in Zig 0.16.0. It aims to replicate and surpass the performance capabilities of `uNetworking/uWebSockets` (and its underlying low-level I/O library `uSockets`) by leveraging Zig's explicit memory management, zero-allocation network fast-paths, and robust C interoperability.

## Core Paradigms
1. **Data-Oriented Design (DoD)**: Memory layout dictates performance. We employ Struct of Arrays (SoA) and tight data packing to maximize CPU cache utilization.
2. **Functional Programming (No OOP)**: Object-Oriented Programming is strictly forbidden. We separate pure data structures from the functions that transform them, favor pure functions without hidden state, and implement zero-allocation pipelines.
3. **Linux Kernel Coding Style**: We combine Zig's safety with Linux's pragmatic style, enforcing Linux file naming (`snake_case`) as well as `snake_case` for variables and functions, shallow nesting via early returns, and an absolute ban on emojis in the codebase.

## Ecosystem & Dependencies
- **Event Loop**: `mitchellh/libxev` for high-performance, cross-platform asynchronous I/O.
- **Parser**: `farbenbuilds/zslay` integrated as the core WebSocket protocol parser.
- **C-Interop**: Zig's `translate-c` is utilized to safely and ergonomically wrap C libraries.
- **Vendored C/C++ Libraries**: `BoringSSL` (Crypto/TLS), `lsquic` (HTTP/3), and `libdeflate` (compression).
- **Tooling**: `natecraddock/zf` (fuzzy finder) integrated for development workflows.

## Architecture Mapping: µWebZockets vs µWebSockets
In the original C++ ecosystem, the stack is split into `uSockets` (handling the low-level C event loop and raw sockets) and `µWebSockets` (handling the C++ HTTP/WS protocols and user API). In `µWebZockets`, these concepts are unified into a single cohesive Zig codebase.

### Project Structure & Purpose

```text
uWebZockets/
├── build.zig             # Zig build system configuration
├── build.zig.zon         # Zig package manifest
├── vendor/               # Contains git submodules (libdeflate, boringssl, lsquic, h1spec)
├── src/
│   ├── root.zig          # Library entry point (exports app, loop)
│   ├── c.h               # Centralized C header for translation. Includes BoringSSL, lsquic, libdeflate, etc.
│   ├── test.zig          # Centralized unit test suite. Re-exports sub-module tests.
│   ├── tests/            # Dedicated test modules (e.g., core_tests.zig, c_tests.zig)
│   ├── core/             # I/O layer (loop.zig, tcp.zig, udp.zig). Wraps libxev.
│   │                     # -> Counterpart: `uSockets` (Loop.c, Socket.c, Event.c)
│   ├── crypto/           # Security layer (tls.zig).
│   │                     # -> Counterpart: `uSockets` crypto bindings (crypto/)
│   ├── http/             # Zero-alloc HTTP/1.1 FSM parser & response logic.
│   │                     # -> Counterpart: `µWebSockets` HttpParser.h, HttpResponse.h, HttpRequest.h
│   ├── ws/               # WebSocket state machine (integrates `zslay`) & deflate.
│   │                     # -> Counterpart: `µWebSockets` WebSocket.h, WebSocketProtocol.h, PerMessageDeflate.h
│   ├── quic/             # HTTP/3 module (lsquic integration).
│   │                     # -> Counterpart: `uSockets` quic layer / future uWS HTTP/3 support
│   └── router/           # Developer-facing API and static comptime routing logic.
│                         # -> Counterpart: `µWebSockets` App.h, TemplatedApp.h, HttpRouter.h
├── tests/
│   ├── autobahn/         # WS Target server for Autobahn Testsuite
│   └── h1spec/           # HTTP/1.1 Target server for h1spec testing
└── examples/
    ├── hello_world.zig   # Executable example (Basic usage)
    └── chat_server.zig   # Executable example (WebSocket Chat)
```

## Architecture Notes
- **`src/router/`**: The primary developer-facing interface and routing logic. Unlike the templated C++ OOP approach of `TemplatedApp.h`, this must present a clean, ergonomic, and purely functional API passing state explicitly. It leverages Zig's `comptime` to resolve routes at compile-time, completely eliminating dynamic routing overhead at runtime (aiming to surpass `µWebSockets` runtime Trie-based `HttpRouter.h`).
- **`src/http/` & `src/ws/`**: The absolute critical paths. These layers must operate entirely without dynamic heap allocations during the request/response lifecycle.
- **`src/core/`**: While `uSockets` rolls its own epoll/kqueue bindings, we leverage `libxev` here for proven, cross-platform performance, wrapping it with functional zero-allocation paradigms.
