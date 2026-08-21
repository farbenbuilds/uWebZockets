---
name: uwebzockets-workflow
description: Master high-performance workflow integrating all specialized skills for the µWebZockets project.
---

# µWebZockets High-Performance Master Workflow

This document outlines the unified workflow combining all specialized skills available in `.agents/skills/*` to build a blazingly fast, zero-allocation WebSocket/HTTP library.

## 1. Mindset & Optimization (`ponytail`, `caveman`, `dod`, `functional-programming-fundamentals`)
- **Functional & Pure (No OOP)**: Zero Object-Oriented Programming allowed. Emphasize pure functions, explicit state passing, and immutability where it doesn't cost performance. Never bind state and behavior into "classes".
- **Data-Oriented Design (`dod`)**: Performance starts with memory. Group data by access pattern, not by object. Use Struct of Arrays (SoA) to maximize CPU cache utilization and minimize pointer chasing. Functional pipelines must operate over these DOD-optimized structures without allocating.
- **Ponytail Mode (`ponytail`)**: Embrace extreme laziness and simplicity. Ask "Do we even need this?" before writing any code. Prefer native Zig language features over dependencies. Keep solutions minimal.
- **Caveman Mode (`caveman`)**: Keep communication dense and concise. High signal-to-noise ratio in documentation, commit messages, and PRs.

## 2. Core Architecture (`zig-0.16`)
- **Zero-Allocation Hot Paths**: The request/response cycle must not allocate memory dynamically. Pre-allocate buffers and leverage `std.heap.ArenaAllocator` for temporary per-connection data.
- **Event Loop & IO**: Utilize `mitchellh/libxev` for a robust, cross-platform, non-blocking event loop.
- **Parsing**: Leverage `farbenbuilds/zslay` for protocol parsing.
- **Zig 0.16 Primitives (`zig-0.16`)**: Strictly adhere to the latest `std.io` patterns and deprecations.

## 3. Implementation & Build (`zig-best-practices`, `zig-comptime`, `zig-build-system`)
- **Idiomatic Zig (`zig-best-practices`)**: Follow standard Zig naming, error handling (native error sets), and explicit memory management. Combine with our Linux-style coding conventions (early returns, minimal indentation).
- **Compile-Time Evaluation (`zig-comptime`)**: heavily utilize `comptime` for routing logic and protocol framing to completely eliminate runtime overhead.
- **Build Infrastructure (`zig-build-system`, `nix-best-practices`)**: Write lean `build.zig` scripts. Utilize Nix for reproducible developer environments to ensure identical cross-platform builds.

## 4. FFI & Cross-Compilation (`zig-cinterop`, `zig-cross`)
- **C Interoperability (`zig-cinterop`)**: Integrate `BoringSSL`, `libsquic`, and `libdeflate`. Prefer using `translate-c` to convert headers to Zig for improved type safety and faster compilation over raw `@cImport`.
- **Targeting (`zig-cross`)**: Ensure the library can cross-compile flawlessly to diverse target architectures using Zig's native cross-compilation toolchain.

## 5. Debugging & QA (`zig-testing`, `zig-debugging`, `zig-compiler`)
- **Zero-Leak Testing (`zig-testing`)**: All tests must use `std.testing.allocator` to proactively detect and prevent memory leaks. Use Zig's built-in fuzz testing to stress-test the parser.
- **Compiler Optimization (`zig-compiler`)**: Distinguish between `ReleaseFast` and `ReleaseSafe`. Always ensure safe runtime checks during development, optimizing to `ReleaseFast` only for proven hot paths.
