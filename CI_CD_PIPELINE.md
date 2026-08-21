# uWebZockets CI/CD Pipeline

This document outlines the Continuous Integration and Continuous Deployment (CI/CD) strategy for `uWebZockets`. Given our strict performance and functional paradigms, the pipeline acts as the ultimate gatekeeper for zero-allocations, memory safety, and protocol compliance.

## Workflows

The following table maps our CI/CD strategy to specific GitHub Actions workflow files:

| Workflow                          | Trigger                             | Purpose                                         |
| --------------------------------- | ----------------------------------- | ----------------------------------------------- |
| `.github/workflows/lint.yml`      | Pull request into `main`            | Code formatting (`zig fmt --check .`) and convention checks (emoji/`snake_case` scanner). |
| `.github/workflows/test.yml`      | Pull request into `main`            | Native Zig unit tests (`zig build test`) with `std.testing.allocator` memory leak detection. |
| `.github/workflows/compliance.yml`| Pull request into `main`            | Spins up target servers and runs Autobahn WS and `h1spec` test suites. |
| `.github/workflows/publish.yml`   | Push of a version tag matching `v*` | Cross-platform builds (Linux/macOS) via Nix and GitHub release binary distribution. |

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
  - **`ReleaseSafe`**: Compiled with optimizations enabled but safety checks (bounds checking, overflow) retained. Used to catch hidden memory bugs under load.
  - **`ReleaseFast`**: Compiled with max speed, stripping safety checks. The ultimate production target for our zero-alloc hot paths.
- **Cross-Compilation Check**: Validates that `uWebZockets` cross-compiles flawlessly for critical target triples (e.g., `x86_64-linux-musl`, `aarch64-linux-gnu`, `aarch64-macos-none`) via Nix.

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

### 6. Job: `publish-artifacts`
1. Checkout repository.
2. Setup Nix (with `flake-parts`) and Zig 0.16.0.
3. Derives the version from the tag (`v0.1.0` becomes `0.1.0`).
4. Extracts the release notes from the matching `## [0.1.0]` section of `CHANGELOG.md`.
5. Calls `nix build` sequentially for the targets defined in `flake.nix`:
   - `linux-x86_64-gnu` -> builds `uWebZockets-x86_64-linux-gnu.a`
   - `linux-x86_64-musl` -> builds `uWebZockets-x86_64-linux-musl.a`
   - `linux-aarch64-gnu` -> builds `uWebZockets-aarch64-linux-gnu.a`
   - `linux-aarch64-musl` -> builds `uWebZockets-aarch64-linux-musl.a`
   - `macos-x86_64` -> builds `uWebZockets-x86_64-macos.a`
   - `macos-aarch64` -> builds `uWebZockets-aarch64-macos.a`
   - `windows-x86_64` -> builds `uWebZockets-x86_64-windows.lib`
6. Packages Linux and macOS artifacts exclusively into cross-platform archives (`.tar.bz2`, `.tar.gz`, `.tar.xz`) utilizing hermetic tools (`gnutar`, `bzip2`, `gzip`, `xz`). Windows targets are packaged into `.zip` archives utilizing the `zip` tool. All tools are provided via `flake.nix` dev shells. The raw `.a`/`.lib` files are strictly omitted from the payload.
7. Creates (or updates) the GitHub Release named after the tag and uploads the generated tarball archives.

## Versioning Rules
- Semantic versioning; the `v*` tag is the single release trigger.
- The tag must match the version declared in `build.zig.zon`, and a matching `CHANGELOG.md` section must exist. The full checklist lives in [CONTRIBUTE.md](CONTRIBUTE.md).
