# µWebZockets CI/CD Pipeline

The pipeline verifies formatting, bounded protocol behavior, multiple
optimization modes, standards compliance, cross-target compilation, and
release metadata. A passing pipeline is evidence for the tested configurations;
it is not a proof that all memory or security defects are absent.

## Workflows

| Workflow | Trigger | Environment | Purpose |
| --- | --- | --- | --- |
| `lint.yml` | pushes and pull requests to `main`, manual | `Linting` | Zig formatting and repository conventions |
| `test.yml` | pushes and pull requests to `main`, manual | `Testing` | Debug, sanitizer, fuzz, ReleaseSafe, and ReleaseFast verification |
| `oss_fuzz.yml` | pushes and pull requests to `main`, manual, reusable | `Testing` | OSS-Fuzz-compatible ASan/libFuzzer build and execution |
| `autobahn_compliance.yml` | pushes and pull requests to `main`, manual | `autobahn Compliance` | RFC 6455 server compliance |
| `h1spec_compliance.yml` | pushes and pull requests to `main`, manual | `h1spec Compliance` | HTTP/1.1 compliance |
| `http3_compliance.yml` | pushes and pull requests to `main`, manual | `HTTP3 Compliance` | curl/ngtcp2 and aioquic HTTP/3 interoperability |
| `benchmark.yml` | pull requests to `main`, nightly, manual | `Benchmarking` | HTTP throughput regression |
| `publish.yml` | `v*` tag push | `Publish` | Exact-tag verification and six-target static-library release |

Every workflow uses a GitHub environment so repository deployments and any
environment protection rules remain visible in GitHub.

## Lint

The lint job uses Zig 0.16.0 and runs:

```sh
zig fmt --check build.zig src examples tests fuzz
sh scripts/check_conventions.sh
```

The convention scanner checks project source filenames, Zig function and
variable names, and text files for prohibited emoji code points. Vendored
sources are excluded because their upstream conventions are preserved.

## Unit and build verification

The test job checks out all submodules and enters the Nix development shell.
It then runs:

```sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-objects -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
(cd tests/package_consumer && zig build check -Doptimize=ReleaseSafe)
```

Debug tests cover parser limits, malformed framing, partial reads and writes,
pool ownership, router method behavior, handshake validation, close codes,
fragmentation, streaming UTF-8, SIMD masking, pub/sub cleanup, and large
WebSocket messages. Code that allocates in tests uses leak-detecting test
allocators where applicable. Most hot-path tests use caller-provided fixed
storage and therefore allocate nothing to begin with.

ReleaseSafe compiles the same test graph with safety checks and optimization.
ReleaseFast proves the production static-library graph and all pinned C/C++
dependencies compile at the speed-oriented mode. The downstream fixture proves
that the published Zig package can be consumed through `b.dependency` without
repository-relative vendor paths.

The sanitizer pass is native Linux only. The Nix shell supplies matching LLVM
sanitizer, glibc, and dynamic-linker paths. `build.zig` sets coherent RPATHs
and launches sanitizer executables through that matching loader, instruments
BoringSSL, lsquic, libdeflate, and the local C ABI shim with ASan/UBSan, enables
Zig's full C-UB checks, preserves frame pointers, and isolates the vendor cache.
CI enables ASan leak detection and makes both ASan and UBSan fail fast. A
separate x86_64 Linux pass rebuilds the pinned C/C++ dependencies and local C
shim with MemorySanitizer and origin tracking, then runs a focused C
dependency-boundary smoke. It does not instrument Zig code or execute the full
C ABI suite, and MSan cannot be combined with ASan.

The test job also runs Zig's native fuzzer for 100,000 iterations over bounded
HTTP, HTTP/3 metadata, WebSocket extension, and zslay receive-state targets.
Seed corpora include valid, fragmented, malformed, and control-frame inputs.
It separately compiles the three sanitizer-coverage libFuzzer objects used by
OSS-Fuzz for HTTP framing, WebSocket masking, and QUIC packet boundaries.

## OSS-Fuzz compatibility

The reusable `oss_fuzz.yml` workflow uses ClusterFuzzLite, so it does not
assume or claim enrollment in the hosted OSS-Fuzz service. Its external-project
Docker build copies the exact revision under test, verifies the Zig 0.16.0
archive checksum, builds all three `LLVMFuzzerTestOneInput` entrypoints, links
them with the OSS-Fuzz-provided Clang flags and libFuzzer engine, and retains
all targets for the bad-build check. A bounded batch then executes every target
in the OSS-Fuzz runner environment.

The fuzz-target metadata enables address builds only. Zig 0.16 emits sanitizer
coverage for these objects and `ReleaseSafe` keeps Zig safety checks, but
Clang's flags do not instrument Zig-generated loads and stores. The workflow
therefore does not claim standalone UBSan or MSan instrumentation; those names
refer only to the separate C/C++ dependency checks described above.

## Autobahn WebSockets compliance

The Autobahn job builds `autobahn_server` in ReleaseSafe, then the Deno runner
starts it, waits until port 9001 is accepting connections, and launches the
digest-pinned
`crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`
container as a fuzzing client. The runner uses Deno's native process API and
has no runtime JavaScript dependencies. It always terminates the server, and
the container writes reports as the invoking POSIX user so repeated local runs
can replace them safely. The workflow uploads the complete HTML/JSON report
even when the gate fails.

