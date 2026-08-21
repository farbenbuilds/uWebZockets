# Contributing to uWebZockets

Thank you for your interest in contributing to `uWebZockets`! To maintain our extreme performance targets and strict codebase quality, please read and adhere to the following guidelines before submitting a Pull Request.

## Prerequisites
Before you start coding, please familiarize yourself with our core architectural documents:
1. **[CODEBASE.md](./CODEBASE.md)**: Understand the directory structure and how we map to the original C++ `uWebSockets` stack.
2. **[CODING_CONVENTION.md](./CODING_CONVENTION.md)**: Our strict style, naming, and formatting rules.
3. **[CI_CD_PIPELINE.md](./CI_CD_PIPELINE.md)**: How your code will be tested and benchmarked.

## The Three Pillars of uWebZockets

1. **Zero-Allocation Hot Paths**: The network request and response cycles must *never* dynamically allocate memory on the heap. Pre-allocate buffers or use arena allocators for temporary per-connection state. If a PR introduces a heap allocation in `src/http/` or `src/ws/`, it will be rejected.
2. **Strictly Functional & DoD (No OOP)**: Do not try to emulate classes or bind hidden state to behavior. Separate data structures (designed for cache-locality using Data-Oriented Design) from the pure functions that operate on them.
3. **Linux Kernel Styling in Zig**: We explicitly override Zig's standard naming convention. You *must* use `snake_case` for functions and variables. Keep your control flow shallow (return early). And remember: **Emojis are strictly banned** anywhere in the repository, including PR descriptions and commit messages.

## Development Workflow

1. **Format your code**: Run `zig fmt` on your files. Unformatted code will fail CI immediately.
2. **Run the tests**: Use `zig build test`. We use `std.testing.allocator` exclusively. If your code leaks memory, the tests will immediately fail.
3. **Check Naming**: Double-check that you haven't slipped into `camelCase` for local variables or function names.
4. **Write concise commit messages**: Be dense, precise, and have a high signal-to-noise ratio.

## Submitting a Pull Request
- Ensure your PR passes all local tests (`zig build test`).
- Expect your PR to be rigorously stress-tested in CI against the **Autobahn WebSockets Testsuite** and **h1spec**.
- Performance regressions (measured in RPS and latency percentiles against the baseline) will block merges unless strongly justified.
