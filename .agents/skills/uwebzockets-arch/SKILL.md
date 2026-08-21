---
name: uwebzockets-arch
description: Core architecture, dependencies, and design philosophy for uWebZockets. Use this skill when making high-level design decisions or integrating core libraries.
---

# uWebZockets Architecture Skill

## 1. Objective
Build a high-performance, zero-allocation WebSocket/HTTP server API library in Zig 0.16.0, mirroring and surpassing `uNetworking/uWebSockets`.

## 2. Core Dependencies & Stack
- **Event Loop**: `mitchellh/libxev`. Used for high-performance, cross-platform asynchronous IO. Ensure the event loop is tightly integrated and minimizes context switches.
- **Parser**: `farbenbuilds/zslay`. The core parser for protocols. Must be used in a zero-allocation manner on the hot path.
- **C-Interop/FFI**: `translate-c` (from `codeberg.org/ziglang/translate-c`). Prefer translating C headers to Zig over raw `@cImport` for complex libraries to gain better type safety and compilation speed.
- **Tooling**: `natecraddock/zf` (fuzzy finder) for project tooling and build scripts.
- **Cryptography & Compression**: C/C++ libraries like BoringSSL, libsquic, libdeflate integrated via FFI.

## 3. Design Principles
- **Data-Oriented Design (DoD)**: Lay out connection state and buffers to maximize cache hits. Avoid pointer chasing.
- **Non-blocking IO**: All network operations must be non-blocking. Offload heavy computation (like SSL handshakes) if it blocks the main event loop, or handle it asynchronously.
- **Commercial API Readiness**: The public API must be ergonomic, safe, and heavily documented (using short, readable comments without emojis).

## 4. When to Use This Skill
- Designing the main event loop wrapper.
- Integrating SSL/TLS or compression libraries.
- Writing parsing logic for HTTP/WebSocket frames.
- Structuring the public API for users of the `uWebZockets` library.
