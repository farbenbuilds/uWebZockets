# uWebZockets CI/CD Pipeline

This document outlines the Continuous Integration and Continuous Deployment (CI/CD) strategy for `uWebZockets`. Given our strict performance and functional paradigms, the pipeline acts as the ultimate gatekeeper for zero-allocations, memory safety, and protocol compliance.

## Pipeline Stages

### 1. Formatting & Linting (`zig fmt` & Custom Checks)
- **`zig fmt` Check**: Ensures all source code adheres strictly to the Zig formatter. Any unformatted code will fail the build.
- **Convention Checks**: A custom CI script will scan for banned patterns based on our `CODING_CONVENTION.md`:
  - **Emojis**: Scans for and rejects any emojis in code, comments, or commit messages.
  - **Naming**: Enforces `snake_case` for functions and variables (our Linux style override).

### 2. Unit Testing & Memory Leak Detection (`zig build test`)
- **Execution**: Runs all internal `test` blocks defined across the `src/` directory.
- **Memory Safety**: Zig's `std.testing.allocator` is used for all tests. If any test leaks even a single byte of memory, or if a double-free/use-after-free is detected, the pipeline will immediately halt and fail.
- **Fuzz Testing**: Executes built-in Zig fuzz tests targeting our integration with the `zslay` parser to ensure absolute resilience against malformed HTTP/WS payloads.

### 3. Build Verification (`ReleaseSafe` & `ReleaseFast`)
- **Compilation Check**: Ensures that the library, target servers in `tests/`, and sample apps in `examples/` compile successfully across different optimization modes.
- **Cross-Compilation Check**: Validates that `uWebZockets` cross-compiles flawlessly for critical target triples (e.g., `x86_64-linux-musl`, `aarch64-linux-gnu`, `aarch64-macos-none`) to guarantee `libxev` and C-interop portability.

### 4. Protocol Compliance Testing (Autobahn & h1spec)
To position `uWebZockets` as a commercial-grade alternative to `uWebSockets`, we must perfectly pass industry-standard protocol test suites.
- **Autobahn WebSockets Testsuite**: 
  - *Action*: The pipeline spins up our `tests/autobahn/` target server in the background and runs the standard Python `wstest` docker container against it.
  - *Purpose*: Validates 100% strict compliance with RFC-6455 (WebSocket Protocol), including fragmentation, masking, per-message deflate, and control frames.
- **h1spec (HTTP/1.1 Testsuite)**:
  - *Action*: The pipeline compiles our `tests/h1spec/` target server and runs the `h1spec` suite against it.
  - *Purpose*: Validates HTTP/1.1 edge cases, pipelining, chunked encoding, and malformed request handling to ensure our zero-alloc HTTP FSM parser never panics or hangs.

### 5. Performance Benchmarking (Nightly/PRs)
- **Action**: Runs load testing tools (like `wrk` or `bombardier`) against the current branch and compares the request-per-second (RPS) and latency percentiles against both the `main` branch and a baseline C++ `uWebSockets` server.
- **Purpose**: Ensures that new commits do not introduce hidden performance regressions, cache misses, or violate the Data-Oriented Design (DoD) zero-allocation hot-path rules.
