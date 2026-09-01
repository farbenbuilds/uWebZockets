# Contributing to µWebZockets

µWebZockets accepts focused changes that preserve bounded resource use,
protocol correctness, and a shallow data-oriented design.

Read [CODEBASE.md](CODEBASE.md), [CODING_CONVENTION.md](CODING_CONVENTION.md),
and [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) before changing the transport or
protocol paths. Report security defects privately as described in
[SECURITY.md](SECURITY.md).

## Development environment

Use the pinned Nix shell when possible. Clone recursively when working on the
vendored h1spec compliance suite:

```sh
git clone --recurse-submodules https://github.com/farbenbuilds/uWebZockets.git
cd uWebZockets
nix develop
```

The flake pins Nixpkgs 26.05. The non-Nix toolchain requires Zig 0.16.0, CMake,
Ninja, patch, Go, Python, Perl, and zlib development files.

## Engineering requirements

- Do not allocate in request parsing, frame parsing, masking, routing, or
  network write callbacks. Allocate fixed application storage at startup.
- Cap every peer-controlled length, count, queue, and subscription.
- Prefer parallel arrays or compact slabs when a hot loop reads only a subset
  of fields. Do not force Struct of Arrays onto small one-off records.
- Keep parsing and validation functions pure where practical. Pass mutable I/O
  state explicitly at the event-loop boundary.
- Finish route registration before starting either listener; route arrays are
  immutable once `listen` or `listen_udp` succeeds.
- Keep route captures within the 16-slot request bound, parameter patterns
  within the 64-route bound, and middleware within its 32-entry fixed array.
- Treat asynchronous response tokens as event-loop-confined, exactly-once
  borrows. Marshal cross-thread completion back to the owning loop and test
  stale-token, double-completion, disconnect, and pipelining paths.
- Use early returns and short error paths. Never silently swallow an error.
- Use `snake_case` for project files, functions, and variables. Preserve raw C
  identifiers only at the FFI boundary.
- Keep comments concise and explain constraints or non-obvious tradeoffs.
- Do not add emoji characters anywhere in the repository.
- Put every ordinary Zig unit test under `src/tests/` and import it from
  `src/tests/main.zig`. Production modules must not import the centralized test
  root. The `src/tests/fuzz_main.zig` Smith corpus runs once in the ordinary
  test graph and is also the dedicated root for extended `zig build fuzz` runs.
- Keep the implementation POSIX-only. Do not add Windows branches or APIs.
  Linux and macOS are the published CI matrix; preserve the accepted FreeBSD,
  NetBSD, OpenBSD, and DragonFlyBSD targets when changing platform checks.
- Preserve upstream style in vendored submodules; update those through their
  upstream project rather than rewriting vendored files.

## Local checks

Run all relevant checks before opening a pull request:

```sh
zig fmt --check build.zig src examples tests fuzz
sh scripts/check_conventions.sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe --summary all
zig build oss-fuzz-smoke -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
```

Sanitizer commands require native Linux; MemorySanitizer additionally requires
x86_64 and cannot be combined with `-Dsanitize=true`. `nix develop` exports
matching sanitizer, glibc, and dynamic-linker paths automatically. Non-Nix
setups must
pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. When that runtime
uses a different glibc than the host, also pass matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths.

Changes to WebSocket parsing or I/O must also run the Autobahn target. Changes
to HTTP parsing, dispatch, or response framing must run h1spec. Changes to
HTTP/2 or HPACK must exercise the centralized malformed-frame, flow-control,
Huffman, table-size, header-list, and pseudo-header tests. Changes to HTTP/3
must compile `http3_server`, exercise centralized QPACK/framing tests, and run
the pinned curl/ngtcp2 and aioquic cross-implementation gate. The exact CI
commands and report gate are documented in [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md).

Tests should use fixed caller-owned storage for hot paths. If the unit under
test allocates, use `std.testing.allocator` or another leak-detecting allocator
and prove all success and error paths release ownership.

New external-byte parsers or framing transformations must have deterministic
Smith coverage and, when they form a network trust boundary, an
`LLVMFuzzerTestOneInput` target compatible with Google OSS-Fuzz. Add bounded
seed corpora, dictionaries where grammar tokens help, and a smoke driver that
runs without libFuzzer. FFI changes must preserve exact C layout checks, keep
`include/uWebZockets.h` synchronized with implemented exports, and include
malformed and capacity-exhaustion cases.

## Pull requests

- Explain the protocol, ownership, or performance invariant being changed.
- Include regression tests for bugs and malformed-input tests for parsers.
- Document API, limit, configuration, or compatibility changes.
- Separate measured performance results from estimates.
- Note breaking changes explicitly in the pull request and changelog.
- Keep commits concise and follow
  [.github/COMMIT_CONVENTION.md](.github/COMMIT_CONVENTION.md).

## Dependency updates

For Zig dependencies, update all generated package views together:

- `build.zig.zon`
- `build.zig.zon.json`
- `build.zig.zon.nix`
- `build.zig.zon.txt`

Record the upstream version, immutable URL or revision, Zig package hash, Nix
hash, license, and any API migration. Rebuild from an empty Zig/vendor cache so
a stale artifact cannot hide a dependency problem.

For C/C++ package sources, retain immutable commits and Zig package hashes,
CMake target-based builds, Ninja execution, the Zig compiler wrappers,
target-specific cache directories, and static-library outputs. Keep lsquic's
ls-qpack and ls-hpack revisions synchronized with the pinned lsquic source. The
`vendor/h1spec` submodule remains a compliance input rather than a packaged
library dependency. Do not add global compiler or linker flags when
target-local settings work.

## Releasing

1. Set the same version in `build.zig.zon` and `flake.nix`.
2. Add a dated `CHANGELOG.md` section with breaking changes and limitations;
   do not leave an `Unreleased` placeholder in a final release snapshot.
3. Verify `THIRD_PARTY_NOTICES.md` and every packaged license.
4. Pass local formatting, convention, test, and build checks.
5. Pass ASan/UBSan/leak, MemorySanitizer, Smith fuzz, OSS-Fuzz object/smoke,
   Autobahn, h1spec, and HTTP/3 cross-implementation checks on the release
   commit.
6. Tag the final commit as `v<version>` and push the tag.
7. Review all six `Publish` environment deployments, archives, and
   `SHA256SUMS` before announcing the release.