The configuration selects groups 1-7, 9-13 with no exclusions. The report gate
requires the verified 1.0.0 aggregate baseline: all 517 cases, with 514 `OK`
and 3 `INFORMATIONAL` results for both protocol and close behavior. Any failed,
`NON-STRICT`, missing, additional, or reclassified result fails the job. RFC
7692 groups 12 and 13 pass through negotiated no-context-takeover per-message
deflate; no case is excluded or suppressed.

## h1spec compliance

The h1spec job builds the HTTP target in ReleaseSafe, waits for port 8000, and
runs the pinned repository submodule with Deno. On failure it uploads the
server log. Deterministic HTTP adversarial cases also remain in the Zig unit
suite so malformed-input coverage does not depend solely on an external tool.

## Cross-target checks

`flake.nix` defines native GNU or macOS packages and Linux musl packages. Its
Nixpkgs input is pinned to the 26.05 release so all four supported host systems,
including x86_64-darwin, remain evaluable. Checks compile tests for both native
and musl targets without attempting to execute foreign binaries. The publish
matrix runs natively on these GitHub-hosted architectures:

- x86_64-linux-gnu
- x86_64-linux-musl
- aarch64-linux-gnu
- aarch64-linux-musl
- x86_64-macos
- aarch64-macos

Windows is not supported in `1.0.0` and is intentionally absent from the
matrix.

The default build also compiles the bounded `http3_server` example. The HTTP/3
gate drives it independently with pinned curl/ngtcp2/nghttp3 and aioquic,
checks valid requests and trailers plus duplicate pseudo-header, pseudo-header
ordering, and connection-specific header rejection cases. Each malformed
request must receive `H3_MESSAGE_ERROR` while a concurrent sibling succeeds on
the same connection; a final health request then verifies continued service.
The gate retains server logs, traces, versions, results, and qlogs. The
runner generates a one-run localhost certificate in a private temporary
directory and deletes its key during cleanup, so clean checkouts do not depend
on ignored developer certificates.

## Performance regression

The benchmark workflow checks the pull request and its `main` base out into
separate directories, then builds each checkout from its own working directory
with ReleaseFast on the same Ubuntu runner. Candidate and baseline builds use
three bounded attempts with 10- and 20-second backoff so a transient immutable
dependency fetch does not discard the comparison.

The versioned [`http-throughput-v1`](benchmarks/http_throughput_guarantee.md)
contract runs three 10-second `wrk` samples against each `hello_world` server,
compares median requests per second, and fails when the candidate falls below
90 percent of the baseline. Pull-request raw reports remain available as
30-day workflow artifacts. Scheduled and manual mainline runs additionally
append the canonical JSON record and raw evidence to the durable
`benchmark-data` branch. Records include runner, toolchain, source, flake-lock,
and contract provenance and are described by the published v1 schema.

The tolerance accounts for shared-runner variance. This is an explicit relative
regression guarantee, not a portable absolute-capacity claim; absolute history
must only be compared within matching runner and toolchain cohorts.

## Publishing

A `v*` tag gates four release phases.

1. A native verification job checks formatting and conventions, runs the
   centralized Debug and ASan/UBSan suite plus the MSan dependency-boundary
   smoke, compiles ReleaseSafe tests and all OSS-Fuzz objects, and builds the
   downstream package consumer from the exact tagged source. The reusable
   Autobahn, h1spec, HTTP/3, and OSS-Fuzz compatibility workflows run in
   parallel against that same tag; release builds cannot start until all five
   verification jobs pass.
2. Each matrix job enters the `Publish` environment, checks that the tag
   is valid Semantic Versioning, matches `build.zig.zon`, both Nix package
   versions, and the C ABI version macros/string, and has a matching
   `CHANGELOG.md` section, then builds the appropriate Nix package.
3. Each target is packaged as one `.tar.gz` containing the µWebZockets,
   BoringSSL, lsquic, and libdeflate static archives, `include/uWebZockets.h`,
   metadata, and all relevant licenses.
4. The release job enters the `Publish` environment, requires exactly six
   archives, writes `SHA256SUMS`, extracts matching changelog notes, and creates
   or updates the GitHub release through `gh`. Versions containing a hyphen are
   marked as prereleases; stable versions are marked latest.

Release uploads are idempotent: rerunning a tag workflow updates notes and
replaces assets with the same names.

## Release checklist

- Update `build.zig.zon`, `flake.nix`, and `CHANGELOG.md` to the same version.
- Run formatting and convention checks.
- Run Debug tests and ReleaseSafe/ReleaseFast build checks.
- Run the native Linux ASan/UBSan/LeakSanitizer and MSan passes.
- Run the ClusterFuzzLite bad-build check and bounded batch for all three
  OSS-Fuzz targets.
- Run Autobahn and h1spec compliance.
- Verify third-party revisions and licenses.
- Create and push `v<version>` only after the release commit is final.
- Review the `Publish` environment deployment and generated checksums.

The benchmark workflow is advisory for release tags because it runs on pull
requests and nightly rather than on `publish.yml`. Performance claims must cite
the retained configuration and raw results.
