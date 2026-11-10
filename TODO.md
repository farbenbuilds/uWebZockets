# uWebZockets Engineering Roadmap and Execution Guide (v1.9.0 to v3.9.0, full-stack modules, and MCP)

> Target Audience: the maintainer, systems engineers, and autonomous coding
> agents.
> Current release: 2.2.0 (2026-11-10). Open patch: 2.5.5 (Section 11.1).
> Historical note: the v1.9.0 and v2.0 sections are closure context; use the
> current repository state and milestone checkboxes, not the old release
> target, to decide what is open.
> Repository constraints: zero allocation on hot paths, shared-nothing
> thread-per-core, pure functions, explicit named types, bounded startup
> memory, no emojis, no `std.debug.print` outside tests.
> Binding rules: `AGENTS.md`, `CODING_CONVENTION.md`, `CONTRIBUTE.md`, and
> `CI_CD_PIPELINE.md` always win over this document. If this guide and the
> repository disagree, the repository wins and this guide is corrected.
> This file is the single comprehensive guide. Part I is the execution tracker;
> Part II is the merged design dossiers from `uWZ-Disadvantages.md`; Section 19
> is the master release checklist.

---

## 0. Vision and document map

**Vision:** make µWebZockets the reference high-performance Zig server for
teams that need HTTP/1.1, HTTP/2, HTTP/3, WebSocket, and WebTransport with
bounded memory and predictable tail latency, then give those teams an optional
application layer (SQL, S3, jobs, cache, sessions, JWT, proto, metrics,
tracing, MCP) without forcing a monolith or a hidden runtime. The core stays
zero-allocation and shared-nothing; the modules are independently importable,
per-worker, feature-gated, and fail closed.

**What this file is:**

- **Part I, Sections 1-18: execution tracker.** Release history, open limits,
  exact milestones, acceptance criteria, checkboxes, dependency pins, current
  module program, and MCP integration.
- **Part II, P0-P27: design dossiers.** The merged `uWZ-Disadvantages.md`.
  Problem statements, rejected alternatives, detailed designs, memory/perf
  evidence, and reference comparisons against Dusty and nilo.
- **Part III, Section 19: release checklist.** The final gate list for a
  release; it does not replace the milestone evidence in Parts I and II.

**Authority:** Part I wins for *what to do now*, current release numbering, and
checkboxes. Part II wins for *why*, design constraints, and the evidence a
change must produce. Section 19 wins for *ship/no-ship*. When a design dossier
and a milestone appear to conflict, the milestone is current; update the
dossier in the same PR.

**Current horizon:**

| Horizon | Work | Where |
| --- | --- | --- |
| Open patch | 2.5.5: XEV-006/XEV-007, scheduler fail-stop, macOS runtime, H2/TLS matrix, lsquic sync | Section 11.1 |
| Release preflight | Install `caldoai/skills --skill untangle-codebase` and wire it into the agent roster before 2.5.5 work | Section 11.1.0 |
| Toolchain | Zig 0.17: install `zig-0-17`, remove `zig-0.16`, update skill lock and agent prompts | Section 11, R-6.1 |
| Module track | `uz.sql`, `uz.s3`, `uz.jobs`, `uz.memory_cache`, `uz.sessions`, `uz.jwt`, `uz.proto`, `uz.metrics`, `uz.trace` | Section 17 |
| Agent surface | MCP server over Streamable HTTP, tools derived from OpenAPI/JSON-RPC | Section 18 |
| Hardening | v3.0.0-v3.9.0 security boundary closure | Section 16 |
| Design depth | Engine seam, idle memory, build weight, docs, budget, client, handler I/O, typed API, modules | Part II P5-P15 |

**Crosswalk:**

| Workstream | Part I tracker | Part II dossier |
| --- | --- | --- |
| Engine seam / libxev boundary | Sections 5, 7.2, 16.5 | P5, P18 |
| Idle memory and HTTP/2 storage | Sections 6, 17 | P6 |
| Build weight and feature gates | Sections 17.3, 17.15 | P7 |
| Docs, API reference, first run | Section 8, 17.13 | P8 |
| Four-axis quality budget | Section 1.4, 6, 17.15 | P9 |
| Windows runtime evidence | Sections 7.2, 16.5 | P10 |
| Zig 0.17 upgrade | Section 11 (R-6, R-6.1), 11.1 | P11 |
| Client completeness | Section 16.11 | P12 |
| Handler I/O and streaming bodies | Sections 8, 17.3 | P13 |
| Typed handler layer | Section 17.18 | P14 |
| Full-stack modules | Section 17 | P15 |
| MCP integration | Section 18 | Section 18 plus P15 security rules |
| Security closure | Section 16 | P18, P19, P20 |

**Non-negotiables:** keep the `farbenbuilds/libxev` fork; Zig 0.16 now and
0.17 later; zero request-path allocation; fixed capacity and explicit
exhaustion; per-worker ownership; shared-nothing; C ABI core-only; optional
modules; no new build-time Python/CMake/Ninja/Go/Perl; no weakened gate. Before
the Zig 0.17 upgrade, install `zig-0-17` and remove `zig-0.16` exactly as
section 11, R-6.1 requires.

---

## 1. How to use this guide

### 1.1 Human workflow

1. Read the limit inventory in section 4.1 and pick the next open milestone.
2. Work milestones in the order given in section 4.6. Do not start a later
   milestone while an earlier one has missing required evidence.
3. For a full-stack module task, use section 17 as the canonical task list and
   `uWZ-Disadvantages.md` for the design rationale and acceptance evidence.
   The module track may run beside the v3 security closure only when its
   dependency rows in section 17 are green.
4. A limit may close in exactly two ways:
   - it is fixed and verified, or
   - it is re-declared with a linked reason, raw evidence, and an explicit
     restoration criterion.
   No limit closes by deleting a test, skipping a gate, lowering a threshold,
   or writing a claim without artifacts.
4. Update `CHANGELOG.md`, `docs/`, and the relevant ADR in the same change that
   closes or re-declares a limit.

### 1.2 Agent workflow

Every milestone follows the repository agent sequence:

| Phase | Agent | Required output |
| :--- | :--- | :--- |
| Architect | `architect` | Scope, assumptions, affected ownership boundaries, acceptance criteria, file list |
| Implementer | `developer` plus the domain specialist (`transport_io`, `http_protocol`, `crypto_tls`, `build_vendor`, `verification`, ...) | Diff, commands run, raw results, unresolved questions |
| Reviewer | `reviewer` | Independent correctness/security/compatibility/convention review with file and line references |
| Integrator | `integrator` | Combined diff check, required verification evidence, delivery summary |

Rules:

- Do not advance past a phase while its required output is missing.
- Never claim an unrun check passed. Report exact commands and their output.
- Keep edits to shared files serialized; parallelize only independent slices.
- Do not add `TODO`, `FIXME`, `XXX`, or `HACK` markers to the repository. This
  document is the tracker.
- Full-stack module work follows the same four phases. There is no dedicated
  SQL/S3/jobs/cache agent in the current roster; use `developer` with
  `http_protocol` for wire/clients, `crypto_tls` for secrets and verification,
  `dx_router` for the service surface, and `verification` for vectors and
  integration tests. The architect must name one module owner in the scope.
- **Zig toolchain skill refresh is mandatory.** Before any Zig 0.17 upgrade
  work, install the 0.17 skill and remove the 0.16 skill:
  ```sh
  npx skills add https://github.com/zigcc/skills --skill zig-0-17
  npx skills remove zig-0.16 -y
  ```
  Then update `skills-lock.json`, `.opencode/agents/*.md`,
  `.codex/agents/*.toml`, `AGENTS.md`, `CONTRIBUTE.md`, and every agent prompt
  that names the old skill. Verify with `npx skills list --json` and the
  checks in section 11, R-6.1. Do not hand-edit a vendored `SKILL.md`. Do not
  confuse the `zig-0.16` skill with the `uwz/zig-0.16` libxev integration
  branch; the branch is renamed only when the 0.17 fork branch lands.
- **2.5.5 release preflight.** Install the codebase-understanding skill before
  starting the patch:
  ```sh
  npx skills add caldoai/skills --skill untangle-codebase
  ```
  Then wire it into the architect, developer, reviewer, and integrator prompts.
  The full checklist is section 11.1.0.

### 1.3 Repository gates after every code change

```sh
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
sh scripts/check_docs.sh
zig build test
```

Additional gates by touch point:

| Touch point | Gate |
| :--- | :--- |
| Memory or transport | `zig build test -Dsanitize=true -Doptimize=ReleaseSafe` |
| Portability | `zig build test-compile -Dtarget=x86_64-windows-gnu` and `-Dtarget=aarch64-macos` |
| Public API | `tests/package_consumer` `zig build check -Doptimize=ReleaseSafe` |
| WebSocket framing | Autobahn target |
| HTTP/1.1 parsing/framing | h1spec target |
| HTTP/2 or HPACK | Centralized malformed-frame, flow-control, Huffman, table-size, header-list tests |
| HTTP/3 | `http3_server` build plus the pinned curl/ngtcp2 and aioquic gate |
| Module (FS-0 through FS-10) | Feature-gate disabled build, unit/vector tests, mock or live integration, allocation test, secret-redaction test, fuzz where the module parses peer input |
| Fuzzing | `zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe` and `oss-fuzz-smoke` |

### 1.4 The evidence contract

Every benchmark or load result used to close a limit stores, in one directory:

- source URL and retrieval time of every tool used;
- exact uWebZockets commit or tag, Zig version, dependency pins, and
  `flake.lock` hash;
- CPU model, core count and quota, affinity policy, SMT state, kernel version,
  governor, and memlock limit;
- libxev backend (`io_uring` or `epoll`), optimization mode, worker count;
- load generator version, threads, connections, streams, duration;
- HTTP version, keep-alive, TLS version, compression settings;
- exact request and response bytes;
- warmup, sample count, statistic, and spread;
- success and error rates plus CPU, RSS, and tail latency;
- listener ownership and run-status evidence.

Never combine numbers from different systems into one ratio. Treat a changed
backend, kernel, worker count, or workload as a new cohort and a new series.
Never edit generated benchmark output by hand.

### 1.5 Never do these

- Do not disable leak detection, `halt_on_error`, or a sanitizer check.
- Do not delete, skip, or weaken a test to make a graph green.
- Do not change benchmark window sizes, buffer caps, or worker counts before a
  probe shows that the cost is real.
- Do not publish a number that a reviewer cannot reproduce from the raw
  artifacts.
- Do not replace an accepted socket or read result with `Canceled` without a
  documented disposal rule.
- Do not modify or move the `v2.1.6` tag, release, or commit.
- Do not modify the HttpArena repository data by hand.
- Do not use ephemeral development certificates for recorded measurements.

---

## 2. Release roadmap overview

```mermaid
timeline
    title uWebZockets Modular Release Timeline
    section Evidence and Platform Closure
        v1.9.0 : Declared-Limits Closure (H2/TLS evidence, Windows runtime, MSan decision)
    section Core Performance
        v2.0.0 : Multi-Core Scaling, Write Coalescing, SIMD WS, Deflate Pooling
    section Fullstack Milestones
        v2.1.0 : Hierarchical Timing Wheel and Non-Blocking Sleep Engine
        v2.1.5 : API Hardening and Worker Manager
        v2.2.0 : Streaming IO, Multipart Parser and Zero-Copy Sendfile
        v2.3.0 : uz.sql: PostgreSQL, SQLite, Typed Rows and Migrations
        v2.4.0 : Comptime-Validated HTML SSR and SIMD Escaping
        v2.5.0 : uz.proto and Native gRPC Engine over HTTP2
        v2.5.5 : XEV-006/XEV-007, macOS runtime, H2 evidence, lsquic sync
        v2.6.0 : Server-Sent Events (SSE) and Streaming Tokens
        v2.7.0 : uz.sessions, uz.jwt, Cookies, Rate Limiting and Auth
        v2.8.0 : uz.metrics, uz.trace, Diagnostics and OTLP
        v2.9.0 : Zero-Downtime Hot Reload, Graceful Drain and Multi-OS CI
        v2.10.0 : uz.s3 Object Storage (provisional slot)
        v2.11.0 : uz.jobs Durable Queue and Scheduler (provisional slot)
        v2.12.0 : uz.memory_cache In-Process Cache (provisional slot)
        v2.13.0 : Module Integration, Recipes and Docs
        v2.14.0 : MCP Server Integration over Streamable HTTP (provisional)
    section Security Boundary Closure
        v3.0.0 : Boundary Register, Threat Model and Evidence Baseline
        v3.1.0 : Event Loop, Completion and Windows Boundary Closure
        v3.2.0 : HTTP/1.1 and HTTP/2 Trust Boundary Closure
        v3.3.0 : WebSocket and Compression Boundary Closure
        v3.4.0 : QUIC and HTTP/3 Boundary Closure
        v3.5.0 : TLS, Identity, Authentication and Secrets
        v3.6.0 : Ownership, Router and C ABI Boundary Closure
        v3.7.0 : Outbound Client Boundary Closure
        v3.8.0 : Platform, Operations and Supply Chain
        v3.9.0 : Assurance, Disclosure and Final Boundary Closure
```

| Version | Milestone theme | Primary deliverables | Acceptance target |
| :---: | :--- | :--- | :--- |
| **v1.9.0** | **Declared-Limits Closure** | H2/TLS scaling evidence, HttpArena `baseline-h2` restore, Windows runtime support, MSan scope decision, follow-up decisions | Every limit in section 4.1 closed or re-declared with linked raw evidence |
| **v2.0.0** | **High-Throughput Scaling** | Pipelined write coalescing, uncapped workers, SIMD WebSocket batching, deflate pooling, measured H2 tuning | Baseline > 3.5M RPS, pipelined > 10M RPS, P99 <= 160 us on the designated host |
| **v2.1.0** | **Timer Wheel & Deadlines** | Hierarchical timing wheel, async `/delay`, connection idle timeouts | Timer, parking, and idle/header deadlines unit-tested; HttpArena `async` adapter remains 2.2-C3 |
| **v2.1.5** | **API Hardening & Worker Manager** | Typed cluster lifecycle, worker failure detail, publish reports, worker-group extraction, TODO/docs cleanup | Public cluster API and package consumer stay source-compatible; full matrix green |
| **v2.2.0** | **Streaming & Static Assets** | Multipart streaming, chunked transfers, `sendfile`, 100 KiB TLS echo | HttpArena `8gbit` and `static-*` active |
| **v2.3.0** | **SQL Module** | `uz.sql`: pure-Zig PostgreSQL wire client, optional SQLite backend, per-worker pools, typed rows, migrations | PostgreSQL and SQLite integration tests pass; `async-db`/`crud` active; no request-path allocation |
| **v2.4.0** | **Comptime SSR Engine** | Comptime HTML parser, SIMD entity escaping, `/fortunes` renderer | HttpArena `fortunes` active |
| **v2.5.0** | **Proto and gRPC** | `uz.proto` shared wire codec, protobuf framing, 5-byte length prefix, HTTP/2 trailers (`grpc-status`) | `unary-grpc` and `unary-grpc-tls` active; proto vectors pass |
| **v2.5.5** | **Follow-up Closure** | XEV-006 timer carry, XEV-007 queued cancellation, scheduler fail-stop, macOS runtime, H2/TLS matrix, lsquic sync | Open C-items fixed or re-declared; macOS/Windows evidence; patch release |
| **v2.6.0** | **Real-Time Push (SSE)** | `text/event-stream`, HTTP/1.1 chunking, HTTP/2 DATA framing, `Last-Event-ID` | Sub-millisecond event broadcast, zero leaks |
| **v2.7.0** | **Sessions, JWT, and Security** | `uz.sessions` sealed-cookie sessions, `uz.jwt` HS/RS/ES/EdDSA and JWKS, cookies, rate limiter, CORS | Session tamper/replay and JWT algorithm-confusion suites pass; HttpArena `production-stack` auth ready |
| **v2.8.0** | **Metrics and Tracing** | Expanded `uz.metrics`, lock-free counters/histograms, `/metrics`, `uz.trace`, W3C context, OTLP/HTTP export | Zero overhead on request hot paths; OTLP golden tests pass |
| **v2.9.0** | **Reliability & Multi-OS** | Graceful drain, socket takeover, multi-OS CI | Clean multi-OS test matrix, zero-downtime reload |
| **v2.10.0** | **Object Storage** (provisional) | `uz.s3`: SigV4, presigned URLs, streaming GET/PUT, multipart, bounded retries | Mock S3 vector suite and optional MinIO gate pass |
| **v2.11.0** | **Durable Jobs** (provisional) | `uz.jobs`: SQL-backed queue, enqueue-in-transaction, leases, retries, schedules | At-least-once claim, retry, and shutdown tests pass |
| **v2.12.0** | **In-Process Cache** (provisional) | `uz.memory_cache`: fixed-capacity typed keyspace, TTL, eviction, stats | No allocation after init; hit/miss/eviction tests pass |
| **v2.13.0** | **Module Integration** | Service lifecycle, feature flags, recipes, docs, C ABI boundary statement | Every module has a runnable example and a gate |
| **v2.14.0** | **MCP Server** (provisional) | `uz.mcp`: tool metadata from OpenAPI, `tools/list`, `tools/call`, Streamable HTTP, SSE, sessions, auth, tracing | MCP Inspector/tools-only conformance passes; no tool-call secret leakage |
| **v3.0.0** | **Boundary Register & Baseline** | Boundary IDs, threat model, evidence contract, supply-chain and disclosure baseline | Every `SECURITY.md` claim classified, owned, and linked to evidence |
| **v3.1.0** | **Event Loop & Platform** | Completion lifecycle, IOCP, UDP GRO, signals, backend policy, runtime sanitizers | No stale completion, Windows runtime green, all backends soak-tested |
| **v3.2.0** | **HTTP/1.1 & HTTP/2** | Smuggling matrix, header/body limits, HPACK and flow control, RFC 8441 tunnels | h1spec and centralized HTTP/2 gates green with no exclusions |
| **v3.3.0** | **WebSocket & Deflate** | Handshake, UTF-8, fragmentation, control frames, RFC 7692, pub/sub backpressure | Autobahn 517/517, fuzz clean, no decompression amplification |
| **v3.4.0** | **QUIC & HTTP/3** | QPACK, stream/header/body bounds, GSO/GRO datagrams, WebTransport, QUERY | Cross-implementation HTTP/3 gate green, WebTransport decision closed |
| **v3.5.0** | **TLS, Identity & Secrets** | Certificate policy, mTLS, 0-RTT, rotation, session tickets, kTLS, auth/rate limits | Fail-closed identity paths, zeroized secrets, accepted/deferred ADRs |
| **v3.6.0** | **Ownership, Router & C ABI** | Captures/middleware caps, async tokens, borrowed slices, C ABI layout, fixed slabs | Misuse suite and C/C++ consumer pass under ASan/LSan |
| **v3.7.0** | **Outbound Client** | TLS verification, redirects/cookies/proxy policy, response parser, pool isolation | Loopback and malformed-server suites pass, no trust-rule reuse |
| **v3.8.0** | **Platform, Operations & Supply Chain** | Windows/BSD matrix, deployment limits, drain, SBOM, licenses, release provenance | Support claims match CI, supply-chain evidence reproducible |
| **v3.9.0** | **Assurance & Final Closure** | Full fuzz campaign, external audit, disclosure drill, register closure | Zero open boundaries; every remaining boundary accepted with ADR |

The v3.x track is a security boundary closure program, not a feature expansion.
A boundary is closed only when it is fixed and proven, hardened with evidence,
or explicitly accepted with an ADR and review trigger. Deleting a limitation
from `SECURITY.md` without evidence is not closure.

The GraphQL Wire Transport plan that was originally scheduled for v1.9.0 is
preserved in section 5 as a deferred feature track. Assign it a release number
after the v1.9.0 closure milestone lands, so measurement and platform evidence
do not compete with new surface area.

---

## 3. Ground rules and coding conventions

All code changes across all milestones must strictly comply with
`CODING_CONVENTION.md` and `docs/roadmap.md`:

- **Shared-nothing, thread-per-core:** retain per-core event loop isolation.
  Each worker owns its slab exclusively. No cross-thread locking or mutex
  contention on request paths.
- **Zero heap allocations on hot paths:** proposals introducing dynamic
  allocation during request dispatch or WebSocket framing are rejected by
  policy. Bounded buffers only.
- **Explicit types and pure functions:** no OOP, no hidden state, pure
  functions for parsing/validation/encoding, explicit named types (no
  `anytype` in public APIs), no `std.debug.print`, no emojis, Linux-style
  early returns.
- **Validation suite:** run the gates in section 1.3 after every change.
- **Knowledge graph:** keep synchronized with `graphify update .`.

---

## 4. Version 1.9.0: Declared-Limits Closure and Measurement Evidence

> Historical closure context. The 1.9.0 release shipped; these checkboxes
> preserve the planning record. Unchecked rows are superseded by later release
> evidence and are not open 2.2.0 work. The current release line is 2.2.0.

**Objective:** close every limit that the v1.8.5 and v1.8.9 deliveries
declared, produced tooling for, or deferred, and leave the repository in a
state where every remaining boundary is a dated, documented decision instead
of an open question.

**Theme rule:** this release contains no speculative performance work. Every
code change is the smallest patch that a measurement or a failing test
requires. Tooling and evidence may land without code changes.

### 4.1 Limit inventory

| # | Limit or boundary | Current state after 1.8.9 | Closes in |
| :-: | :--- | :--- | :--- |
| L1a | No 256/1,024-connection H2-over-TLS run in this repository | `h2-tls-scaling-v1` contract, env, runner, and real-PEM example shipped; rows unmeasured | M1 |
| L1b | HttpArena `baseline-h2` profile withdrawn | Adapter changes not made; official run not attempted | M2 |
| L2 | io_uring ring-pressure retry had no deterministic test | Closed in 1.8.9: pure `ring_retry_decision` plus branch tests | Closed |
| L3a | Threaded tests skipped under ASan/MSan | Closed in 1.8.9: all 17 threaded tests run under ASan with `use_sigaltstack=0` | Closed |
| L3b | Windows runtime coverage | Test plumbing ported; two runtime blockers remain; workflow compile-only | M4 |
| L4 | MemorySanitizer scope ambiguous for TLS/cluster paths | Dependency-boundary smoke is the current contract; decision not written as permanent | M5 |
| L5 | `Cluster.request_shutdown` after `deinit` is a silent no-op | Documented in `docs/api.md` and `docs/troubleshooting.md`; no API guard | M6-1 |
| L6 | TLS credential rotation requires a rolling restart | Documented in ADR 0002 and `docs/deployment.md`; hot reload has no ADR | M6-2 |
| L7 | Backend selection is process-sticky; `xev` stays internal | Documented in `docs/architecture.md`; `error.BackendChanged` is deliberate | M6-3 |
| L8 | Shared-port TLS test flaked under ephemeral-port pressure | 1.8.9 retries eight fresh reservations; no flake observed since | M6-4 |
| L9 | Per-worker session tickets block cross-worker resumption | Not measured | M1 probe, then M6-5 |
| L10 | H2 window/flow-control tuning was proposed, not measured | No change made; must be evidence-gated | M3 (conditional) |
| L11 | H2/TLS benchmark is not in GitHub Actions | Deliberate: shared runners cannot satisfy the evidence contract | M7 |
| L12 | Post-merge provenance archive and clean-clone check | Maintainer tags the merged release after review; agents archive the gate results once the tag exists | M0 |
| L13 | Windows was never officially supported | Re-declared until M4 passes | M4 |
| L14 | mTLS and QUIC/HTTP/3 clustering were never promised | Remains a documented boundary; needs an ADR only if requested | Out of scope |

**Sources for this inventory:** the `Limits` section of `CHANGELOG.md` for
1.8.9, the `Current status` section of
`benchmarks/h2_tls_scaling_guarantee.md`, the `Windows runtime blocker
details` and deliberate-boundary table in `docs/roadmap.md`, the scope
boundaries in `docs/adr/0002-tls-cluster-lifecycle.md`, and the v1.8.5/v1.8.9
declared-limits handoff. Update this table in the same pull request that closes
or re-declares a row; never leave a closed row without a linked test, artifact,
or decision record.

### 4.2 Milestone M0: Post-merge provenance and clean-clone verification

**Why:** every later measurement names an exact artifact, and the arena
restores profiles against released tags and immutable hashes.

**Tag ownership:** the maintainer creates and pushes every release tag after
reviewing and merging the release pull request. Agents never create, move, or
push tags, and must not treat a missing tag as an open task. Wait for the
maintainer's tag before producing artifacts that name it.

Tasks:

- [x] Confirm PR #94 (`release/v1.8.9-declared-limits`) is merged and `main` is
      green.
- [x] Wait for the maintainer to create the release tag after review and
      merge.
- [x] After the tag exists, record the tag, merge commit SHA, minimum Zig
      version (0.16.0), and the shipped contract identifier
      (`h2-tls-scaling-v1`) in the release notes.
- [x] From a fresh clone of the tag and an empty Zig cache, run
      `zig build test --summary all` and archive the output.
- [x] Archive the current Debug, ASan/UBSan, ReleaseSafe, Windows compile,
      macOS compile, and package-consumer results next to the benchmark
      artifacts.
- [x] Confirm `sh scripts/check_release_version.sh`, `check_docs.sh`, and
      `check_conventions.sh` pass at the tag.

**Acceptance:** the maintainer-created tag checks out cleanly; the fresh-cache
build is green; provenance is archived; no local cache or uncommitted file is
required.

**Owners:** maintainer (tag creation and review); `build_vendor` runs the
clean-clone check after the tag exists.

### 4.3 Milestone M1: H2/TLS scaling characterization (closes L1a)

**Objective:** produce reproducible, protocol-equivalent H2-over-TLS evidence
at 256 and 1,024 connections on one host, with plaintext/h2c and single-loop
TLS controls, and fill the probe table with measurements instead of
hypotheses.

The contract already exists and must not change silently:

- `benchmarks/h2_tls_scaling_guarantee.md` (contract)
- `benchmarks/h2_tls_scaling_v1.env` (machine-readable parameters)
- `scripts/benchmark_h2_tls.sh` (runner)
- `examples/tls_cluster.zig` (PEM/worker/capacity/affinity overrides)

Changing any parameter requires a new benchmark ID and a new series.

#### M1-1 Prepare the host and the artifact

- [x] Record one named shared development host and label the evidence
      non-quiet. The archived run records an AMD Ryzen AI 7 350, 8 physical
      cores/16 logical CPUs with SMT, powersave governor, Linux 7.2.2,
      `RLIMIT_MEMLOCK=8192 KiB`, `UWZ_CPU_AFFINITY=0`, and io_uring. It is not
      a quiet-host competitive claim.
- [x] Build the cluster with real PEM credentials and TLS 1.3 at
      `-Doptimize=ReleaseFast`. Do not use `enable_https_ephemeral` for
      recorded rows.
- [x] Confirm the configured `UWZ_MAX_CLIENTS` exceeds the peak connection
      count so no row closes connections for capacity reasons.
- [x] Verify the runner fails closed: run one cohort with a deliberately wrong
      response body and confirm the script reports failure.

#### M1-2 Reproduce the original failure honestly

- [x] Run 256 connections against the single-app `init_https` control. Expect
      it to serve; record requests/s, latency, CPU, and RSS.
- [x] Run 1,024 connections against the same single-app control and capture the
      failure mode: h2load counters, `ss` state, server logs, CPU, RSS, active
      worker count. This is the baseline the cluster must beat.
- [x] Run the same levels against the plaintext cluster control and the TLS
      cluster. Capture per-worker accept counts from the metrics registry and
      the memlock state.
- [x] Alternate A/B order across at least five rounds. Report median and
      spread, never a single peak.

#### M1-3 Characterize before optimizing

Fill this table with measurements and attach raw artifacts. Do not tune until
one row is proven by samples.

| Hypothesis | Probe | Evidence required | Result |
| :--- | :--- | :--- | :--- |
| Single-loop saturation (expected) | Compare 1-, 2-, 4-worker clusters at 1,024 connections | 83k / 155k / 277k req/s at one stream and 291k / 502k / 669k at eight streams; p99 falls with workers | Confirmed; no flow-control change made |
| Accept-path imbalance | Per-worker `connections_accepted`; kernel 4-tuple hashing check | 4-worker TLS spread 4.8 percent; 2-worker split 48.5 / 51.5 percent | No imbalance observed |
| Handshake cost dominates | CPU profile during a connect storm; full vs resumed handshakes | TLS throughput is 49-84 percent of plaintext; 1 worker 20 new/100 reused, 4 workers 97 new/23 reused | Visible but not collapsing; per-worker tickets accepted in ADR 0003 |
| Stream or flow-control stall | HTTP/2 window occupancy, write-queue depth, p99 vs connections | Zero failures/timeouts in 30 TLS and 30 plaintext samples; p99 rises smoothly | No stall observed |
| Slab capacity | Compare `max_connections` above peak connections | `UWZ_MAX_CLIENTS=2048` above the 2,048 peak; zero capacity errors or closes | Capacity sufficient |
| Per-worker session tickets | Count resumed vs full handshakes during a reconnect storm | 1 worker 20 new/100 reused; 4 workers 97 new/23 reused; 0 failures | Bounded by per-worker ticket keys; feeds M6-5 |
| Profiling availability | `perf_event_paranoid` and h2load connect rows | Kernel profiling restricted on the host; user-space connect/TTFB and CPU/RSS samples archived | No kernel profile claimed |

- [x] Capture the closest available profile. Kernel `perf` was unavailable
      under the host's `perf_event_paranoid` setting; user-space connect/TTFB
      rows, CPU, and RSS samples are archived in the evidence bundle.
- [x] If a change is proposed: smallest patch for the measured cost, with a
      mixed-workload control and unchanged capacity/error behavior. Keep it
      only if repeated same-host runs beat run-to-run spread with no p99 or
      error regression.

**Acceptance:** raw artifacts and the filled table; the TLS cluster shows
nonzero RPS at 1,024 connections on this host; every optimization decision is
traceable to a probe row.

**Deliverables:** results directory (or results branch) with raw h2load output,
profiles, logs, and a summary; contract status updated; `docs/` links added.

**Owners:** `verification` (contract and runs), `transport_io` (profiles),
`http_protocol` (HTTP/2 frame interpretation).

### 4.4 Milestone M2: Restore HttpArena `baseline-h2` (closes L1b)

**Objective:** restore the withdrawn profile with the public API only and
publish raw evidence. Depends on M0 and M1.

#### M2-1 Adapter changes (HttpArena repository, not this one)

- **External:** `frameworks/uwebzockets/build.zig.zon`: pin the released tag
      and immutable hash with `zig fetch --save`. The adapter lives in the
      HttpArena repository; this PR does not modify or run it.
- **External:** `frameworks/uwebzockets/src/main.zig`: replace the single-app
      TLS listener with the cluster profile. No adapter-side private API or TLS
      setup is permitted.
- **External:** use the public API only and keep HTTP/3 on its own listener.
- **External:** `frameworks/uwebzockets/meta.json`: restore `"baseline-h2"`
      only after M1 and local validation are green.
- **External:** build the adapter from a clean dependency cache.

#### M2-2 Validation and official run

- **External:** run the HttpArena validation suite locally before requesting
      anything.
- **External:** trigger `/benchmark -f uwebzockets --save` on the pull
      request.
- **External:** confirm nonzero 256/1,024 rows, only expected success
      statuses, no systematic broken-pipe/disconnect pattern, no unexplained
      timeouts, and fresh official results.
- **External:** commit regenerated results and logs only after the official
      run succeeds. Never edit generated benchmark data by hand.

**Status:** no official HttpArena `baseline-h2` run is claimed for 2.2.0. The
adapter and official run remain owned by the HttpArena maintainers.

#### M2-3 If it still fails

Follow the retreat decision tree:

1. Fix the adapter if the adapter is wrong, then rerun.
2. Withdraw only the subscription if the library cannot support the protocol;
   disclose, keep the raw evidence, and track it as a separate limit.
3. If a supported feature fails, keep the failing evidence, fix the library
   with a regression test, then restore the profile.

A removal reason must link raw logs and the exact diff and must name the
restoration criterion. Never remove a valid low-throughput profile to raise
the composite.

**Acceptance:** released tag works from a clean cache; lifecycle and error
tests pass; validation passes with the profile restored; both connection
levels complete with nonzero RPS; responses succeed; only the standard API is
used; the official run saved fresh results.

**Owners:** `integrator` (adapter and run), maintainer (tag), `verification`
(raw artifact audit).

### 4.5 Milestone M3: HTTP/2 flow-control work, only if M1 proves it

**Objective:** fix the H2 window/stream stall only when M1 shows it, and never
preemptively.

- [x] If M1 shows window or write-queue stalls, record the occupancy evidence
      and the exact failing step.
- [x] Candidate changes to evaluate against the control: larger initial stream
      and connection windows (for example 1 MiB) and proactive
      `WINDOW_UPDATE` emission before depletion.
- [x] Add regression coverage for stack flow control and stream capacity even
      if no production change lands.
- [x] Keep capacity constants and error behavior unchanged unless a new
      capacity contract is written.
- [x] If M1 shows single-loop saturation instead, close L10 as measured and
      make no window change.

**Acceptance:** either a measured fix with repeat-run evidence and no p99 or
error regression, or a recorded "measured, not needed" decision.

**Owners:** `http_protocol` plus `transport_io`; `verification` confirms.

### 4.6 Milestone M4: Windows runtime support (closes L3b and L13)

**Objective:** make `windows.yml` run tests natively and pass, with no
weakened assertions. The two blockers are already documented in
`docs/roadmap.md`.

#### M4-1 Blocker A: libxev IOCP accept lifecycle (upstream)

**Symptom:** after a successful `AcceptEx`, the IOCP backend returns the
accepted socket but never clears `op.accept.internal_accept_socket`. A
persistent accept loop re-arms the completion, `start_completion` calls
`AcceptEx` on the already-connected socket, Windows returns `WSAEINVAL`
(10022), and libxev panics mapping the unmapped error.

**Minimal fix:** null the field on both the success and the error paths of the
accept completion.

- [x] Check the pinned libxev revision against upstream for a merged fix.
- [x] Prefer moving the pin to a revision that contains the fix. Update every
      dependency view (`build.zig.zon`, `.json`, `.nix`, `.txt`) and the
      recorded hash.
- [x] If no fixed revision exists, decide between waiting on upstream and
      carrying an auditable patch. A patch requires: upstream issue link,
      patch file under `patches/`, the same four dependency views updated, a
      note in `THIRD_PARTY_NOTICES.md`, and a decision record. No undocumented
      fork and no patching files inside `zig-pkg`; the maintained fork policy
      and ledger are in [docs/libxev_fork.md](docs/libxev_fork.md) and
      [ADR 0005](docs/adr/0005-libxev-fork.md).
- [x] Add a standalone probe or unit test that exercises a second accept on the
      same completion and fails without the fix.

#### M4-2 Blocker B: queued completions on the Windows close path (this project)

**Symptom:** with the accept fix applied, shutdown reports
`ShutdownIncomplete` because a connection stays in the pool with
`is_writing = true`. `Completion.state()` maps both `.adding` (queued, not yet
submitted) and `.active` to `.active`, so the close branch never clears
`is_writing`/`read_active` for a completion canceled before submission; the
target is marked `.dead` and only the cancel callback fires.

- [x] Distinguish queued from submitted completions at the transport layer.
      Either submit before canceling, or track submission explicitly beside
      `read_active`/`is_writing`.
- [x] Clear the flags for every completion whose callback will never fire so
      the slot returns to the pool exactly once.
- [x] Add a regression test that cancels a queued write before submission and
      asserts the slot is released and `verify_shutdown` completes.
- [x] Keep the POSIX paths unchanged; the fix must be provably Windows-local
      or clearly shared and covered on both.

#### M4-3 Native Windows runtime job

- [x] Extend `.github/workflows/windows.yml` with a job that runs the test
      suite natively (`zig build test --summary all`) on `windows-2025` in
      addition to the compile gates.
- [x] Document which suites are expected to run there. If a test cannot run
      for a principled reason, it returns `error.SkipZigTest` with a
      why-comment; compile-only gates stay.
- **External:** the cluster TLS tests must execute, not skip. The native
      Windows runtime job exists, but its last recorded run (40094814541,
      2026-10-24) was red; native support is not claimed.
- **External:** update `CI_CD_PIPELINE.md` and `docs/roadmap.md` to remove the
      compile-only declaration only after the runtime job is green for a
      release commit.

**Acceptance:** the three cluster TLS tests plus pool shutdown and lifecycle
tests execute and pass on Windows CI; no `@compileError`; no assertion was
dropped or weakened; the workflow includes the runtime job.

**Owners:** `transport_io` (completion policy), `build_vendor` (dependency pin
and workflow), `verification` (runtime matrix).

**Risks:** upstream release timing; Windows runner availability; keeping the
patch surface auditable if a fork becomes necessary.

### 4.7 Milestone M5: MemorySanitizer scope decision (closes L4)

**Objective:** end the ambiguity with a written decision, not code churn.

Option A (preferred unless there is a concrete need):

- Keep the dependency-boundary smoke as the permanent MSan contract.
- Record why: Zig 0.16 emits no MSan instrumentation for Zig code, and full
  BoringSSL instrumentation would require rebuilding and maintaining a second
  TLS toolchain.
- Write the decision into `docs/deployment.md` and `CI_CD_PIPELINE.md`, and
  reference it from `docs/roadmap.md`.

Option B:

- Instrument BoringSSL and run the full suite under MSan. This requires a
  toolchain that emits Zig MSan instrumentation and a supported instrumented
  BoringSSL build; it becomes its own milestone with its own ADR.

Tasks:

- [x] Choose A or B at the start of the milestone and record the choice in an
      ADR or a dated decision section in `CI_CD_PIPELINE.md`.
- [x] If A: link the paragraph in the roadmap and close the boundary as
      permanent, not temporary.
- [x] If B: file the toolchain prerequisites as blocking items and keep the
      dependency-boundary smoke as the interim contract.

**Acceptance:** the repository states one unambiguous MSan contract with a
date and a reason.

**Owners:** `verification` with `build_vendor`; maintainer decides.

### 4.8 Milestone M6: Follow-up decisions and API hygiene (closes L5 to L9)

Each item below is independent. Close each with code, documentation, or a
dated re-declaration.

#### M6-1 `Cluster.request_shutdown` after `deinit`

**Status:** closed in 2.1.5. `Cluster.state()` exposes `releasing`/`released`,
`deinit_checked()` returns `error.ClusterRunning`, and `request_shutdown` stays
a documented no-op in those states ([ADR 0007](docs/adr/0007-cluster-lifecycle-and-failures.md)).

- [x] Add a public lifecycle state and a checked release path instead of a
      one-off `is_deinitialized` predicate.
- [x] Keep the documented no-op and state it at the call site.
- [x] Acceptance: users can inspect the lifecycle and cannot be surprised by
      the no-op without documentation saying so.

#### M6-2 TLS credential rotation

Current state: `enable_https` reads credentials once per worker; rotation
requires a rolling restart.

- [x] Decide whether hot reload is needed. If yes, write an ADR covering the
      per-worker atomic context swap, in-flight connection safety, and rollback.
- [x] If no, keep the rolling-restart guidance in `docs/deployment.md` and
      mark the boundary as a decision, not an omission.
- [x] Acceptance: the boundary is either implemented and tested or dated and
      documented.

#### M6-3 Backend stickiness and `error.BackendChanged`

Current state: documented in `docs/architecture.md`; `xev` stays internal.

- [x] Keep `xev` internal. If any public API needs backend introspection, write
      an ADR first.
- [x] Acceptance: no new public surface without an ADR; docs remain accurate.

#### M6-4 Shared-port test stability

Current state: eight bounded fresh reservations in 1.8.9; no flake observed.

- [x] Watch the test across releases. If a flake reappears, move to distinct
      preregistered ports or a held reservation with a documented kernel
      distribution caveat.
- [x] Acceptance: repeated suite runs stay green, or the fix is replaced with
      a more deterministic scheme.

#### M6-5 Cross-worker session resumption

Current state: each worker owns its `SSL_CTX`, so session tickets do not
resume across workers. M1 measures the full vs resumed handshake mix.

- [x] If resumption matters for the target workload, write an ADR for shared
      ticket keys and measure the TLS-state sharing cost.
- [x] If it does not, record the measured mix and close the boundary as
      accepted.
- [x] Acceptance: a measured decision, not a preference.

### 4.9 Milestone M7: Evidence archive and CI decision (closes L11 and L12)

- [x] Archive M1 and M2 raw artifacts with the release. Keep the directory
      append-only and never edit generated output.
- [x] Update `benchmarks/h2_tls_scaling_guarantee.md` "Current status" with the
      measured result and the exact artifact location.
- [x] Keep `h2-tls-scaling-v1` out of `benchmark.yml` while runners are shared.
- [x] When a dedicated quiet runner exists, add a `workflow_dispatch`-only,
      non-gating job that runs the contract, uploads raw artifacts, and records
      provenance. It must never compare shared-runner numbers to the dedicated
      host.
- [x] Leave `http-throughput-v1` untouched. If its parameters must change, cut
      a v2 contract and a new history series.
- [x] Acceptance: every published number links to raw artifacts on a named
      host, and CI enforces only what it can reproduce reliably.

### 4.10 Sequencing, owners, and release gates

Suggested order: **M0 -> M4 (parallel with M1) -> M1 -> M3 (conditional) ->
M2 -> M5/M6 (parallel) -> M7**.

| Milestone | Primary agent | Consult | Reviewer focus |
| :--- | :--- | :--- | :--- |
| M0 Post-merge provenance | `build_vendor` | maintainer | maintainer-owned tag, clean-clone build, archived results |
| M1 Characterization | `verification` | `transport_io`, `http_protocol` | raw artifacts, controls, no tuning without a measured hotspot |
| M2 HttpArena restore | `integrator` | maintainer | public API only, raw run artifacts, profile honesty |
| M3 H2 flow control | `http_protocol` | `transport_io`, `verification` | evidence-gated change, regression coverage |
| M4 Windows runtime | `transport_io` | `build_vendor`, `verification` | no weakened assertions, auditable dependency change, runtime job |
| M5 MSan decision | `verification` | `build_vendor` | dated, unambiguous contract |
| M6 Follow-ups | `dx_router` | `crypto_tls`, docs owner | ADR-first for any API change |
| M7 Evidence/CI | `integrator` | maintainer | append-only artifacts, no shared-runner claims |

Release gates for v1.9.0 (all must hold before the maintainer tags):

1. Every row in section 4.1 is closed or re-declared with linked evidence and
   an explicit reason.
2. Every code change satisfies the gates in section 1.3.
3. M1 artifacts are archived and linked; the contract parameters are unchanged
   or versioned.
4. M2 either restored the profile with official fresh results, or the
   non-restoration is publicly disclosed with raw evidence and a criterion.
5. M4 either passes natively on Windows or is re-declared with the upstream
   and local blockers linked.
6. `CHANGELOG.md`, docs, ADRs, and version metadata describe exactly what
   shipped; the maintainer-created tag and the recorded commit SHA match.

### 4.11 Open questions

1. Which machine is the designated quiet host for M1, and what is its
   `RLIMIT_MEMLOCK`?
2. Does the pinned HttpArena commit expose a local profile validation command,
   and what is it?
3. Is a Windows runtime runner available to this repository's plan, or does M4
   depend on external infrastructure?
4. Does any target workload actually need cross-worker session resumption, or
   is a measured per-worker handshake ratio enough?
5. Is credential hot reload needed in production, or is the rolling restarter
   the documented answer?
6. Should `h2-tls-scaling-v1` results live on a results branch, in
   `benchmark-data`, or beside the release notes? Pick one before M1 records
   anything.

### 4.12 Appendix A: command reference

```sh
# Repository gates
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
sh scripts/check_docs.sh
zig build test --summary all

# Sanitizers (Nix dev shell: nix develop path:.)
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all

# Portability
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build test-compile -Dtarget=x86_64-windows-gnu --summary all
zig build test-compile -Dtarget=aarch64-macos --summary all

# Consumer and example
(cd tests/package_consumer && zig build check -Doptimize=ReleaseSafe)
zig build tls_cluster -Doptimize=ReleaseSafe

# M1 local run (validate flags with h2load --help for your build)
export UWZ_TLS_CERT=/path/to/fullchain.pem
export UWZ_TLS_KEY=/path/to/privkey.pem
export UWZ_WORKERS=4 UWZ_MAX_CLIENTS=2048 UWZ_CPU_AFFINITY=0
export UWZ_TLS_BIND=127.0.0.1 UWZ_TLS_PORT=8443
scripts/benchmark_h2_tls.sh tls-cluster ./zig-out/bin/tls_cluster /tmp/h2-results
h2load -n 500000 -c 1024 -m 8 -t 8 https://127.0.0.1:8443/

# Release tag (maintainer only, after review and merge)
# Agents never create, move, or push tags.
git tag -a v1.9.0 -m "Release 1.9.0"
git push origin v1.9.0
```

### 4.13 Appendix B: file inventory

| Concern | Files |
| :--- | :--- |
| H2/TLS contract and runner | `benchmarks/h2_tls_scaling_guarantee.md`, `benchmarks/h2_tls_scaling_v1.env`, `scripts/benchmark_h2_tls.sh` |
| Benchmark server | `examples/tls_cluster.zig` |
| TLS cluster API | `src/router/app.zig`, `src/router/builder.zig`, `src/crypto/tls.zig` |
| Backend selection and retry | `src/core/loop.zig`, `src/core/xev.zig` |
| Cluster TLS tests | `src/tests/tls_tests.zig` |
| Test and build plumbing | `builds/testing.zig`, `builds/sanitizers.zig`, `src/tests/main.zig` |
| Windows listener and helpers | `src/core/tcp.zig` |
| Docs | `docs/tls.md`, `docs/api.md`, `docs/architecture.md`, `docs/memory_model.md`, `docs/deployment.md`, `docs/troubleshooting.md`, `docs/roadmap.md`, `docs/adr/` |
| Benchmarks and CI | `benchmarks/`, `.github/workflows/test.yml`, `.github/workflows/windows.yml`, `.github/workflows/benchmark.yml` |
| HttpArena (external) | `frameworks/uwebzockets/build.zig.zon`, `frameworks/uwebzockets/src/main.zig`, `frameworks/uwebzockets/meta.json` |

---

## 5. Deferred feature track: GraphQL Wire Transport

**Status:** deferred feature track, not part of 2.2.0. It remains available
for a later minor release; no date is promised here. Re-declared on
2026-11-10: all five G-* tasks are outside the 2.2.0 release and are not
release blockers.

**Objective:** bounded, zero-DOM GraphQL transport over HTTP and WebSocket
without an application query execution engine.

### Task G-0: RFC 6455 WebSocket subprotocol negotiation (`src/ws/`)

- **Current state:** `src/ws/socket.zig` writes a static `101 Switching
  Protocols` response without evaluating or echoing `Sec-WebSocket-Protocol`.
- **Requirements:**
  1. Parse `Sec-WebSocket-Protocol` from the upgrade request
     (comma-separated `1#token` list per RFC 6455).
  2. Enforce bounded capacity:
     ```zig
     pub const max_offered_subprotocols: usize = 8;
     pub const max_subprotocol_length: usize = 64;
     ```
  3. Define the selection callback on the WebSocket route configuration:
     ```zig
     pub const SubprotocolSelector = *const fn (
         ctx: ?*anyopaque,
         offered: []const []const u8,
     ) ?[]const u8;
     ```
  4. Append `Sec-WebSocket-Protocol: <selected>\r\n` to the 101 response when
     matched. In strict mode, reject unmatched protocols with
     `400 Bad Request`.
  5. Tests in `src/tests/ws_tests.zig`: zero offers, matching offers, multiple
     offers, unknown offers, malformed header injection. Keep the Autobahn
     pass rate at 517/517.

### Task G-1: WebSocket GraphQL envelopes (`src/graphql/transport_ws.zig`)

- **Subprotocols:** modern `graphql-transport-ws` (`connection_init`,
  `connection_ack`, `ping`, `pong`, `subscribe`, `next`, `error`, `complete`);
  optional legacy `graphql-ws`.
- **Design and limits:**
  1. Zero-DOM scanner: extract `id`, `type`, and
     `payload: { query, variables, operationName, extensions }` without
     allocating a JSON tree. Query text is borrowed from the socket buffer.
  2. Bounded limits:
     ```zig
     pub const max_envelope_bytes: usize = 64 * 1024;
     pub const max_operation_id_bytes: usize = 64;
     pub const max_active_operations: usize = 16;
     ```
  3. Per-connection operation state machine: `subscribe` -> `next`* ->
     `complete`. Handle unknown IDs, duplicates, and cancellations without
     dropping the socket.
  4. Bridge subscriptions into `src/ws/pubsub.zig` with automatic
     unsubscription on disconnect.

### Task G-2: GraphQL over HTTP (`src/graphql/http.zig`)

- `POST` with `application/json`: parse
  `{ query, operationName, variables, extensions }`.
- `POST` with `application/graphql`: body is raw query text.
- `GET`: `query`, `operationName`, and `variables` via `src/http/query.zig`.
- Responses: `{"data": ...}` or `{"errors": [...]}` through a bounded
  `ResultWriter`. Status codes: 400 for malformed JSON or missing query, 200
  for execution outputs (including execution errors), 405 for unsupported
  methods.

### Task G-3: Application executor contract (`src/graphql/executor.zig`)

```zig
pub const Operation = struct {
    id: ?[]const u8 = null,
    query: []const u8,
    operation_name: ?[]const u8 = null,
    variables: ?[]const u8 = null,
    extensions: ?[]const u8 = null,
};

pub const ExecutorError = error{
    InvalidQuery,
    ExecutionFailed,
    Canceled,
};

pub const Executor = *const fn (
    ctx: ?*anyopaque,
    operation: *const Operation,
    writer: *ResultWriter,
) ExecutorError!void;
```

Register the executor once during server configuration before `listen()`.

### Task G-4: Documentation and integration example

- `docs/graphql.md` with limits, wire protocols, and the executor contract.
- `examples/graphql_server.zig` with an HTTP endpoint and a WebSocket
  subscription using a mock executor.

### Deferred GraphQL checklist

- **Deferred:** Subprotocol negotiation (G-0) passes unit tests and Autobahn 517/517.
- **Deferred:** `graphql-transport-ws` (G-1) passes table-driven encode/decode tests.
- **Deferred:** GraphQL-over-HTTP (G-2) handles GET, POST JSON, and POST raw queries.
- **Deferred:** Executor seam (G-3) verified with the mock executor.
- **Deferred:** `docs/graphql.md` published and validated (G-4).

---

## 6. Version 2.0.0: High-Throughput Performance and Multi-Core Overhaul

**Status (2026-10-20):** the P-1 through P-9 code and unit-test surface is
implemented on `release/v2.0.0-high-throughput`. The designated-host performance
evidence and UDP receive GRO are carried into section 8.1 as 2.2-C1 and
2.2-C2.

**Update (2026-10-24):** [ADR 0005](docs/adr/0005-libxev-fork.md) adopts
`farbenbuilds/libxev` as the maintained downstream fork. The 2.1.0 migration
pins commit `cbf01bc` on `uwz/zig-0.16`, carries XEV-001 in the fork, and
removes the overlay and audit patch.

**Objective:** maximize multi-core utilization, remove write syscall
amplification, and eliminate compression latency, with every change gated by
the v1.9.0 measurement baseline.

**Surface-completion note:** P-9 adds the remaining ordinary HTTP method,
`TRACE`. It is deliberately isolated from the performance work and must not
introduce allocation or a new hot-path branch. The only expected cost is one
token comparison in `HttpMethod.parse` and one extra slot in the existing
fixed method arrays. It is exempt from benchmark gating but not from the test,
sanitizer, and compatibility gates.

### Task P-1: Multi-core scaling without re-implementing shipped APIs

- **Current state:** v1.8.5 and v1.8.9 already ship
  `Server.builder(...).build_cluster(...)` with `Cluster.enable_https(cert,
  key)` and one `SSL_CTX` per worker, plus `SO_REUSEPORT` distribution,
  physical-core affinity, and per-worker slabs. The 1.9.0 M1 milestone
  characterizes it.
- **Requirements:**
  - Build on the shipped cluster API. Do not re-implement multi-core TLS or
    add a second cluster abstraction.
  - Any change to the per-worker context decision (for example one shared
    `SSL_CTX`) goes through a new ADR with measured TLS-state and rollback
    evidence.
  - Keep `init_https` and the existing cluster signatures unchanged.

### Task P-2: Uncapped worker scaling for high-core servers

- Expose `UWEBZOCKETS_WORKERS` to override thread counts.
- Default to `std.Thread.getCpuCount()` (one worker per physical core) and
  remove the 32-worker cap once M1 shows scaling behavior at higher counts.

### Task P-3: HTTP/1.1 pipelining write coalescing

- In the socket read completion, process all complete pipelined requests in
  the current buffer in one loop.
- Keep the per-connection send ring (already bounded, default 64 KiB) and
  append response heads and payloads sequentially.
- Flush queued responses with a single vectorized write when the backend
  supports it.

### Task P-4: WebSocket SIMD unmasking and frame batching

- Accelerate unmasking with 128-bit/256-bit vector XOR loops instead of
  scalar loops (the SIMD scan primitives already exist in `src/core/simd.zig`).
- Assemble multiple echo frame headers and payloads into a consolidated output
  buffer before the write path.

### Task P-5: Thread-local `libdeflate` compressor pooling

- Pre-allocate one `libdeflate_compressor` per worker thread at startup.
- Use a pre-allocated bounded scratch buffer for gzip headers, compressed
  payloads, and CRC32 footers. Never allocate a compressor on a request path.

### Task P-6: Kernel socket flags and buffer sizing

- Keep `TCP_NODELAY`, `TCP_QUICKACK`, and `TCP_DEFER_ACCEPT` on accepted
  sockets (already shipped; verify under load).
- Expand fixed 16 KiB buffer caps only where M1 or P-3 shows a measured limit.

### Task P-7: HTTP/2 window scaling and HTTP/3 UDP offload

- **Gate:** do not change H2 windows speculatively. Apply changes only when
  v1.9.0 M1 fills the stream/flow-control probe row with stall evidence.
- If required, evaluate larger initial stream and connection windows and
  proactive `WINDOW_UPDATE` emission, with regression tests for stream
  capacity and flow control.
- Enable `UDP_GRO` and `UDP_SEGMENT` (GSO) on lsquic UDP sockets and verify
  with the HTTP/3 gate.

### Task P-8: Deterministic multi-port startup barrier

- Implement an atomic startup synchronization barrier inside `App.listen_all()`.
- Ensure auxiliary listeners (:8081, :8082, :8443) report verified socket
  binding before port 8080 starts accepting.

### Task P-9: Complete the HTTP method surface with TRACE

**Current state (as of 1.8.9):** `HttpMethod` in `src/router/radix.zig`
covers GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, and QUERY, plus an
internal CONNECT selector. TRACE is absent from `HttpMethod.parse`/`name`,
`concrete_methods`, `Router`/`App` registration, the client `Method`, and the
C ABI. An incoming `TRACE` request currently parses as an unknown token:
`HttpMethod.parse` returns `null`, so a method-specific handler cannot be
registered, the method is omitted from `Allow` and OpenAPI, and dispatch falls
through to an `any` route when one exists. The only TRACE reference is the
HTTP/3 replay-safety classifier in `src/quic/http3_extensions.zig`.

**Scope decision:** make TRACE a first-class, explicitly registered method in
the server, client, and C ABI. Do not auto-register a TRACE route and do not
synthesize the RFC 9110 echo response; the application opts in and owns the
handler. Keep CONNECT as an internal transport selector for HTTP/2 and HTTP/3
extended CONNECT; do not expose it through `App` or `uwz_app_route` in this
task. Do not change WebSocket handshake rules, which remain GET-only. Leave
request-body parsing generic: TRACE is bodyless by definition, but the parser
does not need a method-specific special case in this task.

**Security position:** TRACE is safe and idempotent (RFC 9110 section 9.3.8),
but a successful response reflects the received request, which is a
cross-site tracing risk. A handler that implements the echo must redact
`Authorization`, `Cookie`, `Proxy-Authorization`, and application secrets,
must bound the reflected bytes to the response capacity, and should emit
`Content-Type: message/http`. Document that TRACE is opt-in and should be
disabled on public deployments unless an explicit operational requirement
exists.

**Implementation map**

| Layer | Files | Required change |
| :--- | :--- | :--- |
| Server method model | `src/router/radix.zig` | Append `.trace` after `.connect` so existing enum bit positions stay stable. Add `"TRACE"` to `parse`, `name`, and `lower_method` (OpenAPI spelling `trace`). Add `.trace` to `concrete_methods` between `.options` and `.query`. Add `Router.trace`. |
| App builder | `src/router/app.zig` | Add `App.trace(path, handler)` with the same `ensure_routes_mutable` and `router.trace` flow as `get`/`post`. `route_context`, `route_async`, and `route_async_context` need no new wrappers because they already accept `HttpMethod`. |
| Client | `src/client/types.zig`, `src/client/request.zig` | Append `.trace` to `Method`; map it to `"TRACE"` in `method_name`. |
| C ABI | `include/uWebZockets.h`, `src/c_api/app.zig` | Append `UWZ_HTTP_TRACE = 9` after `UWZ_HTTP_QUERY = 8`; never renumber existing values. Map 9 in `register_http_route` and `http_method`. Do not add a CONNECT code. |
| TLS 0-RTT | `src/core/tcp.zig` | Add `.trace` to the safe-method allowlist in `early_data_forbids` (`GET`, `HEAD`, `OPTIONS`, `TRACE`); update the 0-RTT policy text. Do not change the QUERY policy in this task. QUIC already lists TRACE in `method_is_replay_safe`. |
| OpenAPI | `src/router/radix.zig` | `lower_method` returns `trace`; the generator needs no change. Add a test that a TRACE route appears as `"trace"`. |
| Docs and metadata | `docs/api.md`, `docs/client.md`, `docs/tls.md`, `docs/deployment.md`, `docs/protocols.md`, `CHANGELOG.md` | Add TRACE to the registration and client tables, the safe-method lists, and the release entry. State that TRACE is opt-in and that reflection must redact credentials. |

**Test matrix**

- `src/tests/router_tests.zig`: `parse("TRACE")`/`name()`; `Router.trace` on
  exact and parameterized paths; 405 `Allow` behavior; `any` advertises TRACE.
  Update the expected `Allow` string to
  `GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, TRACE, QUERY`.
- `src/tests/http_tests.zig`: raw `TRACE /probe HTTP/1.1` parses and retains
  `req.method`.
- `src/tests/client_tests.zig`: serialized head is
  `TRACE /probe HTTP/1.1`.
- `src/tests/framework_tests.zig`: OpenAPI contains `"trace"` for a TRACE
  route.
- `src/tests/http2_server_tests.zig`: `:method: TRACE` reaches the handler.
- HTTP/3 gate: a pinned curl/ngtcp2 `:method: TRACE` request reaches the
  handler. `scripts/http3_compliance/run.sh` performs the live request and
  asserts `200` with the `trace` body; `src/tests/quic_phase3_tests.zig` keeps
  the explicit `method_is_replay_safe("TRACE")` assertion.
- `tests/c_api/smoke.c` and `tests/c_api/header_cpp.cc`:
  `UWZ_HTTP_TRACE == 9`; `uwz_app_route(..., UWZ_HTTP_TRACE, ...)` returns
  `UWZ_OK`; existing method values are unchanged.

**Human implementation checklist**

1. Confirm the ABI and security decisions above; do not add an automatic echo.
2. Implement the method model, app wrapper, client mapping, and C ABI mapping
   in one reviewable commit.
3. Add the tests above before changing docs; the 405/`Allow` and `any` tests
   are the regression net for unknown-method fallback.
4. Update `docs/` and `CHANGELOG.md` in the same change.
5. Run the gates in section 1.3 plus the sanitizer and package-consumer gates.
6. Verify the C smoke and C++ header checks, then run `graphify update .`.

**Agent execution**

- **Architect:** confirm the ABI append-only policy, the 0-RTT classification
  for TRACE (admit it as safe; do not change QUERY), and whether a bounded
  echo example is in scope. Produce the file list and acceptance criteria
  above; do not implement.
- **Developer:** `dx_router` owns `src/router/` and the app surface;
  `http_protocol` checks the parser and method-token behavior; `transport_io`
  owns the 0-RTT allowlist; `ffi_edge` owns the C ABI and header checks;
  `verification` owns the protocol and test matrix. Report changed files,
  exact commands, and raw results.
- **Reviewer:** independently check enum bit stability, exhaustive switches,
  `Allow`/OpenAPI output, C ABI value stability, client serialization, 0-RTT
  behavior, no automatic TRACE route, and no new allocation. Report findings
  with file and line references.
- **Integrator:** land P-9 as an isolated commit before the final performance
  tuning, resolve overlaps, run the combined gates, and attach evidence. Do
  not mix this commit with P-3/P-4 benchmark runs.

**Acceptance criteria**

- [x] `HttpMethod.parse("TRACE") == .trace` and `.name()` returns `"TRACE"`.
- [x] `Router.trace` and `App.trace` register exact and parameterized routes.
- [x] A TRACE request reaches the registered handler over HTTP/1.1, HTTP/2,
      and HTTP/3.
- [x] A GET-only path answers TRACE with 405 and an `Allow` field; adding a
      TRACE route makes `Allow` include TRACE.
- [x] An `any` route advertises TRACE and still handles unknown methods.
- [x] OpenAPI emits `"trace"`; the client emits `TRACE /probe HTTP/1.1`.
- [x] `UWZ_HTTP_TRACE == 9`, existing C method values are unchanged, and
      `uwz_app_route` accepts the new code.
- [x] TRACE early data is admitted; non-safe methods still receive 425.
- [x] No allocation, no CONNECT exposure, and no WebSocket handshake change;
      the only hot-path cost is the existing method-token comparison and one
      extra fixed method-array slot.
- [x] `zig fmt`, convention, release-version, docs, unit, sanitizer,
      package-consumer, C smoke, and C++ header checks pass.

---

## 7. Version 2.1.x: Asynchronous Timer Engine and API Hardening

**Objective:** enable non-blocking delay handlers, connection timeouts, and
task scheduling without blocking worker loops or adding cross-thread locks,
then harden the public application and worker-manager surface.

**Status (2026-10-25):** 2.1.0 shipped the per-worker timing wheel (T-1 to
T-4), the libxev fork migration (2.1-C3), and the three v2.0.5 hot-path
follow-ups (2.1-H1 to 2.1-H3). 2.1.5 closes the API-hardening slice in section
7.1: typed cluster lifecycle and failure reporting, per-worker publish
outcomes, a dedicated worker thread manager, and TODO/docs cleanup. The
quiet-host performance evidence (2.1-C1), receive-side UDP GRO (2.1-C2),
cross-process listener handoff (2.1-C4), optional API follow-ups (2.1-C5), and
the external HttpArena `async` adapter activation are carried to 2.2.0 or
later; the carry-over list is in section 8.1. The native Windows runtime job
and the XEV-001 re-arm regression remain CI gates. The carried follow-up
closure is scheduled as 2.5.5; see section 11.1.

### Carry-over milestones from v2.0.0

The 2.0.0 implementation closed the code and unit-test surface. The following
items are deliberately open and must be scheduled before or beside the timer
work; they are not regressions in 2.0.0.

#### 2.1-C1 and 2.1-C2: carried to 2.2.0

| Item | Tracking owner |
| :--- | :--- |
| 2.1-C1 quiet-host performance evidence | 2.2-C1 in section 8.1 |
| 2.1-C2 receive-side UDP GRO | 2.2-C2 in section 8.1 |

The detailed acceptance criteria live in section 8.1; edit them only there.

#### 2.1-C3: libxev fork migration and overlay removal

- [x] Sync the fork mirror and create `uwz/zig-0.16` at `9ce8e8e`.
- [x] Import the IOCP accept ownership change as the first
      `uwz(win-iocp): ...` ledger commit (XEV-001) at
      `cbf01bc432a84cd91a99c1cb1031b46416d044c7`.
- [x] Move the pin to the full fork commit, regenerate all four dependency
      views and hashes, remove `vendor/libxev_overlay` and the patch, delete
      the overlay build step, and replace the libxev half of
      `scripts/check_vendor_overlay.sh` with `scripts/check_libxev_fork.sh`.
- [x] Update notices, roadmap, CI provenance, and ADR 0004. The empty-cache
      build and the Linux gates pass; the native Windows gate runs in CI.
- [x] Keep upstream `mitchellh/libxev` fetch-only; do not submit the patch
      upstream or modify `zig-pkg`.
- [x] Track upstream issue #252 only to decide when XEV-001 retires; overlay
      removal follows the fork migration, not an upstream release. This is a
      standing review item, not an open 2.1.0 task.

#### 2.1-C4 and 2.1-C5: carried to 2.2.0

| Item | Tracking owner |
| :--- | :--- |
| 2.1-C4 cross-process listener handoff | Task A-4 in section 15 |
| 2.1-C5 optional API follow-ups | 2.2-C5 in section 8.1 |

The detailed decisions live with those owners; do not duplicate them here.

### v2.0.5 hot-path follow-ups

The 2.0.5 audit closed the server-side HTTP/1 scan cursor, accept-error
backoff, empty-table rate-limit probe, and pub/sub reentrancy path. Three
bounded follow-ups remain. Each is a separate reviewable change; do not bundle
them with the timer wheel or with a dependency refresh.

#### 2.1-H1: O(1) rate-limit eviction with exact oldest-key semantics

**Status:** closed in 2.1.0. `RateLimitTable` plus `rate_limit_indexed` provide
open-addressed lookup, caller-owned LRU links, exact-oldest eviction, and an
amortized rehash. The legacy `rate_limit` constructor remains the documented
linear compatibility path. **Owner:** dx_router.

**Current state.** `src/http/middleware.zig` keeps `RateLimitBucket` at 32
bytes and accepts a caller-owned table through `rate_limit(io, options,
buckets)`. Empty tables use the open-addressed probe path. Pre-seeded tables
use `locate_bucket_linear`, and a full-table miss must scan every bucket to
prove absence and select the smallest `last_refill_ns`.

**Required behavior.** A hit and a free-capacity insert must be O(1) expected.
A full-table miss must select the exact oldest bucket, with the existing
lowest-index tie break, and start the evicted key with zero tokens. A key that
rotates cannot reset its own budget. `last_refill_ns == 0` remains the free
marker and key `0` remains a valid key.

**Design constraints.**

- Keep the `rate_limit(io, options, buckets)` entry point and fixed-capacity,
  allocation-free construction.
- Add caller-owned index storage through a named table type, or an explicit
  second slice; no file-scope mutable state and no hidden allocator.
- Prefer intrusive LRU links or an open-addressed index plus a bounded
  min-heap/timing wheel. State the tie break and how token refill interacts
  with eviction.
- A restored or pre-seeded table must rebuild the index at construction or use
  the documented linear compatibility path. One table has exactly one owning
  limiter.
- If a new public table type is introduced, update `CODEBASE.md`, the
  middleware docs, and the slab accounting tests in the same change.

**Tests and evidence.**

- Full table with at least four explicit timestamps: oldest key wins; equal
  timestamps select the lowest index.
- Insert at least 4096 keys into a full table, hit every key, and assert no
  duplicate live keys plus bounded probe work through a test-only counter.
- Evicted key starts empty and remains unable to reset its budget.
- Empty table fails closed without reading the clock or hashing a key.
- Pre-seeded and restored tables preserve the current placement and eviction
  behavior.
- Record probe counts and, if benchmarked, separate measured results from
  estimates.

**Acceptance.** No O(n) scan on the hit or free-capacity path; full-table
eviction is O(1) expected with exact-oldest semantics; no allocation after
construction; existing middleware tests stay unchanged or are strengthened,
never weakened.

**Gates.** `zig fmt --check build.zig src examples tests fuzz`,
`sh scripts/check_conventions.sh`, `zig build test --summary all`,
`zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all`, and the
quiet-host benchmark contract if a performance number is claimed.

#### 2.1-H2: Client HTTP/1 response parser incremental scan cursor

**Status:** closed in 2.1.0. `Parser.scan` and `Parser.scan_work` cover status
lines, interim and final headers, chunk sizes, chunk extensions, trailers, and
split chunk CR/LF pairs; `compact` rebases the cursor. **Owner:** http_protocol.

**Current state.** `src/client/http1.zig` restarts delimiter searches at the
current token mark on every read, so a peer that dribbles status-line, header,
chunk-size, chunk-extension, or trailer bytes forces repeated scans of the
accumulated prefix. `compact()` shifts unconsumed bytes and resets `mark`, so a
cursor must be rebased there.

**Required behavior.** Total delimiter scan work must be linear in the response
size, independent of read chunking. The accepted grammar, header limits, body
limits, and error precedence must not change.

**Design constraints.**

- Follow the server-side `src/http/parser.zig` pattern: one `scan` cursor, one
  `enter_state` transition helper, and a diagnostic `scan_work` counter that
  is reset for each response.
- Use `scan` for the status line, interim headers, headers, chunk size, chunk
  extension, trailer, and fixed/eof/chunk body transitions.
- On incomplete header or trailer input, keep a three-byte overlap for the
  four-byte `\r\n\r\n` terminator. On a split chunk CR/LF, resume at the CR so
  the LF is not skipped.
- In `compact()`, rebase `scan` by the same shift as `mark`, clamp it to the
  retained range, and never move it backwards.
- The terminal done/error path must return the consumed prefix, not the scan
  cursor.
- Do not change `parse_response` signatures or public error sets.

**Tests and evidence.**

- Byte-at-a-time status line, headers, chunk size, chunk extension, and
  trailer: assert done and `scan_work <= 4 * wire.len + 32`.
- Split the header and trailer terminator at every position; split chunk
  CR/LF; call `compact()` between partial reads and assert the response still
  completes.
- Add or extend a `fuzz/client_http1.zig` Smith corpus and
  `LLVMFuzzerTestOneInput` target with the same work bound if no client parser
  fuzz target exists.
- Keep the existing client tests and add a regression that fails on the
  parent commit.

**Acceptance.** No full-prefix rescan; byte-at-a-time and whole-buffer
delivery produce identical parsed output; limits and malformed-input decisions
are unchanged.

**Gates.** `zig fmt --check build.zig src examples tests fuzz`,
`sh scripts/check_conventions.sh`, `zig build test --summary all`,
`zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all`,
`zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe`, and
`zig build oss-fuzz-smoke -Doptimize=ReleaseSafe --summary all`.

#### 2.1-H3: Pub/sub per-topic subscriber index

**Status:** closed in 2.1.0. Stable topic ids, intrusive per-topic subscriber
lists, and open-addressed topic and subscription indexes make publish work
O(topic subscribers) and subscribe/unsubscribe O(1) expected. Publish-depth
tombstones and reentrant removal are preserved. **Owner:** ws_protocol.

**Current state.** `src/ws/pubsub.zig` scans `0..bound` of the global
`max_subscriptions` table (8192 rows) for every publish. `find_topic` scans up
to 1024 names, and `remove_topic` remaps every live subscription row when a
topic id moves. The tombstone and publish-depth rules from 2.0.5 are correct
and must be preserved.

**Required behavior.** Publish work must depend on the live subscribers of the
published topic, not the global subscription count. Subscribe, unsubscribe,
and per-topic removal must be O(1) expected with fixed storage. Reentrant
unsubscribe and deinit during fan-out must still deliver each live subscriber
exactly once and must not cause cross-topic delivery.

**Design constraints.**

- Add fixed SoA links for each subscription row (`next_subscription`,
  `prev_subscription`) and per-topic heads/tails (or an equivalent bounded
  intrusive list) carved at startup.
- `publish` snapshots the topic id and head, follows links, and defers removal
  until the outermost `end_publish`. New subscriptions during a frame must not
  receive the in-flight message.
- Prefer stable topic ids over swap-removal remapping; if topic ids still
  move, rebuild links atomically and prove no row points at a stale id.
- Preserve idempotent subscribe, `max_topics`, `max_subscriptions`,
  failed-subscriber isolation, and zero allocation in the message path.
- State the memory delta and update `ServerConfig` slab accounting plus the
  default-slab expectation in `src/tests/config_tests.zig`.
- Do not add a global lock or per-worker mutex. Each engine remains
  event-loop-confined.

**Tests and evidence.**

- One topic with N subscribers and many unrelated topics: publish visits only
  the N live rows, proven by a test-only visit counter.
- A failed HTTP/2 subscriber during fan-out is tombstoned without shifting
  rows; a sibling receives exactly one copy.
- Subscribe during publish never receives the in-flight message; nested
  publish and reentrant unsubscribe/deinit are covered.
- Topic removal and reuse do not misdeliver to a subscriber of another topic.
- Cap exhaustion, empty-topic sweep, and the existing pub/sub tests remain
  green.

**Acceptance.** Publish work is O(topic subscribers); subscribe/unsubscribe is
O(1) expected; no allocation or new lock; existing WebSocket, HTTP/2, and
Autobahn behavior is unchanged.

**Gates.** `zig fmt --check build.zig src examples tests fuzz`,
`sh scripts/check_conventions.sh`, `zig build test --summary all`,
`zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all`, the
Autobahn target, and the HTTP/2 server tests.

#### Execution guide for humans and agents

1. Read `AGENTS.md`, `CODING_CONVENTION.md`, `CODEBASE.md`, and the owning
   module before editing. Use `graphify query` before raw grepping.
2. Land one milestone per pull request. Do not combine H1, H2, or H3 with the
   timer wheel, dependency updates, or unrelated formatting.
3. Start with a regression test that fails on the parent commit. Keep tests
   deterministic; no wall-clock or host-performance assertions.
4. Preserve the invariants above. Do not weaken a limit, delete a test, widen
   an error set, or add a hidden allocation to make a test pass.
5. Update `CODEBASE.md`, `docs/memory_model.md`, the relevant protocol doc, and
   `CHANGELOG.md` when storage, public types, or observable behavior change.
6. Run the gates listed for the milestone, then the full release matrix for any
   change that touches the request path or slab layout.
7. Record measured values only from the designated quiet host; mark estimates
   as estimates. This section does not authorize a performance claim by
   itself.

### Dependency update queue (audited 2026-10-22)

The v2.0.5 security refresh landed the tagged updates below. Only tagged,
reviewed revisions are candidates; unreleased branch heads need their own
measured change and must not ride along with unrelated work.

| Dependency | Pinned | Latest available | Action |
| :--- | :--- | :--- | :--- |
| lsquic | `a961672` (`v4.10.2`) | `v4.10.2` (2026-10-18) | Current; includes the QPACK decoded-header-set bound and the regenerated overlay |
| BoringSSL | `d3bf479` (`0.20261020.0`) | `0.20261020.0`; no newer release | Current; rerun the full TLS and sanitizer matrix on the next pin |
| zslay | `v0.2.1` | `v0.2.1`; HEAD `2af3b09`, 6 unreleased commits ahead | No tagged update; do not pin a branch without a release |
| ls-hpack | `fda48e0` (CMake-only ahead of `v2.3.5`) | HEAD `fda48e0` | Current; no C source delta |
| zlib | `v1.3.2` | `v1.3.2`; HEAD `767c4c9`, 110 unreleased commits ahead | No released update |
| ls-qpack | `9156770` | `v2.7.0` = HEAD | Current |
| libdeflate | `92e6a0d` | `v1.26` = HEAD | Current |
| libxev | `cbf01bc` (`farbenbuilds/libxev` `uwz/zig-0.16`, base `9ce8e8e`) | HEAD `451a2bc` requires Zig 0.17 | Migrated in 2.1.0; XEV-001 and XEV-002 are the only downstream patches. Track upstream issue #252 for retirement |
| h1spec | `f0a5650` | `f0a5650` = HEAD | Current |
| Zig | `0.16.0` from the pinned `zig-overlay` snapshot | Latest tag `0.15.2`; no upstream `0.16.0` tag | Treat `0.16.0` as a development snapshot, not an update target |
| Flake inputs | `nixpkgs`, `zig-overlay`, `zon2nix`, `flake-compat`, `systems` | All have newer branch heads; `flake-parts` is current | Refresh with `nix flake update` in a separate tooling change and rerun the full matrix |

- [x] Land the tagged dependency updates above in 2.0.5, update every
      dependency view (`build.zig.zon`, `.json`, `.nix`, `.txt`) and the
      recorded hashes, and rerun the release gates.
- [x] Migrated the IOCP accept patch to `farbenbuilds/libxev`, removed
      `vendor/libxev_overlay` and `patches/libxev_iocp_accept_socket.patch`,
      moved the pin, updated every dependency view, and deleted the overlay
      build step (2.1-C3, ADR 0005).
- [x] Do not combine the dependency refresh with the timer-wheel
      implementation; land them as separate reviewable changes so benchmark
      and protocol regressions stay attributable.

### Task T-1: Per-worker hierarchical timing wheel (`src/core/timer_wheel.zig`)

**Status:** closed in 2.1.0; unit-tested by the timer-wheel suite.

- Four levels:
  - Level 0: 256 slots (1 ms resolution, 0 to 255 ms).
  - Level 1: 64 slots (256 ms resolution, up to 16.3 s).
  - Level 2: 64 slots (16.3 s resolution, up to 17.4 min).
  - Level 3: 64 slots (17.4 min resolution, up to 18.6 h).
- Zero-allocation node embedding: timer entries live inside connection slab
  slots.
  ```zig
  pub const TimerNode = struct {
      deadline_ms: u64,
      callback: *const fn (ctx: *anyopaque) void,
      ctx: *anyopaque,
      next: ?*TimerNode = null,
      prev: ?*TimerNode = null,
  };
  ```

### Task T-2: Single `xev.Timer` integration

**Status:** closed in 2.1.0; one persistent scheduler timer per worker loop.

- Drive the wheel with one persistent `xev.Timer` watcher per worker loop,
  ticking at 1 ms or sleeping until the nearest active deadline.
- Cascade expired nodes down levels and execute level-0 callbacks.

### Task T-3: Zero-allocation request parking and resumption

**Status:** closed in 2.1.0; HTTP/1 and HTTP/2 parking slots are connection-owned.

- Provide:
  ```zig
  pub fn sleep(ctx: *Context, delay_ms: u64, resume_fn: *const fn (*Context) void) void;
  ```
- Implement the HttpArena `/delay/{ms}` profile: suspend processing, register
  the node, write the response on expiry.

### Task T-4: Connection idle timeouts and dead-connection reaping

**Status:** closed in 2.1.0; idle and header-read deadlines use wheel nodes.

- Register `keep_alive_timeout` and `header_read_timeout` in the timing wheel.
- Reset the node on every successful read; terminate and reclaim the slot when
  the timer expires first.

### 7.1 Version 2.1.5: API Hardening and Worker Manager

**Objective:** make the thread-per-core manager's lifecycle, failures, and
delivery outcomes explicit without breaking the 2.1 public surface or adding
work to the request path.

**Status (2026-10-25):** implementation complete; PR #105 is fully green.

- [x] Add atomic `ClusterState` (`configured`, `running`, `stopped`,
      `releasing`, `released`), `state()`, `worker_count()`, and
      `worker_capacity()`.
- [x] Add `FailurePhase`, `WorkerFailure { index, phase, err }`,
      `first_failure()`, and `failure_count()`; retain the first worker or
      spawn failure and log it with the worker index.
- [x] Add `PublishReport { queued, dropped, notify_failed,
      first_dropped_worker }` and `publish_report()`; keep `publish()`
      source-compatible and validate before mutating any inbox.
- [x] Replace `Cluster.configure`'s `anytype` callback with the named
      `ConfigureCallback` function pointer.
- [x] Move lifecycle transitions, release claiming, borrowed thread-slice
      start/join, and first-failure capture into
      `src/router/worker_group.zig`; keep thread storage in `Cluster` and
      `Cluster` as the only public worker manager.
- [x] Reject lifecycle misuse with `ClusterRunning`, `ClusterStopped`, and
      `ClusterDeinitialized` instead of touching drained workers.
- [x] Add `deinit_checked()` for supervisors; keep `deinit()`'s panic contract.
- [x] Record the decision in ADR 0007 and update `docs/api.md`,
      `docs/architecture.md`, `CODEBASE.md`, `README.md`, and `CHANGELOG.md`.
- [x] Add worker-group and cluster lifecycle/publish-report tests.
- [x] Run the full release matrix on CI: Debug tests, ReleaseSafe sanitizers,
      cross-target test compile, package consumer, C/C++ ABI checks, and the
      relevant compliance gates. Final local evidence: Debug and ASan/UBSan
      642/642 tests, ReleaseFast 642/642, Windows and macOS test-compile,
      package consumer, and the example install graph. CI on final SHA
      `3733252` is fully green across Debug, ASan/UBSan, MSan, ReleaseSafe,
      cross-target, downstream consumer, fuzz smoke, Autobahn, h1spec, HTTP/3,
      benchmark, and formatting.

**Acceptance:** existing 2.1 call sites compile unchanged; cluster tests pass
with leak detection; the public docs name every new type and error; no new
allocation or lock appears on the steady-state request path.

---

## 8. Version 2.2.0: Streaming I/O, Large Payloads, and Zero-Copy Static Assets

**Status (2026-11-10): release-ready; maintainer merge and tag pending.**

2.2.0 ships bounded file responses on every
supported transport, static sidecar negotiation, the incremental multipart
parser and part-sink adapter, the bounded request-streaming foundation, and the
HTTP/2 reset-retention and timer-overflow fixes. The C ABI layout, default
buffered request behavior, and the v2.1.6 release are unchanged. The release entry is in
[CHANGELOG.md](CHANGELOG.md).

### 8.1 Shipped in 2.2.0

- **S-1 response streaming.** `Response.begin_stream`, `write_chunk`, and
  `end_chunks` retain their public contract. Producers that return `.done`
  without terminal framing fail closed on HTTP/1, HTTP/2, and HTTP/3; blocked
  HTTP/2 resets are retained in a bounded FIFO and no longer close healthy
  siblings. The transport matrix covers 1-byte, 16 KiB, and 64 KiB chunks.
- **S-1 request streaming.** `StreamingRequest`, `BodySink`, `BodyRoute`,
  `BodyState`, and the pure HTTP/1 head/body decoder are shipped. HTTP/1.1, TLS HTTP/1.1,
  HTTP/2, and HTTP/3 bind the sink live through `App.post_stream`,
  `put_stream`, and `patch_stream`; live 1 MiB and 100 MB uploads pass on
  H1/TLS with a 16 KiB buffered cap. Pause/resume works on every transport; H2
  withholds stream credit and H3 stops reading with a bounded suffix. Live H2
  and H3 100 MB socket-pair proofs pass. Streaming routes run `headers_only`
  middleware once, carry its response headers to body end, send `100 Continue`,
  use the per-request `BodyBinding` context, and resolve capture capacities
  above 16 from per-stream H2 storage.
- **S-2 incremental multipart.** `StreamingParser` and `MultipartSink` accept
  arbitrary chunk boundaries with caller-owned storage, bounded carry, strict
  RFC 7578 metadata, explicit payload acknowledgement, and pause/resume.
  The full-body `Request.multipart()` API is unchanged.
- **S-3/S-4 static delivery.** Plaintext `sendfile` remains the preferred path.
  TLS, HTTP/2, and HTTP/3 stream known-length files through bounded scratch.
  Static mounts support `.gz`/`.br` sidecars, `Vary`, `Content-Encoding`,
  representation-specific validators, freshness checks, and encoded ranges.
  Content-coding negotiation scans every `Accept-Encoding` field without
  allocation. kTLS stays with v3.5.0 SB-31; splice remains conditional on a
  measured benefit.
- **S-5 TLS payload.** The 100 KiB producer response and true POST echo proofs
  pass with multi-record TLS framing and bounded queue occupancy.
- **C5 optional API decisions.** Shared TCP credentials, opt-in TRACE without
  automatic reflection, and the current C single-endpoint surface are retained.
  Reopening criteria are recorded in the [deliberate boundaries](docs/roadmap.md#deliberate-boundaries).
- **C6 timer boundaries.** The wheel range, overflow behavior, parking-slot
  ownership, and second-sleep misuse are documented. The overflow scan now
  examines every entry so a large advance cannot skip an earlier deadline.
- **C8 limiter ownership.** The rate-limit bucket table, open-addressed index,
  and LRU moved to `src/http/rate_limit.zig`; `middleware` keeps the public
  names as re-exports and the zero-allocation contract. Connection parking
  extraction remains a 2.3.0 item.
- **C9/C10/C11 dependency baseline.** The maintained libxev, lsquic, and h1spec
  pins are full commits; all four dependency views agree; the local provenance
  check passes; `patches/` and `vendor/lsquic_overlay` are absent. The cold
  build, h1spec 33/33 run, and HTTP/3 cross-implementation run were recorded
  during implementation; the exact-mirror sync, fresh final-pin protocol runs,
  and h1spec test-only submodule attribution remain release-owner actions.
- **M7 release metadata.** Version surfaces, C ABI macros, documentation
  headers, changelog, and roadmap are synchronized.

### 8.2 Re-declared to 2.3.0

These items are deliberately outside the 2.2.0 release. They remain tracked
with dated restoration criteria in this section and
[docs/roadmap.md](docs/roadmap.md#deliberate-boundaries).

- **Ownership debt (untangle pass).** `src/core/tcp.zig`,
  `src/router/app.zig`, `src/http2/server.zig`, `src/http/response.zig`, and
  `src/quic/stream.zig` remain above the 1000-line review flag. Their named
  seams are extracted; the remaining split is explicitly approved for 2.3.0.
- **WebTransport activation (M4).** Publish the required maintained-fork
  server APIs and pass a compatible draft-16 client gate before flipping
  capability bits.
- **Quiet-host performance evidence (C1).** Run the v2.0/v2.1 pipeline,
  WebSocket, `json-comp`, and `latency-1m` contracts on a named host.
- **Receive-side UDP GRO (C2).** Expose ancillary segment sizes and pass the
  pinned HTTP/3 gates.
- **HttpArena `async` adapter (C3).** Update and validate the external adapter.
- **Cluster runtime and timer/limiter ownership (M5).** The rate-limit table,
  index, and LRU now live in `src/http/rate_limit.zig`. Extract the nested
  cluster runtime and the connection parking state without changing public
  behavior.
- **Fork archives and platform closure (C13/M6-6).** Retain final archives,
  resolve pins from a second machine, and run the native Windows release job.
- **kTLS integration and splice.** Keep the standalone helper and the
  measured-benefit condition recorded in the deliberate boundaries.

### 8.3 Release verification

The final source passed `zig fmt --check`, `scripts/check_conventions.sh`,
`scripts/check_release_version.sh`, `scripts/check_docs.sh`,
`scripts/check_dependency_forks.sh`, the Debug and ReleaseSafe suites, the
ASan/UBSan suite through the pinned Nix shell, the Windows and macOS
cross-compile gates, the 10K fuzz smoke, and the downstream package consumer.
Compilation is not a foreign-runtime claim. The maintainer owns the merge, tag,
and publication; agents do not create, move, or push `v2.2.0`.

## 9. Version 2.3.0: `uz.sql` — PostgreSQL, SQLite, and Typed Rows

**Objective:** enterprise database access inside the per-core event loop with
no synchronization, context switches, or global pool locks. The module is
optional: a program that never imports `uz.sql` must not link a SQL driver, and
the core server must not depend on one.

**Module contract:** `uz.sql` is a Service-like module with per-worker state.
Each worker owns its own connections, statement cache, and row buffers. There
is no global pool, no cross-thread queue, and no request-path allocation. A
query that exceeds the configured statement, parameter, row, or field bound
returns a typed error; it never grows storage.

### Task D-0: Module surface, naming, and lifecycle

- Path: `src/sql/` (public `uz.sql`), not `src/db/`.
- Export a `Sql` config/service type, a per-worker `Db` handle, a `Tx` handle,
  a bounded `Rows` iterator, and typed parameter/row helpers.
- Integrate with the module lifecycle in Section 17.3 (FS-0). The service must
  start after the listener binds and stop before the worker loop is destroyed.
- Add a compile-time feature gate so `-Dsql=false` or a program that does not
  import the module links no SQL code.
- Document that the C ABI does not expose SQL in the first release; a separate
  ADR is required before adding C symbols.
- Keep secrets out of logs and error strings. A URL with a password is never
  printed verbatim.

### Task D-1: Pure Zig PostgreSQL wire parser (`src/sql/pg_wire.zig`)

- Frontend/Backend Protocol 3.0: startup, MD5 and SCRAM-SHA-256
  authentication, Parse, Bind, Execute, Describe, Sync, ReadyForQuery.
- TLS via the existing client TLS context; fail closed on certificate errors.
- Binary decoding for int2/int4/int8, float4/float8, text, varchar, bytea,
  bool, timestamp, date, uuid, numeric (bounded), and NULL.
- Bounded message framing: every backend message has a maximum size; an
  oversized or truncated message fails the connection with a stable error.
- Cancellation and deadline mapping from the timing wheel to the wire call.

### Task D-2: Per-core zero-lock socket pool (`src/sql/pool.zig`)

- 8 to 16 PostgreSQL sockets per physical worker, each bound to the worker's
  loop. No mutexes, no atomic CAS, no cross-thread queuing.
- Bounded acquire queue with a deadline; pool exhaustion returns
  `error.PoolExhausted` rather than allocating a new connection.
- Health check and reconnect policy with a bounded backoff and no thundering
  herd.
- Per-worker pool telemetry: active, idle, waiting, failed, reconnect count.

### Task D-3: Pipelined parameter serialization and execution

- Format multiple Parse/Bind/Execute frames into one socket write and await a
  single `Sync` round trip.
- Encode parameters directly into the pre-allocated client slab.
- Parameter count and total encoded size are compile-time or configured bounds.
- No string interpolation: every parameter is bound through the wire protocol.
  A literal SQL fragment helper, if added, must be an explicit escape hatch
  with a documented injection risk and a compile-time name.

### Task D-4: Prepared statement cache and binary row decoder

- Cache statement handles per worker connection.
- Typed row iterator over the read slab:
  ```zig
  var rows = try conn.query("SELECT id, randomnumber FROM World WHERE id = $1", .{target_id});
  while (try rows.next()) |row| {
      const id = row.get(i32, 0);
      const num = row.get(i32, 1);
  }
  ```
- Borrowed field slices stay valid only until the next `next`/`reset`/query.
  A `.keep()` or caller-buffer copy is required for deferred use.
- Column count, row count, field bytes, and total response bytes are bounded.

### Task D-5: HttpArena integration (`async-db`, `crud`)

- Implement `/db`, `/queries?count=N`, and `/updates?count=N`.
- Verify throughput above 300K RPS on `async-db`.
- Record the PostgreSQL version, TLS mode, pool size, worker count, and query
  latency distribution in the evidence directory.

### Task D-6: SQLite backend (`src/sql/sqlite.zig`)

- Pin a pre-generated SQLite amalgamation under `vendor/sqlite/`; compile it
  with `zig cc` and no CMake, Ninja, Perl, or Python.
- Support `:memory:`, file paths, WAL mode, busy timeout, and foreign keys.
- One writer per worker; document the SQLite concurrency model and the
  `SQLITE_BUSY` behavior. Do not pretend SQLite is a drop-in multi-writer
  replacement for PostgreSQL.
- The SQLite backend is optional. A program that enables only PostgreSQL must
  not link SQLite.
- Add license and provenance entries in `THIRD_PARTY_NOTICES.md`.

### Task D-7: Transactions, savepoints, and deadlines

- `Tx` supports `commit`, `rollback`, and bounded savepoints.
- A transaction is worker-local and cannot cross threads.
- Every query and commit/rollback has a deadline from the timing wheel or the
  module's bound.
- A cancellation or timeout must leave the connection usable or mark it failed;
  never return a connection with unknown transaction state to the pool.
- Test rollback on error, savepoint rollback, connection reset, and shutdown.

### Task D-8: Migrations (`src/sql/migrate.zig`)

- Ordered, embedded migration files with a checksum table.
- PostgreSQL uses an advisory lock; SQLite uses an exclusive transaction.
- Idempotent: a migration that has already run is skipped by checksum.
- A checksum mismatch fails closed with the migration name; never silently
  rewrite the schema.
- Provide `app.before`-style startup integration through the module lifecycle,
  not a hidden global.
- Test empty database, partial migration, concurrent starter, and rollback.

### Task D-9: Typed row mapping (explicit, no ORM)

- Add an explicit `FromRow`/`ToParam` trait layer only after the raw iterator is
  stable.
- No `@typeInfo`-driven schema generation, no runtime reflection, no ORM.
- A struct mapping declares its column names/indices and types; a mismatch is a
  compile-time or startup error.
- Benchmark compile time and binary size before adopting.

### Task D-10: Integration and assurance

- Unit tests for every wire message and every row type.
- SQLite in-memory integration tests run in CI; PostgreSQL integration tests
  run with a service container and skip with a written reason when unavailable.
- Fuzz the PostgreSQL wire decoder, SQLite value decoder, and migration
  checksum parser.
- Run ASan, UBSan, LSan, and the allocation gate.
- Measure p50/p99 query latency, pool wait time, and per-worker RSS.

### Task D-11: Documentation

- `docs/sql.md`: supported versions, TLS policy, pooling, transactions,
  migrations, SQLite limits, parameter binding, row lifetimes, and security.
- Runnable examples: PostgreSQL CRUD, SQLite local app, transaction + jobs.
- Explicitly state what is not supported: no ORM, no automatic schema
  reflection, no query builder in the first release, no cross-worker pool.

**Release mapping:** D-0 through D-5 and D-7 through D-11 in v2.3.0; D-6 SQLite
may land in v2.3.1 if it delays the PostgreSQL evidence. The module must join
the v3 security boundary register (SQL injection, TLS verification, secret
handling, pool exhaustion) before it is called production-ready.

---

## 10. Version 2.4.0: Comptime-Validated HTML Template Engine and SSR

**Objective:** secure server-side rendering with no runtime reflection or
dynamic allocations.

### Task H-1: Compile-time HTML template parser (`src/template/engine.zig`)

- Parse templates at comptime: detect `{{ item.id }}` substitutions, validate
  fields against the model type, and compile to literal slices plus typed
  accessors.

### Task H-2: SIMD AVX2/NEON HTML entity escaper (`src/template/escape.zig`)

- Vector-scan for `&`, `<`, `>`, `"`, and `'`; expand entities only on match.

### Task H-3: Zero-allocation streaming renderer

- Render into the per-connection write slab:
  ```zig
  pub fn render(writer: anytype, comptime template_str: []const u8, data: anytype) !void;
  ```
- No intermediate strings or heap builders.

### Task H-4: HttpArena `/fortunes` endpoint

- Query rows through the v2.3.0 client, insert
  `"Additional fortune added at request time."`, sort by message, and render
  the standard table with exact byte compliance.

---

## 11. Version 2.5.0: `uz.proto` and Native gRPC over HTTP/2

**Objective:** high-throughput Protobuf/gRPC service communication without C++
library dependencies.

**Patch note:** the 2.1.6 follow-up closure is scheduled as 2.5.5 in section
11.1. It is a carry-over track, not a prerequisite for the proto/gRPC work. `uz.proto` is a shared, bounded wire codec used by gRPC,
OTLP tracing, and application messages. It is not a `.proto` generator and it
does not require protoc.

### Task R-0: `uz.proto` shared wire codec (`src/proto/`)

- Public module `uz.proto`; gRPC imports it downward, and tracing uses it for
  OTLP. Do not keep a second protobuf decoder under `src/grpc/`.
- Supported wire types: varint (int32/int64/uint32/uint64/bool/enum), zigzag
  sint32/sint64, fixed32/fixed64 (including float/double), and
  length-delimited bytes/string/embedded messages.
- Repeated fields, packed repeated scalars, optional presence, maps (encoded as
  repeated entry messages), and oneofs with an explicit tag.
- The message contract is declared beside the struct fields, not generated from
  a `.proto` file. No runtime schema registry, no `protoc`, no C++ protobuf.
- Decode borrows bytes from the input slice; encode writes into caller-owned
  storage. No allocation in either direction.
- Unknown fields are skipped with a bounded skip, never retained unless the
  caller explicitly asks for them.
- Every length, field count, recursion depth, and total message size has a
  configured bound. Truncated and malformed input returns a stable error.
- Provide a conformance suite against the canonical protobuf test vectors and
  round-trip tests for every supported type.
- Document the mapping rules and the unsupported features in `docs/proto.md`.

### Task R-1: Protobuf wire decoder (`src/proto/decode.zig`)

- Varint (int32, int64, uint32, bool), fixed32/fixed64 floating point,
  length-delimited strings and bytes borrowed from the frame.
- Bounded recursion and unknown-field skipping.
- Golden vectors for negative integers, max values, truncated varints, and
  overlong encodings.

### Task R-2: gRPC 5-byte length-prefixed frame machine (`src/grpc/frame.zig`)

- Byte 0 compression flag, bytes 1-4 big-endian length.
- Frame directly into HTTP/2 DATA streams.
- Compressed-message support only when the configured codec is enabled; reject
  an unknown flag before reading the body.
- Bound the frame size and the number of frames per stream.

### Task R-3: HTTP/2 HEADERS, DATA, and TRAILERS state machine

- Validate `content-type: application/grpc`, execute the request, emit
  `:status = 200`, DATA frames, and `grpc-status` / `grpc-message` trailers.
- Map malformed frames to the correct gRPC status, not a generic HTTP 500.
- Keep trailers inside the bounded write queue.

### Task R-4: Unary, client-streaming, server-streaming, bidirectional

- Bridge `RST_STREAM` cancellation to executor contexts.
- Bound active methods and in-flight messages per connection.
- Define the handler contract without `anytype` in the public API.

### Task R-5: HttpArena `unary-grpc` suite

- Implement `benchmark.BenchmarkService/GetSum`.
- Verify on `unary-grpc` (h2c) and `unary-grpc-tls` (h2).
- Record the proto codec cost separately from the HTTP/2 transport cost.

### Task R-6: Toolchain upgrade to Zig 0.17.0

**Release notes:** <https://ziglang.org/download/0.17.0/release-notes.html>

**Current state:** 1.9.0 pins Zig 0.16.0 in the Nix shell, the package
manifest, CI workflows, agents, skills, and documentation. The 2.5.0 upgrade
moves the whole repository to 0.17.0; it is a platform change, not part of the
gRPC protocol work.

#### R-6.1 Skill refresh (mandatory before toolchain edits)

The repository vendors project skills in `.agents/skills/` and pins them in
`skills-lock.json`. The Zig 0.16 skill must be **replaced** by the 0.17 skill,
not kept alongside it. This is a prerequisite for the toolchain upgrade and is
reviewed with the same care as a dependency pin.

Run from the repository root:

```sh
npx skills add https://github.com/zigcc/skills --skill zig-0-17
npx skills list --json
npx skills remove zig-0.16 -y
npx skills list --json
```

Rules:

- Install `zig-0-17` first and verify `.agents/skills/zig-0-17/SKILL.md` exists
  before removing the old skill.
- Remove `zig-0.16` with the CLI. Do not leave both skills installed and do not
  hand-edit a vendored `SKILL.md`.
- Let the CLI update `skills-lock.json`. If it does not, stop and report the
  tool defect; do not hand-edit the lock as a silent workaround.
- Keep the scope project-local. Do not install into the global user scope
  unless the maintainer explicitly asks.
- Update every agent prompt that names the old skill:
  `.opencode/agents/*.md`, `.codex/agents/*.toml`, `AGENTS.md`,
  `CONTRIBUTE.md`, and any other active instruction file. The agent roster
  currently names `zig-0.16` in the transport, protocol, build, crypto, FFI,
  and verification instructions.
- Do not confuse the `zig-0.16` **skill** with the `uwz/zig-0.16` **libxev
  integration branch**. The branch remains until `uwz/zig-0.17` exists, all
  four dependency views are repinned, and the dependency policy review is
  complete.
- Commit the skill refresh with the toolchain pin and agent-instruction
  updates. Do not mix it with protocol or feature commits.

Verification:

```sh
test -f .agents/skills/zig-0-17/SKILL.md
test ! -e .agents/skills/zig-0.16
npx skills list --json
rg -n '"zig-0\.16"' skills-lock.json && exit 1
rg -n 'zig-0\.16' .opencode/agents .codex/agents AGENTS.md CONTRIBUTE.md || true
git diff -- skills-lock.json .agents/skills .opencode/agents .codex/agents
```

The last `rg` must show only `uwz/zig-0.16` branch references, never a skill
load instruction. `npx skills list --json` must show `zig-0-17` and no
`zig-0.16` entry.

Acceptance:

- [ ] `zig-0-17` is installed and pinned in `skills-lock.json`.
- [ ] `zig-0.16` is absent from `.agents/skills/`, `skills-lock.json`, and all
      agent prompts.
- [ ] The skill update is committed with the Zig 0.17 toolchain pin.
- [ ] Offline/CI restore uses `npx skills experimental_install
      --frozen-lockfile` after the lock is committed.
- [ ] No vendored `SKILL.md` was hand-edited.

**Requirements:**

- [ ] Complete R-6.1: install `zig-0-17`, remove `zig-0.16`, update
      `skills-lock.json`, and update every agent prompt that names the skill.
- [ ] Read the 0.17.0 release notes and inventory every breaking change that
      affects this repository: `std.Io`, `@cImport`, build APIs, allocator
      interfaces, threading, networking, and the C ABI shim.
- [ ] Land the upgrade as its own reviewable change before or after the gRPC
      work, never mixed with protocol implementation commits.
- [ ] Update the toolchain pins and every derived view: `flake.nix`,
      `flake.lock` (`zig-overlay`), `build.zig.zon`
      (`minimum_zig_version`), `build.zig.zon.nix`, and the `zig` package
      version used by the Nix shell.
- [ ] Update CI toolchain installs in `.github/workflows/*` from 0.16.0 to
      0.17.0 and keep the pinned action SHAs unchanged.
- [ ] Update the C ABI and package-consumer checks so they build with the same
      compiler version as the library.
- [ ] Migrate source, examples, tests, fuzz targets, and build scripts; do not
      leave compatibility shims for 0.16.0 unless they are required by a
      supported target.
- [ ] Update agents, skills, and documentation: `AGENTS.md`,
      `CODING_CONVENTION.md`, `.opencode/agents/*.md`, `.codex/agents/*.toml`,
      `.agents/skills/*/SKILL.md`, `skills-lock.json`, `SKILL.md`,
      `README.md`, `CODEBASE.md`, `CONTRIBUTE.md`, `SECURITY.md`,
      `CI_CD_PIPELINE.md`, and every active `docs/*` toolchain reference.
      Historical changelog entries and release notes keep their original
      version.
- [ ] Update the `Zig 0.16.0 is the only supported toolchain` boundary in
      `docs/roadmap.md` and add a changelog migration note for consumers who
      pin the package.

**Acceptance:**

- [ ] R-6.1 is green: `zig-0-17` is installed and pinned, `zig-0.16` is absent
      from the skill tree, lock file, and agent prompts.
- [ ] `zig version` reports 0.17.0 in the pinned Nix shell and in CI.
- [ ] Every gate in section 1.3 passes, plus the sanitizer, MSan,
      cross-target, package-consumer, fuzz, Windows runtime, Autobahn,
      h1spec, HTTP/3, and benchmark checks.
- [ ] No active agent, skill, workflow, build file, or user-facing document
      still claims 0.16.0; historical release material is unchanged.
- [ ] The upgrade commit can be reverted independently of the gRPC work.

---

### 11.1 Version 2.5.5: Follow-up closure plan

**Status:** planned. This section merges the standalone `2.1.7-TODO.md` draft,
renumbered for the 2.5.5 release slot. The 2.1.6 tag and release commit are
immutable: `v2.1.6` = `bd40454b559ba954935101372cdbb5f496a3ff21`; libxev pin
`c49f6dfb83038c146232472c063e4b2681d098d8`. Do not amend, retag, or force-push
2.1.6. Every correction lands in 2.5.5 as a revert or follow-up.

The design rationale for the engine/timer work is in Part II P5 and P6; this
section is the execution tracker for the patch.

> Audience: the maintainer, systems engineers, and autonomous coding agents.
> Source: the 2.1.6 release at `bd40454b559ba954935101372cdbb5f496a3ff21`
> and the libxev integration pin
> `c49f6dfb83038c146232472c063e4b2681d098d8`.
> Target: `v2.5.5`, a patch after v2.5.0. It closes the C-items carried
> from the 2.1.6 release. The 2.1.6 tag and commit remain immutable.
> Constraints: `AGENTS.md`, `CODING_CONVENTION.md`, `CONTRIBUTE.md`, and
> `CI_CD_PIPELINE.md` are binding for every change. Zero hot-path allocation,
> shared-nothing worker isolation, pure functions, explicit named types,
> bounded startup memory, no emojis, and no weakening of any gate.

---

#### 11.1.0 Release preflight: install `untangle-codebase`

Before starting the 2.5.5 milestones, every developer and agent must install
the codebase-understanding skill and wire it into the agent system:

```sh
npx skills add caldoai/skills --skill untangle-codebase
```

Integration requirements:

- [x] Add `untangle-codebase` to the project skill roster and `AGENTS.md`
      Skill Library; do not hand-edit the vendored `SKILL.md`.
- [x] Load it in the agent prompts that plan, implement, review, or integrate
      codebase-wide changes: `.opencode/agents/architect.md`,
      `developer.md`, `reviewer.md`, `integrator.md`, and the matching
      `.codex/agents/*.toml` files. Add it to a domain specialist only when the
      task spans that module and the skill helps the pass.
- [x] Update `CONTRIBUTE.md` so a new contributor knows the skill exists and
      how to install it with `npx skills add`.
- [x] Let the CLI update `skills-lock.json`; verify
      `.agents/skills/untangle-codebase/SKILL.md` and
      `npx skills list --json` show the skill.
- [x] Run one untangle pass over the repository before milestone work. The
      2.2.0 pass is recorded at
      `/tmp/nix-shell.gay4pM/opencode/untangle-2.2.0.md` (outside the repository).
      The rate-limit extraction is landed; the remaining oversized-file
      ownership debt is tracked for 2.3.0.
- [x] Commit the skill install and agent wiring as a release-preflight commit;
      do not mix it with protocol, module, or dependency-pin commits.
- [x] If the skill's advice conflicts with `AGENTS.md`,
      `CODING_CONVENTION.md`, or a project ADR, the project rule wins.

Verification:

```sh
npx skills list --json
test -f .agents/skills/untangle-codebase/SKILL.md
rg -n 'untangle-codebase' AGENTS.md CONTRIBUTE.md .opencode/agents .codex/agents
git diff -- skills-lock.json .agents/skills .opencode/agents .codex/agents
```

Acceptance:

- [x] `untangle-codebase` is installed and pinned in `skills-lock.json`.
- [x] The architect, developer, reviewer, and integrator prompts reference it.
- [x] One untangle pass has been run and its output location is recorded.
- [x] The skill install is committed separately from the 2.5.5 code changes.

---

#### 11.1.1 Why this milestone exists

2.1.6 fixed the kqueue timer spin, hardened the benchmark harnesses, and
pinned libxev XEV-003 through XEV-005. It deliberately left several items
open. They are recorded here so they can be implemented without re-litigating
the 2.1.6 release or moving its tag.

The v2.1.6 release is immutable:

- uWebZockets tag: `v2.1.6`
- release commit: `bd40454b559ba954935101372cdbb5f496a3ff21`
- libxev pin: `c49f6dfb83038c146232472c063e4b2681d098d8`
- lsquic mirror: `413ca7c1acb443b0f9f7aa28611ca723c6738844`
- lsquic integration pin: `85bd081c9103c077a7cc98271d09334d0f1043d4`
- h1spec mirror/pin: `f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e` /
  `999ba9e8f318b1c0ebbff1278b98bc5833f1af18`

Do not amend, retag, or force-push `v2.1.6`. Any correction lands in 2.5.5 as
a revert or follow-up commit.

#### 11.1.2 Open-item inventory

| # | Open item | Why it is still open | Blocks | Milestone |
| :-: | :--- | :--- | :--- | :--- |
| C1 | libxev timer timespec carry (XEV-006) | `timer_next` adds nanoseconds without carrying into seconds. 2.1.6 hides this with `tick_delay_ms`; a near-second arm can still become a roughly one-second wait. | Removing the scheduler workaround; full kqueue/epoll/io_uring/IOCP timer accuracy | M1 |
| C2 | Queued-result cancellation (XEV-007) | Canceling a completion whose result is already in the libxev completion queue returns success but leaves the target registered; the callback still runs. Replacing the result naively can lose an accepted socket or read data. 2.1.6 documents the ordering limit instead of fixing it. | Strict cancel semantics; close-before-callback; safe accepted-socket disposal | M2 |
| C3 | Scheduler timer-error fail-stop | A non-`Canceled` timer error sets `active = false` and logs, but the wheel stops silently. `verify_shutdown` cannot distinguish this from a clean drain. | Deadline liveness; diagnosable shutdown | M3 |
| C4 | macOS uWebZockets runtime gate | No hosted uWebZockets macOS runtime job. The downstream suite was not run for 2.1.6; two known pre-existing failures remain (`config: default slab carries the router region at the end`, `kernel: validate_umem accepts page-aligned power-of-two regions`). | Claiming macOS runtime support; validating `set_nodelay` on Darwin | M4 |
| C5 | Full H2/TLS matrix after 2.1.6 | Only reduced plaintext H2 and the rapid HTTP harness were run locally. The committed 64-2048 x 1/8-stream matrix has not been rerun after the timer and libxev changes; macOS harness paths are not exercised by CI. | Publishing fresh 2.1.x H2 evidence; mac/Linux cohorts | M5 |
| C6 | lsquic integration sync | The read-only mirror is at upstream `cd23e526...`, but `uwz/main` still pins `85bd081c...`. The upstream zero-application-close-error fix and the BBRv3 range are not in the integration pin. | HTTP/3 close-error correctness and provenance closure | M6 |
| C7 | macOS reset/EINVAL log noise | `src/core/tcp.zig` still logs expected reset errors as `read error: error.Unexpected` because libxev maps the Darwin errno to `Unexpected`; this is noise, not a wire failure. | Clean macOS benchmark logs; operator diagnosis | M3/M4 |
| C8 | Windows native release gate | The release workflow verifies Linux and cross-compiles Windows; the native `windows-2025` runtime job is not part of the tagged release gate. | Windows runtime support claim | M7 |
| C9 | Retained fork archives and second-machine resolution | The release records pins, but the retained archive/local bare mirror and second-machine resolution are still carried evidence work. | Supply-chain reproducibility | M7 |

---

#### 11.1.3 M0 — Freeze the 2.5.0 baseline

**Objective:** establish the exact starting point and ensure no open item
accidentally depends on an unreleased local tree.

**Files:** none for the baseline itself; any new branch starts from the
v2.5.0 release commit.

- [ ] Confirm `main` is at the v2.5.0 release commit and the worktree is clean.
- [ ] Confirm `v2.1.6` still resolves to
      `bd40454b559ba954935101372cdbb5f496a3ff21` and was not moved.
- [ ] Confirm the 2.1.6 GitHub release is public and not a draft.
- [ ] Confirm the libxev integration tip is
      `c49f6dfb83038c146232472c063e4b2681d098d8` and the maintained fork
      has only `main` plus `uwz/zig-0.16`.
- [ ] Read section 0 and choose the first milestone by dependency order.
- [ ] Create a branch for the milestone; do not work directly on `main`.

**Acceptance:** clean baseline, immutable tag, and selected milestone recorded
in the implementation PR.

**Owner:** maintainer; `build_vendor` confirms dependency identity.

---

#### 11.1.4 M1 — XEV-006: normalize libxev timer timespecs

**Objective:** remove the scheduler-side second-boundary workaround by making
libxev carry nanoseconds correctly on every timer backend.

**Current workaround:** `src/core/timer.zig` `tick_delay_ms` keeps each arm
inside the current second. It prevents the roughly one-second stall but makes
the effective tick shorter near a boundary and leaves `TimerContext` exposed.

**Files:**

- maintained libxev fork:
  `src/backend/kqueue.zig`, `src/backend/epoll.zig`,
  `src/backend/io_uring.zig`, `src/backend/iocp.zig`,
  `src/backend/wasi_poll.zig`;
- uWebZockets: `src/core/timer.zig`, `src/tests/core_tests.zig`,
  `docs/dependency_forks.md`, `docs/libxev_kqueue_findings.md`,
  `THIRD_PARTY_NOTICES.md`, `AGENTS.md`, `CONTRIBUTE.md`, `CODEBASE.md`,
  `build.zig.zon*`, `CHANGELOG.md`.

**Required behavior:**

- Normalize the absolute deadline after adding milliseconds:
  `sec += nsec / 1_000_000_000; nsec %= 1_000_000_000`.
- Apply the same rule to every timer implementation, not only kqueue.
- Keep the API and `timer_next(next_ms)` semantics unchanged.
- Remove `tick_delay_ms` only after the fork pin contains the fix; then use
  `tick_ms` directly again.
- Verify `TimerContext` and `Scheduler` across a second boundary.

**Checklist:**

- [ ] Create a libxev branch/PR with ledger ID XEV-006 and the standard
      `uwz(<area>): ...` commit body.
- [ ] Add a deterministic test that sets a deadline in the last millisecond of
      a second and asserts the next callback is no later than the requested
      delay plus a small tolerance.
- [ ] Add a scheduler test that observes many ticks across a second boundary
      and asserts the maximum gap is bounded by the configured tick.
- [ ] Run `zig build test` on macOS arm64 and x86_64, FreeBSD, Linux, and
      Windows; run the fork test binary on native macOS/FreeBSD.
- [ ] Merge with a merge commit; pin the resulting integration tip in all four
      dependency views.
- [ ] Remove `tick_delay_ms` and its test-only workaround from uWebZockets.
- [ ] Update the ledger, findings, changelog, and current-pin surfaces.
- [ ] Run UWebZockets tests, the kqueue macOS job, and the downstream
      `zig build test` against the new pin.

**Acceptance:** no timer callback is delayed by a second-boundary artifact;
the workaround is deleted; all four views agree on the new pin; macOS kqueue
and Linux tests are green.

**Owners:** `build_vendor` and `transport_io`; `verification` runs the matrix.

**Retirement:** delete XEV-006 once the fork base or upstream contains the
normalization.

---

#### 11.1.5 M2 — XEV-007: queued-result cancellation semantics

**Objective:** make cancellation correct when the completion is already in
libxev's completion queue but its callback has not run.

**Problem:** `stop_completion` currently returns when `c.result != null`.
The cancel callback reports success, but the queued target callback still runs.
A naive replacement with `Canceled` can lose an accepted socket or read data.

**Required behavior:**

- Define and document per-operation cancellation:
  - read/recv/pread/recvfrom: discard queued data only when the caller accepts
    that loss;
  - accept: either deliver the accepted socket to a callback that can close it,
    or close it inside the cancellation path;
  - write/send/close/shutdown: preserve idempotent completion and error
    reporting;
  - timer/cancel/machport/proc: define the wakeup/message disposition.
- A canceled target must not rearm or invoke a second callback after cancel
  success.
- The active count and filter deletion must remain balanced.
- Document the ordering guarantee in `src/backend/kqueue.zig` and the public
  API docs.

**Checklist:**

- [ ] Add a regression test: readable pipe, `submit()` queues the read result,
      then cancel before the callback; the read callback must not run with
      success, and the cancel callback must report the documented outcome.
- [ ] Add an accept-specific test that proves no accepted fd is leaked.
- [ ] Add a close/shutdown test that proves idempotence and active-count
      balance.
- [ ] Add a test for a canceled target that tries to return `.rearm`.
- [ ] Verify downstream `close_connection`/`close_server` and the cluster
      signal-watcher test under load.
- [ ] Run the exact-head macOS and FreeBSD kqueue suites.

**Acceptance:** queued cancellation has one documented, tested meaning; no
UAF, socket leak, lost read result, or stale callback; the downstream close
path remains safe.

**Owners:** `transport_io`; `reviewer` audits the result; `verification` runs
the downstream stress test.

**Retirement:** delete XEV-007 when the fork base or upstream provides
equivalent semantics.

---

#### 11.1.6 M3 — Scheduler fail-stop and macOS error noise

**Objective:** make timer failure observable and reduce misleading macOS logs.

##### M3-1 Scheduler fail-stop

- [ ] Add a `failed`/health flag to `Scheduler` (or a typed health result).
- [ ] On a non-`Canceled` timer error, stop arming and make
      `App.verify_shutdown` return `ShutdownIncomplete` or a named timer
      failure instead of silently accepting a dead wheel.
- [ ] Add a test that injects or simulates a timer failure and proves
      shutdown observes it.
- [ ] Keep `Canceled` and intentional stop paths clean.
- [ ] Document the fail-stop contract in `docs/callback_lifecycle.md` and
      `docs/architecture.md`.

##### M3-2 macOS reset/EINVAL log noise

- [ ] Trace the Darwin `read` errno that libxev maps to
      `error.Unexpected`.
- [ ] Classify expected peer reset/EOF cases; log them at debug or suppress
      them with a comment proving the connection is already closed.
- [ ] Keep unexpected errno visible at warn/error.
- [ ] Test a reset peer and a normal close; do not hide real transport faults.

**Acceptance:** a dead scheduler cannot pass shutdown verification; macOS
benchmark logs no longer contain repeated expected-reset `Unexpected` lines.

**Owners:** `transport_io`; `verification` runs the macOS probe.

---

#### 11.1.7 M4 — macOS uWebZockets runtime gate

**Objective:** make macOS a real runtime target instead of a compile-only
claim.

**Known failures to resolve first:**

- `config: default slab carries the router region at the end` expects
  `683_382_400`; macOS reports `683_300_480`.
- `kernel: validate_umem accepts page-aligned power-of-two regions` fails on
  macOS; AF_XDP/UMEM is Linux-only and the test should use the platform page
  size or skip non-Linux.

**Checklist:**

- [ ] Determine the macOS `TcpConnection` slab delta from the platform layout,
      not a guessed constant. Prefer a documented platform-specific expected
      value or a test that derives the exact expected total from the
      platform-dependent structure.
- [ ] Skip or correct the UMEM test for non-Linux targets without weakening
      the Linux coverage.
- [ ] Add a macOS workflow job (or a macOS job to `test.yml`) that runs the
      full `zig build test` on `macos-latest`.
- [ ] Include the `set_nodelay` reset-peer test and the timer tests in the
      macOS job.
- [ ] Run the full suite on macOS at the 2.5.5 release commit; record the
      exact count and skips.
- [ ] Update `docs/operations.md`, `docs/deployment.md`, `README.md`, and
      `docs/roadmap.md` only after the job is green.
- [ ] Keep the two known failures in the release notes until closed.

**Acceptance:** full uWebZockets macOS suite green in CI; no unexplained
skips; the support claim matches the job result.

**Owners:** `verification` and `build_vendor`; `transport_io` reviews the
platform-specific slab/UMEM assumptions.

---

#### 11.1.8 M5 — Full H2/TLS matrix and macOS harness

**Objective:** produce fresh, reproducible 2.1.x H2 evidence after the timer
and libxev changes.

**Checklist:**

- [ ] Run the committed full matrix: 64, 256, 512, 1,024, and 2,048
      connections; 1 and 8 streams; three 10-second samples with the
      documented 2-second warmup.
- [ ] Run the plaintext-cluster control and the TLS-cluster cohort.
- [ ] Keep macOS and Linux results in separate host/backend cohorts.
- [ ] Run the macOS harness path (`lsof`, `ps`, CPU/RSS sampling) and verify
      listener ownership and clean shutdown.
- [ ] Record first, peak, and last RSS, cohort medians, p99 spread, and the
      run-status sentinel.
- [ ] Archive the raw output under `benchmarks/results/` using the
      three-file policy: archive, README, manifest.
- [ ] Compare only same-host, same-backend cohorts; do not turn the result
      into a competitive claim.
- [ ] If the matrix cannot run, re-declare the limit with the host blocker and
      a restoration date.

**Acceptance:** fresh artifacts and a filled characterization table; every
number links to raw evidence; no hand-edited output.

**Owners:** `verification`; `build_vendor` records host/toolchain provenance.

---

#### 11.1.9 M6 — lsquic integration sync and HTTP/3 evidence

**Objective:** close the gap between the synchronized lsquic mirror and the
older integration pin.

**Current state:** mirror `cd23e526e53387ad7a2fada9a4479d2353ee2b42`;
integration pin `85bd081c9103c077a7cc98271d09334d0f1043d4`. The reviewed
upstream range adds BBRv3, BBR-Copilot, ACK range-merge and ACK-frame capacity
fixes, and send-controller accounting; the 2.1.6 zero application
CONNECTION_CLOSE fix remains in the integration gap.

**Checklist:**

- [ ] Review the mirror-to-integration range and the upstream commit
      `413ca7c` for build, license, and HTTP/3 behavior changes.
- [ ] Create a `sync/...-YYYYMMDD` branch from `uwz/main`; merge the compatible
      upstream commit with `--no-ff`.
- [ ] Resolve LSQ-001/LSQ-002 conflicts in favor of the ledger invariants.
- [ ] Run the HTTP/3 cross-implementation gate and the close-error test.
- [ ] Merge the integration PR and pin the resulting full commit in all four
      views.
- [ ] Update `scripts/dependency_mirrors.env`, `docs/dependency_forks.md`, and
      `THIRD_PARTY_NOTICES.md`.
- [ ] If the sync is deferred, record the reason and restore date; do not
      silently keep the old pin.

**Acceptance:** lsquic mirror and integration pin are consistent, the HTTP/3
gate is green, and the zero-error close behavior is tested.

**Owners:** `build_vendor`, `quic_h3`, and `verification`.

---

#### 11.1.10 M7 — Release 2.5.5

**Objective:** publish the 2.5.5 patch only after the selected open items are
fixed or explicitly re-declared.

**Checklist:**

- [ ] Update `src/version.zig`, `build.zig.zon`, `flake.nix`,
      `include/uWebZockets.h`, ABI tests, and all documentation headers to
      2.5.5.
- [ ] Add a dated `CHANGELOG.md` section with fixed, changed, security, and
      limits sections. Do not rewrite 2.1.6 history.
- [ ] Add/update ledger rows and remove closed carry-over bullets.
- [ ] Run the exact-mirror check, empty-cache rebuild, full tests, sanitizers,
      fuzz, Autobahn, h1spec, HTTP/3, package consumer, and cross-target
      matrix.
- [ ] Run the native Windows runtime job and the macOS runtime job for the
      release commit.
- [ ] Archive retained fork commits and resolve each pin from a second
      machine or retained archive.
- [ ] Tag `v2.5.5` on the merge commit and push the tag; confirm the Publish
      workflow creates the release.
- [ ] Do not move or delete `v2.1.6`.

**Acceptance:** all release gates green; tag and release resolve to the same
commit; every remaining limit is linked in the changelog.

**Owners:** maintainer and `integrator`; `build_vendor` owns provenance.

---

#### 11.1.11 Sequencing

1. M0 baseline.
2. M1 XEV-006, because it removes a live workaround and changes the libxev pin.
3. M2 XEV-007, while the kqueue state machine is fresh.
4. M3 scheduler fail-stop and log noise.
5. M4 macOS runtime, because it changes platform support claims.
6. M5 full H2 matrix, after the code and platform gates stabilize.
7. M6 lsquic sync, separate from libxev.
8. M7 release.

Do not combine M1/M2 with M6, and do not combine a dependency pin with an
unrelated feature change. Each milestone gets its own reviewable PR and raw
evidence.

---

#### 11.1.12 Open questions

- Should queued cancellation discard read data by default, or require a
  caller-supplied policy?
- Should an accepted socket discovered during cancellation be delivered to
  the callback for closing, or closed directly by the backend?
- Is XEV-006 small enough to upstream into the next compatible libxev base,
  or should it remain a fork ledger row?
- Should macOS become a full runtime support claim in 2.5.5 or remain
  compile-only until the macOS job has been green for two consecutive
  releases?
- Is the lsquic 413ca7c close-error fix required for 2.5.5, or can it be
  re-declared to the next HTTP/3 dependency refresh?
- Which Windows runtime failures, if any, remain after the 2.1.6 cross-build?

---

#### 11.1.13 Appendix A: command reference

```sh
# Baseline
git fetch origin main
git switch main
git pull --ff-only
git rev-parse HEAD v2.1.6^{commit}
git status --short --branch

# Repository gates
zig fmt --check build.zig build.zig.zon builds src examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
sh scripts/check_docs.sh
sh scripts/check_dependency_forks.sh
sh scripts/check_dependency_forks.sh --exact-mirrors
zig build test --summary all

# Sanitizers and portability
nix develop "path:." -c zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
nix develop "path:." -c zig build msan -Dmemory-sanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --summary all
zig build test-compile -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --summary all

# Fuzz and package
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
sh scripts/check_package_paths.sh
(cd tests/package_consumer && nix develop "path:../.." -c zig build check -Doptimize=ReleaseSafe --summary all)

# Empty-cache rebuild
cache=$(mktemp -d)
ZIG_GLOBAL_CACHE_DIR="$cache/global" ZIG_LOCAL_CACHE_DIR="$cache/local" \
  zig build test --summary all

# libxev fork checks
cd /path/to/farbenbuilds/libxev
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --summary all
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSafe --summary all
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --summary all
```

---

#### 11.1.14 Appendix B: file and ownership map

| Area | Primary files | Owner |
| :--- | :--- | :--- |
| Scheduler/timer | `src/core/timer.zig`, `src/core/timer_wheel.zig`, `src/tests/core_tests.zig` | `transport_io` |
| kqueue/libxev | fork `src/backend/kqueue.zig`, `docs/libxev_kqueue_findings.md`, `docs/dependency_forks.md` | `transport_io`, `build_vendor` |
| Socket options | `src/core/tcp.zig`, `src/tests/core_tests.zig` | `transport_io` |
| Shutdown/health | `src/router/app.zig`, `docs/callback_lifecycle.md` | `transport_io`, `reviewer` |
| Benchmarks | `scripts/benchmark_h2_tls.sh`, `scripts/benchmark_http.sh`, `benchmarks/` | `verification` |
| macOS/Windows CI | `.github/workflows/`, `docs/operations.md`, `docs/deployment.md` | `build_vendor`, `verification` |
| lsquic | `build.zig.zon*`, `docs/dependency_forks.md`, `THIRD_PARTY_NOTICES.md` | `build_vendor`, `quic_h3` |
| Release | `CHANGELOG.md`, `src/version.zig`, `include/uWebZockets.h`, `flake.nix`, `scripts/` | maintainer, `integrator` |

---

#### 11.1.15 Definition of done for 2.5.5

- [ ] Every C-item is fixed and verified or explicitly re-declared with
      evidence and a restoration criterion.
- [ ] No new `TODO`, `FIXME`, `XXX`, or `HACK` markers exist in the
      repository.
- [ ] No branch, tag, or release from 2.1.6 was moved.
- [ ] The exact libxev and lsquic pins are reachable, reviewed, and recorded
      in all four views.
- [ ] The macOS and Windows runtime claims match the actual jobs.
- [ ] The full test, sanitizer, fuzz, compliance, and benchmark evidence is
      linked from `CHANGELOG.md` and the release notes.
- [ ] A new reader can reproduce the release from the recorded commands and
      artifacts without private context.

---

## 12. Version 2.6.0: Server-Sent Events and Token Streaming

**Objective:** zero-allocation real-time push for dashboards and LLM token
streams.

### Task E-1: `text/event-stream` formatting engine (`src/http/sse.zig`)

```zig
pub const SseSession = struct {
    pub fn send_event(self: *SseSession, event: ?[]const u8, data: []const u8, id: ?[]const u8) !void;
    pub fn send_comment(self: *SseSession, comment: []const u8) !void;
    pub fn close(self: *SseSession) void;
};
```

- Format `event: ...\ndata: ...\nid: ...\n\n` directly into the output slab.

### Task E-2: Chunked HTTP/1.1 and HTTP/2 DATA push

- Set `Content-Type: text/event-stream`, `Cache-Control: no-cache`, and
  `Connection: keep-alive`; flush each token immediately.

### Task E-3: Reconnection lifecycle and `Last-Event-ID`

- Parse `Last-Event-ID` on reconnect and expose a replay hook from a bounded
  ring buffer.

### Task E-4: Bounded backpressure and slow-client drop policy

- Watch write-queue occupancy; discard events or disconnect slow clients to
  protect bounded slabs.

---

## 13. Version 2.7.0: `uz.sessions`, `uz.jwt`, and the Security Suite

**Objective:** standard production security, session, and token infrastructure.
The module surface is optional; a program that never imports sessions or JWT
must not link their code or crypto paths beyond the existing BoringSSL/std
crypto already used by TLS.

**Current state:** `src/http/cookie.zig` already provides RFC 6265 parsing,
`CookieJar`, `Set-Cookie` formatting, and HMAC-SHA256 signing helpers.
`src/http/middleware.zig` already provides Basic/Bearer auth, CORS, security
headers, and a token-bucket rate limiter. Do not re-create those modules; build
the session and JWT layers on top of them.

### Task M-1: `uz.sessions` sealed-cookie sessions (`src/sessions/`)

- Stateless sealed cookie by default: AEAD AES-256-GCM (existing
  `crypto_subtle.encrypt_aes_gcm`/`decrypt_aes_gcm`) or an equivalent
  authenticated construction. Do not use a bare HMAC envelope for secret data.
- Keyring with key ids and rotation: one active key, bounded previous keys for
  verification, explicit retirement. Zeroize key material after use.
- Bounded payload: typed binary or explicit JSON codec into a fixed buffer;
  maximum session size, cookie size, and field count. No allocation on the
  request path.
- Cookie attributes: `HttpOnly`, `Secure`, `SameSite=Lax/Strict/None`,
  `Path`, `Max-Age`, `Expires`; domain is explicit, never inferred silently.
- Session fixation prevention: rotate the session identifier/key material on
  privilege change and login.
- Idle and absolute timeouts; `logout` clears the cookie; expiry is checked
  against the injected clock, not wall-clock calls scattered through code.
- Optional store-backed sessions (SQL or memory cache) for revocation and
  server-side state; stateless remains the default. Document that a stateless
  session cannot be revoked before expiry without a store.
- CSRF token helper bound to the session, with constant-time comparison.
- Tests: tamper, bit-flip, truncated cookie, wrong key id, expired, replayed,
  fixed, oversized, missing cookie, rotated key, and concurrent requests.
- Paths: `src/sessions/session.zig`, `src/sessions/keyring.zig`,
  `src/sessions/cookie.zig` (if a wrapper is needed), `docs/sessions.md`.

### Task M-2: Token-bucket rate limiter with per-core sharding (`src/http/rate_limit.zig`)

- The current limiter lives in `src/http/middleware.zig`; extract it to the
  named module `src/http/rate_limit.zig` only if it removes complexity from
  the middleware file. Keep the public `middleware` re-exports.
- Lock-free token buckets sharded per core; reject with `429` plus
  `Retry-After` and `X-RateLimit-Remaining`.
- Bound table size, key size, and eviction work; exact-oldest eviction is
  already documented in the 2.1-H1 closure. Do not regress it.

### Task M-3: Declarative CORS and security headers (`src/http/headers.zig`)

- The current CORS/security headers live in `src/http/middleware.zig`; extract
  only when the module split has a clear owner and no public API break.
- Configurable origins, methods, headers, credentials.
- Emit `Strict-Transport-Security`, `X-Content-Type-Options`,
  `X-Frame-Options`, `Content-Security-Policy`.
- Test preflight, wildcard rules, credential rules, duplicate headers, and
  header injection.

### Task M-4: `uz.jwt` token verification (`src/jwt/`)

- Compact JWT parsing with strict base64url; reject `none`, padded base64, and
  non-canonical encodings.
- Algorithms: HS256 (shared secret), RS256/RS384/RS512 (BoringSSL RSA),
  ES256/ES384 (BoringSSL ECDSA), EdDSA (Ed25519). Start with HS256, RS256,
  ES256, and EdDSA; add others only with vectors.
- Algorithm allowlist is mandatory; never select the verifier from the token
  header alone. This is the algorithm-confusion defense.
- Claims: `exp`, `nbf`, `iat`, `iss`, `aud`, `sub`, `jti`; configurable clock
  skew and required claims. Reject duplicate claim keys.
- Bounded token size, header size, claim count, and string length. Claims may
  borrow the token buffer for the request lifetime; a `.keep()` or caller
  buffer is required for deferred use.
- Optional `Jwks` service: bounded key cache, `kid` lookup, refresh on unknown
  key with a rate limit, TTL, no unbounded growth, TLS verification, and SSRF
  controls on the JWKS URL.
- Constant-time signature and MAC comparison; zeroize secrets after use; never
  log a token or key.
- Tests: RFC 7515/7518 vectors, alg confusion, `none`, expired, not-yet-valid,
  audience/issuer mismatch, malformed base64, oversized token, duplicate
  claims, key rotation, JWKS refresh, and missing key.
- Paths: `src/jwt/jwt.zig`, `src/jwt/jwks.zig`, `src/jwt/claims.zig`,
  `docs/jwt.md`.

### Task M-5: Session/JWT integration and examples

- `app.sessions(config)` registers the session middleware and exposes a typed
  session handle through the explicit request context.
- `uz.jwt.verify(T, token, options)` returns a typed claims view or a stable
  error. No hidden global key state.
- Add a login/logout example, a protected route, a bearer-token route, and a
  JWKS-backed route.
- Document the difference between a session cookie, a signed cookie, and a JWT;
  do not present one as a substitute for another.
- Add the module to the v3 security boundary register before claiming
  production readiness.

---

## 14. Version 2.8.0: `uz.metrics`, `uz.trace`, and Diagnostics

**Objective:** enterprise observability with no request-path allocation and no
blocking export on a worker loop.

**Current state:** `src/observability/metrics.zig` already provides a
fixed-capacity counter registry and allocation-free Prometheus rendering;
`App.log_metrics`, the hidden `/metrics` route, and eBPF latency histogram
reading exist. Extend that module; do not create a second counter registry.

### Task O-1: Per-worker metric collector (`src/observability/metrics.zig`)

- Keep counters; add gauges, bounded histograms, and monotonic timestamps.
- All state is per worker. A scrape aggregates snapshots; no global lock on the
  request path.
- Metric names and label sets are compile-time or bounded; no unbounded
  cardinality from request data.
- Counter overflow saturates rather than wraps.

### Task O-2: Zero-allocation Prometheus/OpenMetrics exposition (`/metrics`)

- Aggregate per-worker counters and stream the standard text format into the
  response buffer with no heap allocation.
- Include HTTP requests by status class, active connections, bytes, latency
  histograms, slab saturation, write-queue depth, WebSocket messages, HTTP/2
  streams, QUIC/HTTP3 counters, SQL pool metrics, S3/JWKS calls, job counts,
  cache hits/misses/evictions, and trace export drops.
- Validate the output against a parser in CI; reject NaN/Inf where the format
  does not allow it.
- Keep the route hidden by default and documented.

### Task O-3: Structured JSON access logging (`src/observability/logging.zig`)

- Emit `timestamp`, `client_ip`, `method`, `path`, `status`, `bytes_sent`,
  `latency_us`, `trace_id`, and `span_id` through an asynchronous bounded ring
  so disk I/O never blocks a worker loop.
- Redact `Authorization`, `Cookie`, `Set-Cookie`, query strings by default, and
  configured secret fields.
- Bound the line size and the ring depth; drop with a counter, never block.
- Provide a human-readable development sink and a JSON production sink.

### Task O-4: Slab saturation diagnostics

- Expose active slot count, slab saturation percentage, and ring occupancy.
- Warn above 85 percent saturation.
- Include module pools (SQL, S3, jobs) in the diagnostics when enabled.

### Task O-5: `uz.trace` core (`src/observability/trace.zig` or `src/trace/`)

- W3C Trace Context: parse and emit `traceparent` and `tracestate` with strict
  length and character validation.
- Generate trace IDs (16 bytes) and span IDs (8 bytes) from an injected
  entropy source; never use a predictable counter alone.
- Span lifecycle: start, attributes, events, status, end. Bounded attribute
  count and value size; no allocation on the request path.
- Sampling: parent-based plus a configured ratio; record the decision in the
  trace flags. A sampled-out span still propagates context.
- Per-worker span buffer/queue; drop policy with a counter when full.

### Task O-6: Request and module spans

- One server span per request with method, route, status, bytes, and latency.
- Child spans for SQL queries (statement name, not raw parameter values), S3
  operations, job execution, cache operations (optional), and outbound client
  calls.
- Continue an inbound trace from `traceparent`; inject it into outbound
  requests through the client.
- Never record credentials, tokens, cookies, or raw query parameters by
  default.

### Task O-7: OTLP/HTTP exporter

- Encode OTLP protobuf with `uz.proto`; send over the existing client with TLS
  verification and an explicit endpoint.
- Bounded batch size, queue depth, retry/backoff, and flush interval.
- Flush on shutdown with a deadline; report drops.
- Provide a development stdout/log exporter and a no-op exporter that the
  linker can remove.
- Golden tests decode the emitted OTLP payload and compare IDs, attributes,
  status, and resource fields.

### Task O-8: Metrics/tracing integration and assurance

- Add a metrics/tracing example and docs: `docs/metrics.md`, `docs/tracing.md`.
- Test a full request -> SQL -> S3 -> job chain with trace propagation.
- Run the exporter against a local OTLP receiver or a golden-response mock.
- Fuzz `traceparent`, span attribute encoding, and OTLP decoding.
- Verify no request-path allocation and no blocking export.
- Add module metrics to the Prometheus registry without unbounded labels.

---

## 15. Version 2.9.0: High Availability, Hot Reload, and Multi-OS Stability

**Objective:** zero-downtime restarts and robust cross-platform execution.

### Task A-1: Windows accept lifecycle (carry-over from v1.9.0 M4)

**Note:** the canonical plan moved to v1.9.0 M4. Keep this item only if M4 is
re-declared open. Do not implement two different accept fixes.

- Resolve `AcceptEx` completion context recycling so accepted sockets bind to
  the worker IOCP port without handle leaks.
- Run the full unit and integration suites natively on `windows-latest`.

### Task A-2: Windows queued-completion cancellation on close (carry-over from v1.9.0 M4)

**Note:** the canonical plan moved to v1.9.0 M4-2.

- Cancel and drain pending `WSARecv`/`WSASend` with `CancelIoEx`, and release
  every slot whose callback will never fire, before closing the socket.

### Task A-3: Graceful drain state machine (`src/core/drain.zig`)

- On `SIGINT`/`SIGTERM`:
  1. Close listener sockets so the kernel stops routing new connections.
  2. Emit `Connection: close` on active HTTP/1.1 connections.
  3. Emit HTTP/2 `GOAWAY` with the last processed stream ID.
  4. Emit WebSocket close frames with code 1001 and await handshakes.
  5. Enforce a configurable drain grace period (for example 5 s) before
     abortive termination.

### Task A-4: `SO_REUSEPORT` and `systemd` socket activation takeover

- Support Linux socket takeover and `LISTEN_FDS` so a new binary binds before
  the old instance drains.
- Verify zero dropped connections during rolling deployment.

---

## 16. Version 3.0.0 to 3.9.0: Security Boundary Closure Program

**Objective:** close every security boundary declared in `SECURITY.md` by
fixing it, hardening it with evidence, or explicitly accepting it through an
ADR with a review trigger. The program is complete when no boundary is
unclassified, unowned, or unsupported by evidence.

**Scope:** the live HTTP/1.1, HTTP/2, WebSocket, TLS, and HTTP/3 surfaces; the
outbound client; transport and event-loop lifecycle; router and async-token
ownership; the C ABI; platform support claims; supply-chain provenance; and
the disclosure process.

**Status (2026-11-07):** planning. The v3.x track starts after the v2.9.0
work, after the module releases that the maintainer chooses to land first, or
after the relevant v2.1 and v2.9 carry-overs are closed. It does not assume that
an earlier release gate passed; v3.0.0 audits the inherited state first. The
module track in section 17 is not exempt: every shipped module joins the
register through SB-55 through SB-64 before it is called production-ready.

**Binding sources:** `SECURITY.md` defines the boundary. `docs/roadmap.md`
records current status. `docs/adr/` records accepted decisions. `AGENTS.md`,
`CODING_CONVENTION.md`, `CONTRIBUTE.md`, and `CI_CD_PIPELINE.md` remain
binding over this plan.

### 16.1 Operating rules for humans and agents

#### Boundary statuses

| Status | Meaning | Closure evidence |
| :--- | :--- | :--- |
| **Open** | Known defect or missing required protection | Failing test or reproduced attack path |
| **Fix** | Remove the defect or add the missing protection | Regression test fails before and passes after |
| **Harden** | Reduce impact, raise a bounded limit, or add defense in depth | Limit proof, fuzz case, benchmark, or differential test |
| **Accept** | Deliberate security or product boundary | ADR with rationale, owner, and review date |
| **Defer** | Not in the current release | Owner, target, and dated restoration criterion |
| **Closed** | Fix or Harden evidence merged and release-gated | Linked test, CI job, and release checklist item |

No boundary may be marked Closed because a sentence was removed from
`SECURITY.md`. Removing a protection is a new boundary and needs an ADR.

#### Human workflow

1. Pick one release section and one boundary ID. Do not mix two releases in one
   pull request.
2. Write the threat and the observable contract first: entry point, attacker
   capability, preconditions, failure mode, maximum work, error behavior, and
   the test that proves closure.
3. Add the implementation and the regression test in the same change. Update
   `SECURITY.md`, `docs/roadmap.md`, the boundary register, the relevant ADR,
   and `CHANGELOG.md` before requesting review.
4. Run the gates in section 16.3 and archive raw results under the release
   evidence directory.
5. Open the pull request with an assignee and at least one repository label.
   Keep it open until the reviewer and integrator have both signed off.

#### Agent workflow

| Phase | Agent | Required output |
| :--- | :--- | :--- |
| Architect | `architect` | Boundary IDs, threat model, affected files, acceptance tests, ADR need, release target |
| Implementer | `developer` plus `transport_io`, `http_protocol`, `ws_protocol`, `quic_h3`, `crypto_tls`, `ffi_edge`, `dx_router`, or `build_vendor` | Diff, tests, docs, commands and raw outcomes, open questions |
| Reviewer | `reviewer` | Independent correctness, security, compatibility, convention, and evidence review |
| Integrator | `integrator` | Combined diff, boundary-register diff, required gates, release note, delivery summary |

Agents must not claim an unrun check passed, must not weaken a gate to close a
boundary, and must not open a release tag. Every opened or updated pull request
must be assigned and labeled.

#### Pull-request rules

- One boundary group per pull request, one logical change per commit.
- Security-sensitive paths require an independent reviewer and a second
  reviewer from the owning domain when the change touches completion ordering,
  TLS, parser state, or the C ABI.
- The pull request body must name the boundary IDs, the threat, the new test,
  the commands run, and the accepted/deferred decisions.
- Do not include generated benchmark output edited by hand.
- Do not mark an accepted boundary without an ADR and a review trigger.

### 16.2 Boundary register and release map

The register is the v3.x source of truth. `Class` is the intended closure
method; `Target` is the first release allowed to mark the boundary Closed.
Owners use the repository specialist names.

| ID | Boundary | Class | Target | Owner | Required proof |
| :--- | :--- | :--- | :---: | :--- | :--- |
| SB-01 | Every `SECURITY.md` claim has an ID, owner, status, and review trigger | Fix | v3.0.0 | verification | Register check passes; no unclassified claim |
| SB-02 | Threat model for network, TLS, HTTP, WebSocket, QUIC, router, C ABI, and admin boundaries | Fix | v3.0.0 | architect, reviewer | Threat model reviewed and linked from `SECURITY.md` |
| SB-03 | Evidence contract, release gate, and boundary-register CI check | Fix | v3.0.0 | verification, build_vendor | Lint and release gates reject missing evidence |
| SB-04 | Supply-chain baseline: pins, licenses, SBOM, fork provenance, archive | Harden | v3.0.0 | build_vendor | Inventory, hashes, licenses, and archive recorded |
| SB-05 | Private disclosure and CVE response baseline | Harden | v3.0.0 | maintainer, verification | Advisory template, triage, embargo, and credit process |
| SB-06 | Completion lifecycle: cancel, drain, close, stale callbacks, slot reuse | Fix | v3.1.0 | transport_io | Backend matrix and soak tests pass |
| SB-07 | Windows IOCP accept ownership and queued close | Fix | v3.1.0 | transport_io, build_vendor | Native `windows-2025` regression and runtime suite |
| SB-08 | UDP receive ancillary data and GRO segment boundaries | Fix | v3.1.0 | transport_io, quic_h3 | Segmented receive test and HTTP/3 gate |
| SB-09 | Signals, async wakeups, and one process-wide watcher | Fix | v3.1.0 | transport_io, dx_router | Double-install and shutdown-race tests |
| SB-10 | Runtime sanitizer coverage and MSan boundary | Harden | v3.1.0 | verification | ASan, UBSan, LSan, MSan smoke, documented scope |
| SB-11 | Backend selection, stickiness, fallback, and introspection policy | Accept | v3.1.0 | transport_io | ADR and fallback tests |
| SB-12 | HTTP/1.1 framing, request smuggling, header and body limits | Fix | v3.2.0 | http_protocol | Smuggling matrix and h1spec pass |
| SB-13 | HTTP/1.1 keep-alive, pipelining, reuse, and slow-client limits | Fix | v3.2.0 | http_protocol | Pipelining, timeout, and half-close tests |
| SB-14 | HTTP/2 frames, HPACK, flow control, stream caps, and SETTINGS | Fix | v3.2.0 | http_protocol | Centralized malformed-frame and flow-control suite |
| SB-15 | HTTP/2 RFC 8441 tunnel and per-connection tunnel cap | Harden | v3.2.0 | http_protocol, ws_protocol | Extended CONNECT and tunnel-exhaustion tests |
| SB-16 | HTTP/1.1 and HTTP/2 differential, fuzz, and compliance coverage | Harden | v3.2.0 | verification | h1spec, HTTP/2 suite, and fuzz corpus |
| SB-17 | WebSocket handshake, subprotocol, origin, and extension validation | Fix | v3.3.0 | ws_protocol | Handshake rejection matrix |
| SB-18 | WebSocket framing, UTF-8, fragmentation, control frames, and close codes | Fix | v3.3.0 | ws_protocol | Autobahn and malformed-frame tests |
| SB-19 | RFC 7692 negotiation, window bits, and decompression bounds | Fix | v3.3.0 | ws_protocol | Compression abuse and zip-bomb tests |
| SB-20 | WebSocket backpressure, pub/sub fan-out, and slow-consumer policy | Fix | v3.3.0 | ws_protocol, dx_router | Saturation, reentrancy, and drop-policy tests |
| SB-21 | WebSocket fuzz, Autobahn, and regression corpus | Harden | v3.3.0 | verification, ws_protocol | 517/517 Autobahn and fuzz clean |
| SB-22 | QUIC and HTTP/3 frame, stream, header, body, and connection bounds | Fix | v3.4.0 | quic_h3 | Bounded-state and malformed-input suite |
| SB-23 | QPACK dynamic table, blocked streams, and decoded-header bound | Fix | v3.4.0 | quic_h3 | QPACK amplification and table tests |
| SB-24 | HTTP/3 datagrams, GSO, GRO, and packet boundaries | Fix | v3.4.0 | quic_h3, transport_io | Segmented datagram and interop tests |
| SB-25 | WebTransport, extended CONNECT, and capability gate | Fix | v3.4.0 | quic_h3, ffi_edge | Live implementation or accepted ADR with trigger |
| SB-26 | RFC 10008 QUERY and body/content-type gate | Fix | v3.4.0 | http_protocol, quic_h3 | H1, H2, and H3 QUERY tests |
| SB-27 | HTTP/3 interop, qlog, and fuzz coverage | Harden | v3.4.0 | verification, quic_h3 | curl/ngtcp2 and aioquic gate |
| SB-28 | TLS 1.3-only policy, certificate verification, trust store, SNI, hostname and IP | Harden | v3.5.0 | crypto_tls | Verification and failure-mapping matrix |
| SB-29 | mTLS modes and fail-closed client-chain verification | Fix | v3.5.0 | crypto_tls | None, optional, and required mode tests |
| SB-30 | 0-RTT replay policy, credential rotation, and session resumption | Accept | v3.5.0 | crypto_tls | ADR, replay tests, and rotation procedure |
| SB-31 | kTLS key handoff and integration boundary | Defer | v3.5.0 | crypto_tls, transport_io | Standalone helper or ADR with BoringSSL trigger |
| SB-32 | Authentication, rate limiting, and secret handling | Fix | v3.5.0 | crypto_tls, dx_router | Constant-time, duplicate-field, and zeroization tests |
| SB-33 | Router captures, patterns, middleware caps, and immutable registration | Fix | v3.6.0 | dx_router | Capacity and overflow tests |
| SB-34 | Async response tokens: generation, loop confinement, exactly-once | Fix | v3.6.0 | dx_router | Stale, double, cross-thread, and disconnect tests |
| SB-35 | Borrowed slices, request lifetime, and stable application address | Fix | v3.6.0 | dx_router, ffi_edge | Lifetime misuse tests |
| SB-36 | C ABI handles, errors, layouts, slice ownership, and callback rules | Fix | v3.6.0 | ffi_edge | C/C++ consumer and layout assertions |
| SB-37 | Fixed slabs, no dynamic overflow, and exhaustion behavior | Accept | v3.6.0 | dx_router, transport_io | Capacity accounting and rejection tests |
| SB-38 | Ownership assurance: ASan, LSan, fuzz, and misuse corpus | Harden | v3.6.0 | verification | Sanitizer and fuzz suite |
| SB-39 | Client TLS verification, trust store, SNI, hostname, and IP | Fix | v3.7.0 | crypto_tls, transport_io | Loopback and mismatch tests |
| SB-40 | Client redirect, cookie, proxy, retry, mTLS, and protocol policy | Accept | v3.7.0 | transport_io, dx_router | Bounded implementation or ADR per feature |
| SB-41 | Client HTTP/1.1 response parsing and smuggling resistance | Fix | v3.7.0 | http_protocol, transport_io | Malformed-server and framing tests |
| SB-42 | Client connection reuse, pool isolation, and stale-connection policy | Fix | v3.7.0 | transport_io | Origin and trust-rule isolation tests |
| SB-43 | Client fuzz, loopback, and malformed-server assurance | Harden | v3.7.0 | verification | Fuzz and loopback suite |
| SB-44 | Platform support matrix: Linux, macOS, Windows, BSD, affinity | Harden | v3.8.0 | build_vendor, verification | CI matrix and published support claims agree |
| SB-45 | Deployment capacities, idle timeouts, file descriptors, and OS limits | Accept | v3.8.0 | dx_router, transport_io | Capacity contract and refusal tests |
| SB-46 | Graceful shutdown, drain, signal ownership, and socket takeover | Fix | v3.8.0 | transport_io, dx_router | Drain, GOAWAY, close-code, and takeover tests |
| SB-47 | SBOM, licenses, dependency provenance, reproducibility, and fork archive | Harden | v3.8.0 | build_vendor | SBOM, license audit, reproducible build, archive |
| SB-48 | Release provenance, source-only artifacts, and tag discipline | Fix | v3.8.0 | build_vendor, integrator | Release checklist and package-consumer evidence |
| SB-49 | Consumer security documentation and deployment guidance | Harden | v3.8.0 | documentation, dx_router | Security guide linked from `SECURITY.md` and README |
| SB-50 | Full fuzz, sanitizer, compliance, and soak assurance campaign | Harden | v3.9.0 | verification | Sustained campaign with zero unresolved findings |
| SB-51 | External security audit or independent penetration test | Harden | v3.9.0 | maintainer, reviewer | Findings triaged and retested |
| SB-52 | CVE, advisory, and private-disclosure drill | Harden | v3.9.0 | maintainer, verification | Drill report and corrected process |
| SB-53 | Final boundary register closure and v3.9.0 security release | Fix | v3.9.0 | integrator | Zero Open, no Defer without trigger |
| SB-54 | Post-release monitoring, review, and next-boundary intake | Accept | v3.9.0 | maintainer, verification | Dated review and intake procedure |
| SB-55 | `uz.sql`: parameter binding, TLS, pool exhaustion, secret redaction | Fix | v3.5.0 | crypto_tls, dx_router | Injection and pool-exhaustion suites pass |
| SB-56 | `uz.s3`: SigV4 canonicalization, SSRF, redirects, credential redaction | Fix | v3.7.0 | crypto_tls, http_protocol | Golden vectors and mock-S3 security suite |
| SB-57 | `uz.jobs`: lease, at-least-once semantics, payload bounds, shutdown | Fix | v3.6.0 | dx_router, verification | Claim/retry/lease/duplicate-delivery tests |
| SB-58 | `uz.memory_cache`: secrecy, TTL, eviction, capacity, per-worker isolation | Fix | v3.6.0 | dx_router, verification | No-allocation and secret-lifetime tests |
| SB-59 | `uz.sessions`: AEAD, key rotation, fixation, replay, CSRF | Fix | v3.5.0 | crypto_tls, dx_router | Tamper/replay/rotation matrix |
| SB-60 | `uz.jwt`: algorithm confusion, JWKS trust, claim validation, key zeroization | Fix | v3.5.0 | crypto_tls, verification | Vectors and algorithm-confusion suite |
| SB-61 | `uz.proto`: recursion, length, unknown-field, and allocation bounds | Fix | v3.2.0 | http_protocol, verification | Canonical vectors and fuzz corpus |
| SB-62 | `uz.metrics`: cardinality, label injection, secret leakage | Fix | v3.8.0 | verification, dx_router | Label and redaction tests |
| SB-63 | `uz.trace`: redaction, sampling, export blocking, queue bounds | Fix | v3.8.0 | verification, transport_io | Golden OTLP and shutdown-flush tests |
| SB-64 | `uz.mcp`: tool authorization, session, argument/result redaction, SSRF | Fix | v3.8.0 | dx_router, crypto_tls, verification | MCP auth/redaction/conformance suite |

### 16.3 Release gates and evidence contract

Every v3.x release runs the standard repository gates plus the security gates
that match its boundary group.

```sh
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
sh scripts/check_docs.sh
sh scripts/check_security_boundaries.sh
zig build test
zig build test -Dsanitize=true -Doptimize=ReleaseSafe
zig build test-compile -Doptimize=ReleaseSafe
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build oss-fuzz-smoke -Doptimize=ReleaseSafe
```

Additional gates by touch point:

| Touch point | Required gate |
| :--- | :--- |
| Event loop or transport | Backend matrix, cancellation storms, drain, native Windows job |
| HTTP/1.1 | h1spec, smuggling corpus, pipelining and slow-client tests |
| HTTP/2 | Centralized malformed-frame, HPACK, flow-control, and stream-state tests |
| WebSocket | Autobahn with no exclusions, UTF-8 and compression fuzz |
| HTTP/3 | Pinned curl/ngtcp2 and aioquic cross-implementation gate, qlog review |
| TLS | Certificate mismatch, mTLS, 0-RTT replay, rotation, and zeroization tests |
| C ABI | Static layout checks, C and C++ consumers, malformed and capacity cases |
| Client | Loopback, malformed-server, trust-rule isolation, and redirect/proxy policy |
| Module (SQL/S3/jobs/cache/JWT/sessions/proto/metrics/trace) | Golden vectors, mock/live integration, feature-gate link check, allocation, and secret redaction |
| Supply chain | Four zon views, fork reachability, SBOM, licenses, archive |
| Release | Package consumer, source-only tag, published support matrix |

Each release stores its evidence in a dated directory under
`docs/security/evidence/<version>/` or an equivalent committed manifest that
links to the raw artifacts. The manifest records the commit, Zig version,
dependency pins, boundary IDs, commands, outcomes, and reviewer names.

### 16.4 v3.0.0: Boundary Register, Threat Model, and Security Baseline

**Objective:** make every security claim traceable before changing protocol
behavior. This is the gate for the rest of the program.

**Boundaries:** SB-01 through SB-05.

**Non-goals:** no new protocol feature, no dependency migration beyond
recording the current state, no support-claim change.

#### Task V3.0-1: Create the boundary register

- Add `docs/security_boundaries.md` with the columns from section 16.2.
- Add one row for every claim in `SECURITY.md`, including support and
  disclosure claims, not only the "Security boundaries" section.
- Link the register from `SECURITY.md`, `README.md`, `AGENTS.md`,
  `CONTRIBUTE.md`, and `CI_CD_PIPELINE.md`.
- Record current status honestly: Closed, Open, Accept, or Defer. Do not mark
  an inherited v2.x claim Closed without a test or ADR.

#### Task V3.0-2: Threat model each trust boundary

- Draw the data flow for network ingress, TLS termination, HTTP parsing,
  WebSocket upgrade and framing, QUIC and HTTP/3, router dispatch, async
  completion, C ABI entry, and shutdown.
- For each boundary list assets, attacker capability, entry point, trust
  transition, maximum work, failure mode, and detection.
- Map each boundary to the RFC or specification clause that defines the safe
  behavior.
- Review with `crypto_tls`, `http_protocol`, `ws_protocol`, `quic_h3`,
  `ffi_edge`, `transport_io`, and `verification`.

#### Task V3.0-3: Add the evidence and release gate

- Add `scripts/check_security_boundaries.sh` to verify that every `SB-*` row
  has an owner, class, target, and non-empty proof, and that no Open or Defer
  row lacks a target or restoration trigger.
- Wire the check into `lint.yml` and the release checklist.
- Make the check fail on an unknown or duplicate boundary ID.
- Do not add a passing allowlist for incomplete rows.

#### Task V3.0-4: Record the supply-chain baseline

- Inventory every dependency, license, pin, hash, and build input.
- Record the libxev fork state, upstream base, patch ledger, and current
  overlay status.
- Produce an SBOM and a reproducible-build manifest.
- Archive the current dependency sources or hashes needed for an offline audit.

#### Task V3.0-5: Establish the disclosure and CVE baseline

- Define private report intake, acknowledgement, triage, severity, embargo,
  fix, advisory, credit, and backport rules.
- Add an advisory template and a release-note security section template.
- Record who may request a CVE, who approves disclosure, and how consumers are
  notified.
- Run a tabletop exercise and record the gaps.

#### Task V3.0-6: Audit inherited closures

- Re-run the v2.1 libxev fork closure, Windows IOCP tests, UDP GRO tests, and
  v2.9 drain/takeover tests. Mark each SB row with the actual evidence.
- Any inherited claim without evidence becomes Open, not Closed.
- Record accepted v2.x boundaries and their ADRs.

**Evidence:** register complete, threat model reviewed, boundary check in CI,
SBOM and supply-chain manifest archived, disclosure tabletop report.

**Exit criteria:** every `SECURITY.md` claim has an SB ID and an owner; no
unclassified boundary remains; the release gate fails on an incomplete row.

### 16.5 v3.1.0: Event Loop, Completion, and Windows Boundary Closure

**Objective:** make the runtime's cancellation, completion, and platform
behavior provably safe on every supported backend.

**Boundaries:** SB-06 through SB-11.

**Dependencies:** v3.0.0 register and evidence gate. The libxev fork migration
from v2.1-C3 may already be complete; audit it instead of assuming it.

#### Task V3.1-1: Verify the libxev fork pin and patch ledger

- Confirm `build.zig.zon` resolves a full 40-hex commit on `uwz/zig-0.16`.
- Confirm all four zon views agree on URL, revision, Zig hash, and Nix hash.
- Confirm XEV-001 and every other downstream patch has a ledger row, upstream
  reference, invariant, failing-without test, passing-with test, and retirement
  criterion.
- Confirm the fork mirror equals `upstream/main` and the pinned commit is
  reachable from the integration branch and the archive.
- Record the evidence in the release manifest.

#### Task V3.1-2: Prove completion lifecycle ordering

- Exercise submit, cancel, close, read, write, accept, connect, timer, async,
  and file operations on io_uring, epoll, kqueue, and IOCP.
- Test cancellation before submission, cancellation during submission, close
  in a callback, stale completion after slot reuse, and repeated shutdown.
- Assert exactly-once callback delivery and slot release.
- Add a deterministic test hook for queued-versus-submitted state; do not rely
  on timing alone.
- Run a cancellation storm and a 24-hour connect/close soak.

#### Task V3.1-3: Close Windows IOCP accept and queued-close behavior

- Verify `AcceptEx` clears the internal accept socket on success and error.
- Verify a re-arm allocates a fresh accept socket.
- Verify queued reads and writes are submitted before cancel or have their
  flags cleared when the callback cannot fire.
- Run the native runtime suite and the dedicated re-arm regression on
  `windows-2025`.
- Record whether Windows is promoted; if not, leave the support claim
  compile-only and state the exact failing gate.

#### Task V3.1-4: Close UDP receive ancillary data and GRO

- Extend the UDP completion to carry a control buffer and parse segment sizes,
  or move receive to a raw `recvmsg` path while retaining the loop ownership
  contract.
- Feed each segment to lsquic separately; never pass a coalesced buffer as one
  datagram.
- Test mixed sizes, same destination, different destinations, truncation, and
  ancillary-data absence.
- Run the HTTP/3 cross-implementation gate with receive GRO enabled.

#### Task V3.1-5: Prove signals, async wakeups, and watcher ownership

- Reject a second process-wide signal watcher.
- Test signal delivery during accept, TLS handshake, HTTP/2 stream, WebSocket
  frame, QUIC packet, and shutdown drain.
- Ensure the async wake path cannot lose a wakeup or run a callback after the
  loop is deinitialized.
- Run the shutdown race tests repeatedly under sanitizers.

#### Task V3.1-6: Define the sanitizer and MSan boundary

- Run ASan, UBSan, and LSan over the runtime and C/C++ dependencies.
- Keep MemorySanitizer scoped to the dependency-boundary smoke until Zig can
  instrument Zig code; state the limitation in `SECURITY.md`.
- Add unsupported-feature skips with explicit reasons, never silent skips.
- Re-run the full event-loop matrix with instrumentation enabled.

#### Task V3.1-7: Record backend selection policy

- Write or update the ADR for process-sticky backend selection, io_uring to
  epoll fallback, retry bounds, and `error.BackendChanged`.
- Decide whether backend introspection is a public API; default to internal.
- Test fallback under seccomp, low memlock, unsupported kernel, and repeated
  loop creation.

**Evidence:** backend matrix, cancellation and close tests, native Windows
job, UDP GRO HTTP/3 run, 24-hour soak, sanitizer results, backend ADR.

**Exit criteria:** no event-loop boundary is Open; every callback has a proven
owner; Windows support claim matches the native job.

### 16.6 v3.2.0: HTTP/1.1 and HTTP/2 Trust Boundary Closure

**Objective:** make request framing, header handling, connection reuse, and
HTTP/2 state machine behavior resistant to smuggling, desynchronization, and
resource exhaustion.

**Boundaries:** SB-12 through SB-16.

**Dependencies:** v3.1.0 for completion ordering and drain behavior.

#### Task V3.2-1: Build the HTTP/1.1 smuggling matrix

- Test duplicate `Content-Length`, `Transfer-Encoding` plus `Content-Length`,
  chunked extensions, trailers, folded headers, whitespace variants, invalid
  tokens, absolute-form targets, authority-form `CONNECT`, and `OPTIONS *`.
- Reject ambiguous framing before dispatch; never normalize silently.
- Prove the parser consumes exactly one request per message boundary.
- Test request-line and header-block dribbling with the monotonic scan cursor.
- Bound header count, header bytes, request line, body size, and trailer size.
- Record each rejection with a stable reason code.

#### Task V3.2-2: Prove keep-alive, pipelining, and slow-client behavior

- Test ordered response emission for multiple pipelined requests.
- Test `Connection: close`, half-close, RST, idle timeout, header timeout, and
  response-write backpressure.
- Test a slow reader, a slow writer, and a client that never completes headers.
- Ensure no connection slot leaks on parse failure or write failure.
- Test HTTP/1.1 upgrade and `100-continue` paths without smuggling.

#### Task V3.2-3: Audit HTTP/2 framing and state

- Test the client preface, SETTINGS, ACK, PING, WINDOW_UPDATE, RST_STREAM,
  GOAWAY, PRIORITY, CONTINUATION, DATA, HEADERS, and trailers.
- Test invalid stream states, flow-control overrun, zero window, stream ID
  reuse, frame size, padding, and interleaved frames.
- Enforce the 8-stream default cap and a bounded tunnel cap.
- Test HPACK dynamic table size, Huffman decoding, header-list size,
  pseudo-header order, duplicate pseudo-headers, and connection-specific
  headers.
- Keep server push and h2c Upgrade as documented non-goals unless a new ADR
  changes them.

#### Task V3.2-4: Close RFC 8441 WebSocket tunnel behavior

- Test extended CONNECT, `:protocol = websocket`, one tunnel per connection,
  stream exhaustion, flow control, reset, and close ordering.
- Reject a second tunnel and malformed pseudo-headers.
- Verify the tunnel cannot bypass HTTP/2 header or stream limits.

#### Task V3.2-5: Add differential and fuzz coverage

- Expand the centralized malformed corpus with the smuggling and HTTP/2 cases.
- Run h1spec and the HTTP/2 malformed-frame suite.
- Add deterministic Smith seeds and an `LLVMFuzzerTestOneInput` corpus for
  request framing, chunked encoding, and HPACK.
- Run ASan, UBSan, and LSan over the parser paths.

**Evidence:** h1spec report, HTTP/2 suite, smuggling matrix, fuzz corpus,
sanitizer run, per-rejection reason-code table.

**Exit criteria:** no ambiguous framing accepted; h1spec and HTTP/2 gates pass
without exclusions; every peer-controlled length has a cap.

### 16.7 v3.3.0: WebSocket and Compression Boundary Closure

**Objective:** close WebSocket handshake, framing, UTF-8, close, compression,
and pub/sub backpressure boundaries.

**Boundaries:** SB-17 through SB-21.

**Dependencies:** v3.2.0 for HTTP upgrade and RFC 8441 tunnel behavior.

#### Task V3.3-1: Validate the WebSocket handshake

- Require GET, HTTP/1.1, valid `Host`, `Upgrade: websocket`, `Connection`
  token, base64 16-byte `Sec-WebSocket-Key`, and version 13.
- Validate subprotocol and extension offers against a bounded allowlist.
- Apply an explicit origin policy; do not reflect arbitrary origins by default.
- Reject duplicate or smuggled handshake headers and incomplete upgrade state.

#### Task V3.3-2: Close framing and UTF-8 boundaries

- Test FIN, RSV bits, opcodes, mask requirements, payload length encodings,
  control-frame size, control-frame fragmentation, and reserved close codes.
- Stream UTF-8 validation across fragmented messages without buffering the
  whole message.
- Bound message size, fragment count, control-frame rate, and per-connection
  output.
- Test close-code validation, close handshake timeout, half-close, and RST.

#### Task V3.3-3: Bound RFC 7692 compression

- Test negotiation, `server_no_context_takeover`,
  `client_no_context_takeover`, window bits, and invalid extension parameters.
- Decline 8-bit server windows; accept 8-bit client streams only with the
  documented decompression bound.
- Test zip bombs, repeated context takeover, decompression expansion, and
  truncated compressed payloads.
- Keep separate caller-owned scratch buffers for compressed input and output.

#### Task V3.3-4: Prove backpressure and pub/sub isolation

- Test slow consumers, full write queues, pause/resume, disconnect during
  fan-out, reentrant unsubscribe, and repeated subscribe/unsubscribe.
- Enforce topic, subscriber, message, and publish-depth caps.
- Keep tombstones and publish-depth frames until the outermost fan-out returns.
- Ensure a failed subscriber cannot shift or remap another topic.

#### Task V3.3-5: Prove HTTP/2 tunnel interaction

- Verify one WebSocket tunnel per HTTP/2 connection and bounded stream state.
- Test tunnel close, RST_STREAM, GOAWAY, flow-control exhaustion, and
  connection teardown while a WebSocket frame is in flight.

#### Task V3.3-6: Run Autobahn and WebSocket fuzz

- Run Autobahn 517/517 with no exclusions.
- Add malformed handshake, frame, UTF-8, close, and compression seeds.
- Run the WebSocket fuzz target under ASan, UBSan, and LSan.

**Evidence:** Autobahn report, handshake/framing matrix, compression abuse
results, pub/sub saturation tests, fuzz corpus.

**Exit criteria:** Autobahn clean, no decompression amplification, no
subscriber-induced cross-topic delivery, no unbounded WS output.

### 16.8 v3.4.0: QUIC and HTTP/3 Boundary Closure

**Objective:** close QUIC, QPACK, HTTP/3 framing, datagram, QUERY, and
WebTransport boundaries.

**Boundaries:** SB-22 through SB-27.

**Dependencies:** v3.1.0 for UDP GRO and completion ordering; v3.2.0 for shared
HTTP semantics.

#### Task V3.4-1: Bound QUIC and HTTP/3 connection state

- Test connection, stream, header, body, packet-buffer, and active-request
  caps.
- Test malformed frame types, invalid stream IDs, control-stream errors,
  GOAWAY, reset, and connection close.
- Test flow-control exhaustion, blocked streams, and partial DATA.
- Ensure a stream-scoped error does not abort a healthy sibling request.
- Record every rejection reason and its wire behavior.

#### Task V3.4-2: Bound QPACK

- Keep the dynamic table disabled or bounded by an explicit policy.
- Test decoded header-set size, blocked streams, table updates, Huffman
  decoding, duplicate pseudo-headers, and header-list overflow.
- Reject an over-limit header section with a stream-scoped error, not a
  connection-wide abort.
- Add a QPACK amplification regression based on the published attack class.

#### Task V3.4-3: Prove datagrams and packet boundaries

- Test GSO transmit batches and GRO receive segments with mixed sizes.
- Test truncated datagrams, missing ancillary data, and coalesced buffers.
- Ensure lsquic receives exactly one datagram per packet-in call.
- Run the pinned curl/ngtcp2 and aioquic gates with GSO and GRO enabled.

#### Task V3.4-4: Close the WebTransport decision

- Implement live WebTransport only if the pinned lsquic exposes extended
  CONNECT, server-initiated unidirectional streams, and reset-at.
- Otherwise record an accepted ADR with a restoration trigger and keep the
  helper limited to bounded wire validation.
- If implemented, test session establishment, datagrams, stream reset, close,
  flow control, and capability rejection.
- Do not claim live WebTransport support while the helper is disconnected from
  the listener.

#### Task V3.4-5: Prove RFC 10008 QUERY behavior

- Require a syntactically valid `Content-Type` before routing QUERY.
- Test H1, H2, and H3 QUERY requests, missing content type, invalid content
  type, and body-capacity behavior.
- Keep the same rejection semantics across transports.

#### Task V3.4-6: Add HTTP/3 assurance

- Add malformed frame, QPACK, datagram, and header-set fuzz seeds.
- Run the cross-implementation gate, retain qlogs, and review one successful
  and one failed connection trace.
- Run ASan, UBSan, and LSan over the QUIC paths.

**Evidence:** HTTP/3 interop report, QPACK amplification test, GRO/GSO matrix,
QUERY matrix, WebTransport ADR or live tests, qlog review.

**Exit criteria:** no HTTP/3 peer-controlled length is unbounded; WebTransport
is either live and tested or explicitly accepted; QUERY is consistent on all
three transports.

### 16.9 v3.5.0: TLS, Identity, Authentication, and Secrets

**Objective:** make identity, certificate, early-data, rotation, and secret
handling fail closed and auditable.

**Boundaries:** SB-28 through SB-32.

**Dependencies:** v3.0.0 threat model; v3.2.0 HTTP semantics for auth headers.

#### Task V3.5-1: Freeze and test the TLS policy

- Keep TLS 1.3-only as an accepted security posture unless a new ADR changes
  it. Do not add TLS 1.2 merely to remove a boundary.
- Test certificate-chain verification, caller trust store, SNI, hostname, IP
  SAN, expired certificate, wrong host, self-signed certificate, and missing
  trust store.
- Map every TLS error to a stable public error without leaking key material.
- Ensure `verify = false` is development-only and cannot be enabled silently
  in production configuration.

#### Task V3.5-2: Prove mTLS modes

- Test none, optional, and required client-certificate modes.
- Verify required mode fails closed when the client sends no certificate or an
  untrusted chain.
- Test CA bundle changes, chain order, intermediate certificates, and client
  key mismatch.
- Ensure mTLS policy is per-listener and cannot be weakened by a shared
  application default.

#### Task V3.5-3: Bound 0-RTT and replay

- Restrict 0-RTT to safe methods and a documented replay policy.
- Test early-data size, replay of a captured request, method restrictions, and
  fallback when early data is rejected.
- Document that 0-RTT is not a substitute for application idempotency.
- Add a denial test for unsafe methods.

#### Task V3.5-4: Close rotation and session-resumption decisions

- Keep rolling restart as the supported rotation path unless a hot-reload ADR
  is accepted.
- If hot reload is added, use a generation-checked context swap, drain
  in-flight `SSL` objects, and provide rollback.
- Record the cross-worker session-resumption policy and measured reuse.
- Test ticket-key rotation, expiry, and reconnect across workers.

#### Task V3.5-5: Decide kTLS integration

- Keep kTLS as a standalone helper unless BoringSSL exposes a supported key
  handoff and the connection path can hand keys to the kernel safely.
- If integrated, test key zeroization, fallback, record framing, and teardown.
- Record the accepted boundary and the BoringSSL trigger.

#### Task V3.5-6: Harden auth, rate limiting, and secrets

- Compare Basic and Bearer credentials in constant time.
- Reject duplicate authorization headers and malformed schemes before routing.
- Bound token-bucket tables, keys, rotation state, and eviction work.
- Zero secrets after use; keep them out of logs, error strings, core dumps
  where practical, and dev-log records.
- Test overflow, rotation, eviction, and concurrent access without locks on the
  hot path.

**Evidence:** TLS verification matrix, mTLS matrix, 0-RTT replay results,
rotation procedure, kTLS ADR, constant-time and zeroization tests.

**Exit criteria:** identity paths fail closed; no secret appears in logs or
errors; TLS 1.2, hot reload, kTLS, and resumption are either implemented and
tested or explicitly accepted.

### 16.10 v3.6.0: Ownership, Router, Async Tokens, and C ABI

**Objective:** make every borrowed pointer, async completion, capacity limit,
and C ABI handle provably owned and misuse-resistant.

**Boundaries:** SB-33 through SB-38.

**Dependencies:** v3.1.0 for completion lifetime; v3.2.0 and v3.3.0 for
protocol callbacks.

#### Task V3.6-1: Prove router capacity and immutability

- Test 16 captures per request, 64 patterns, and 32 middleware entries.
- Test overflow, duplicate routes, method-not-allowed, 404, parameter decode,
  and immutable route arrays after `listen`.
- Ensure a route registration failure does not partially publish state.
- Test static-route hash and pattern-only routers separately.

#### Task V3.6-2: Prove async-token ownership

- Test generation checks, exactly-once completion, stale token, double
  completion, disconnect, pipelining, and slot reuse.
- Test cross-thread completion without marshalling and require the documented
  error.
- Test completion after deinit, after timeout, and after transport reuse.
- Ensure every abandoned token has a defined release path.

#### Task V3.6-3: Prove borrowed-slice lifetimes

- Test request fields, route parameters, and WebSocket messages after the
  callback returns.
- Test application address stability after `listen` and `listen_udp`.
- Document that callers must copy async data before the callback returns.
- Add misuse tests for moving or copying an `App` after registration.

#### Task V3.6-4: Close the C ABI contract

- Keep `include/uWebZockets.h` synchronized with implemented exports.
- Add static layout, enum, and error-code assertions.
- Test opaque handle creation, use, destroy, double destroy, and use-after-free
  detection where the ABI can detect it.
- Test borrowed slices, callback reentrancy, null pointers, invalid lengths,
  and capacity exhaustion.
- Compile and run the C and C++ consumer fixtures under ASan and LSan.

#### Task V3.6-5: Re-prove fixed-slab behavior

- Record every capacity, its overflow error, and its accounting formula.
- Test exhaustion for connections, requests, WebSocket messages, write queues,
  async tokens, routes, middleware, and HTTP/3 state.
- Confirm no hot path allocates dynamically.
- Keep the fixed-slab decision accepted unless a new ADR changes it.

#### Task V3.6-6: Add the ownership assurance suite

- Run ASan, UBSan, and LSan over the ownership and C ABI tests.
- Add a misuse corpus that intentionally violates each documented rule.
- Run the package consumer from a clean fetch.

**Evidence:** capacity matrix, async-token suite, lifetime misuse suite, C/C++
consumer runs, allocator evidence, layout assertions.

**Exit criteria:** every borrowed pointer has a stated lifetime; every async
token completes at most once; every C ABI handle has a defined destroy path.

### 16.11 v3.7.0: Outbound Client Boundary Closure

**Objective:** make the HTTP/1.1 client safe against malicious servers,
trust-rule confusion, redirect abuse, proxy misuse, and response smuggling.

**Boundaries:** SB-39 through SB-43.

**Dependencies:** v3.5.0 for TLS policy; v3.2.0 for response framing.

#### Task V3.7-1: Prove client TLS verification

- Default to verification; require a caller-supplied trust store because
  BoringSSL ships none.
- Test SNI, hostname, IP SAN, expired certificate, wrong host, self-signed
  certificate, and missing trust store.
- Refuse to reuse one client across different trust rules.
- Keep `verify = false` development-only and visible in configuration.

#### Task V3.7-2: Decide and bound client features

- Redirects: same-origin default, bounded count, method rewrite rules, no
  credential forwarding across origins.
- Cookies: bounded store, origin scope, expiry, no implicit cross-origin send.
- Proxy: explicit opt-in, CONNECT policy, proxy auth, no credential leak.
- Retries: idempotent methods only, bounded attempts, no replay of unsafe
  bodies.
- mTLS and HTTP/2 or HTTP/3 clients: implement only with an ADR and tests;
  otherwise mark accepted with a trigger.
- Never let a feature silently change the default security posture.

#### Task V3.7-3: Harden the client response parser

- Test status line, header limits, `Content-Length`, `Transfer-Encoding`,
  chunked framing, trailers, `1xx`, close-delimited bodies, and malformed
  responses.
- Reject ambiguous framing and duplicate length headers.
- Bound response headers, body size, redirects, and connection lifetime.
- Test a malicious server that dribbles bytes, closes early, or sends a
  conflicting response.

#### Task V3.7-4: Prove pool and connection-reuse isolation

- Keep the client pool per-loop and fixed-capacity.
- Isolate reuse by origin, TLS policy, proxy, and credentials.
- Test stale keep-alive connections, retry-on-stale, and connection close.
- Decide whether DNS resolution is in scope; numeric addresses only remains
  an accepted boundary until an ADR adds resolution and SSRF controls.

#### Task V3.7-5: Add client assurance

- Run loopback tests for success, timeout, reset, TLS failure, and malformed
  response.
- Add a mock malicious-server suite and fuzz the response parser.
- Run ASan, UBSan, and LSan over the client paths.

**Evidence:** TLS mismatch matrix, redirect/cookie/proxy policy tests,
malformed-server suite, pool-isolation tests, fuzz corpus.

**Exit criteria:** a malicious server cannot desynchronize the client parser,
and no client instance reuses a connection across trust rules.

### 16.12 v3.8.0: Platform, Operations, and Supply Chain

**Objective:** make support claims, deployment limits, shutdown behavior, and
release provenance match what the project can actually verify.

**Boundaries:** SB-44 through SB-49.

**Dependencies:** v3.1.0 runtime, v3.5.0 identity, v3.6.0 C ABI, v3.7.0 client.

#### Task V3.8-1: Publish the verified platform matrix

- Linux and macOS remain supported on x86_64 and aarch64.
- Windows is promoted only after the native ReleaseSafe test, ABI, and static
  library jobs are green on the release commit.
- BSD targets remain compile-only unless hosted runtime CI is added; record the
  decision.
- macOS workers remain unpinned; record the accepted affinity boundary.
- Cross-target compile checks must match the published matrix.

#### Task V3.8-2: Freeze the deployment capacity contract

- Document connection, request, WebSocket, write-queue, HTTP/3, route,
  middleware, and async-token capacities.
- Document idle timeouts, header timeouts, drain grace, file-descriptor
  expectations, memlock, and container seccomp constraints.
- Test refusal behavior at every capacity, not silent allocation or truncation.
- Test io_uring fallback under restricted container settings.

#### Task V3.8-3: Prove graceful shutdown and takeover

- Test SIGINT and SIGTERM with the one process-wide watcher.
- Test HTTP/1.1 `Connection: close`, HTTP/2 GOAWAY, WebSocket close 1001, QUIC
  GOAWAY, and drain timeout.
- Test `SO_REUSEPORT` and systemd socket activation takeover without dropped
  connections.
- Test deinit ordering and repeated shutdown calls.

#### Task V3.8-4: Close supply-chain provenance

- Produce an SBOM and license inventory for every dependency.
- Verify all four zon views, fork reachability, archive, and reproducible
  build.
- Record accepted licenses and downstream modifications.
- Add dependency CVE monitoring and a response owner.
- Never publish a release whose dependency source cannot be resolved.

#### Task V3.8-5: Freeze release provenance

- Releases publish source only; no binary archives or checksums to review.
- Verify the tag equals the manifest version and package paths pass.
- Verify the package consumer from a clean cache.
- Record the release commit, dependency pins, boundary register state, and
  evidence manifest.
- Tags remain maintainer-only; agents never create, move, or push tags.

#### Task V3.8-6: Publish consumer security guidance

- Link the security guide from `SECURITY.md` and `README.md`.
- Document pinning, trust-store loading, mTLS, capacity sizing, timeouts,
  shutdown, and supported platforms.
- State every accepted boundary in consumer-facing terms.
- Keep the guidance synchronized with the register and roadmap.

**Evidence:** CI platform matrix, capacity/refusal tests, shutdown and takeover
runs, SBOM and license audit, reproducible-build proof, consumer guide review.

**Exit criteria:** every support claim has a matching gate; every deployment
limit is documented and tested; every release source is resolvable and
archived.

### 16.13 v3.9.0: Assurance, Disclosure, and Final Boundary Closure

**Objective:** prove the program, not just the code. Complete the audit,
disclosure drill, final register review, and security release.

**Boundaries:** SB-50 through SB-54.

**Dependencies:** all prior v3.x releases. No new feature work is allowed in
this release except fixes required by audit findings.

#### Task V3.9-1: Run the full assurance campaign

- Run ASan, UBSan, LSan, MSan boundary smoke, and the full fuzz campaign.
- Run h1spec, HTTP/2, Autobahn, HTTP/3 interop, package consumer, and
  cross-target compile.
- Run a 24-hour or longer soak with mixed HTTP/1.1, HTTP/2, WebSocket, TLS,
  HTTP/3, client, and shutdown traffic.
- Record every finding, owner, fix, and retest.

#### Task V3.9-2: Commission the external review

- Define scope: TLS, HTTP framing, WebSocket, HTTP/3, C ABI, ownership, and
  supply chain.
- Provide the threat model, register, tests, and build instructions.
- Triage findings by severity, fix blockers, and retest.
- Publish a summary that does not expose unfixed exploit details.

#### Task V3.9-3: Run the disclosure drill

- Simulate a private report, acknowledgement, reproduction, fix, advisory,
  backport, and credit.
- Verify the embargo and release-note process.
- Verify the CVE request path and consumer notification.
- Record the drill report and correct the process.

#### Task V3.9-4: Close the register

- Every SB row is Closed or Accept.
- No Defer remains without a dated restoration trigger and owner.
- Every Closed row links to a test or CI job and the evidence manifest.
- Every Accept row links to an ADR and review date.
- Update `SECURITY.md`, `docs/roadmap.md`, `THIRD_PARTY_NOTICES.md`, and the
  boundary register together.

#### Task V3.9-5: Prepare and publish the security release

- Update all version surfaces and changelog.
- Run the full release checklist and package-path check.
- Create the annotated tag only after review and merge; the maintainer owns the
  tag.
- Publish source only and link the evidence manifest.
- Record the post-release monitoring window.

#### Task V3.9-6: Post-release review

- Review incidents, audit findings, fuzz findings, and support reports.
- Decide the next boundary intake and review date.
- Keep the register open for new boundaries; do not freeze security work.
- Archive the v3.9.0 evidence and release notes.

**Evidence:** full assurance report, external audit report, disclosure drill,
closed register, release artifacts, post-release review.

**Exit criteria:** zero Open boundaries, no unexplained Defer, audit findings
closed or accepted, and the release evidence is reproducible.

### 16.14 Sequencing, parallelization, and critical path

| Track | Releases | Can run in parallel with |
| :--- | :--- | :--- |
| Governance and evidence | v3.0.0 | nothing; it gates the program |
| Runtime and platform | v3.1.0 | early v3.5.0 threat work |
| HTTP/1.1 and HTTP/2 | v3.2.0 | v3.3.0 after v3.1.0 |
| WebSocket and compression | v3.3.0 | v3.2.0 after v3.1.0 |
| QUIC and HTTP/3 | v3.4.0 | v3.2.0 and v3.3.0 |
| TLS, identity, and secrets | v3.5.0 | v3.2.0 and v3.3.0 |
| Ownership, router, C ABI | v3.6.0 | v3.2.0 and v3.3.0 |
| Outbound client | v3.7.0 | v3.5.0 |
| Platform, operations, supply chain | v3.8.0 | v3.5.0 and v3.6.0 |
| Assurance and closure | v3.9.0 | nothing; it closes the program |

Critical path: v3.0.0 -> v3.1.0 -> v3.2.0 -> v3.4.0 -> v3.9.0. WebSocket,
TLS, ownership, and client work can overlap once their dependencies are stable.
Do not start v3.9.0 while any v3.1.0 runtime gate is open.

### 16.15 Risk register

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Scope creep turns v3 into a feature program | Security work slips | Boundary register is the only scope; new features need a separate ADR and release |
| A boundary is marked Closed without a failing-before test | False assurance | Reviewer rejects; `check_security_boundaries.sh` requires evidence |
| A gate is weakened to pass a release | Security regression | Integrator and reviewer compare gate definitions; no threshold edits |
| Platform claims outrun CI | Consumer harm | Publish only the tested matrix; Windows and BSD stay gated |
| Upstream or fork drift | Supply-chain surprise | Pin full commits, archive, review range, branch protection |
| Fuzz or compliance flakes hide a defect | Missed regression | Keep raw artifacts, reproduce, fix root cause, no retry-only closure |
| Secret leaks through logs or errors | Credential exposure | Zeroization tests, log review, error mapping, no secret-bearing traces |
| Audit findings arrive late | Release delay | Start audit early in v3.9.0; block release on unresolved findings |
| Accepted boundary becomes a silent default | Unexpected exposure | ADR, review date, and consumer-facing guidance |

### 16.16 Definition of done for v3.9.0

The v3 program is done when all of the following are true:

- Every `SECURITY.md` claim has an SB ID and a final status.
- Every Fix and Harden boundary has a regression test or CI job that fails
  without the change.
- Every Accept boundary has an ADR with rationale, owner, and review date.
- No Defer boundary remains without a dated restoration trigger and owner.
- The boundary register, `SECURITY.md`, `docs/roadmap.md`, `CHANGELOG.md`, and
  the release notes agree.
- The external audit and disclosure drill are closed or have accepted,
  documented findings.
- The package consumer, cross-target matrix, sanitizers, fuzz, h1spec,
  Autobahn, and HTTP/3 gates pass on the release commit.
- The release is source-only, reproducible from the documented pins, and
  shipped with an evidence manifest.

## 17. Full-Stack Module Program (FS-0 to FS-10)

**Status:** canonical task list for the module expansion requested for
µWebZockets. The design rationale, rejected options, and acceptance evidence
live in `uWZ-Disadvantages.md` under the matching FS IDs.

**Scope:** add optional, independently importable modules for SQL, S3, jobs,
cache, sessions, JWT, protobuf, metrics, and tracing without turning the core
server into a monolith and without adding a mandatory dependency to a program
that does not use them.

**Relationship to the v2.x sections:** sections 9, 11, 13, and 14 already carry
the detailed SQL, proto/gRPC, sessions/JWT, and metrics/tracing tasks. This
section is the integration contract, the missing S3/jobs/cache work, and the
release mapping. When the two disagree, the more specific task in sections 9,
11, 13, or 14 wins for its module; this section wins for lifecycle, naming,
feature gates, and release sequencing.

### 17.1 Non-negotiable module rules

1. **Optional import.** A program that does not import a module must not link
   its code, its C library, or its crypto path. Feature flags and conditional
   imports are mandatory.
2. **Core stays lean.** `src/root.zig` may re-export a module only when the
   build option enables it. The server core must not depend on SQL, S3, jobs,
   cache, JWT, proto, sessions, metrics, or tracing.
3. **Per-worker ownership.** SQL pools, S3 clients, job workers, caches, trace
   buffers, and metric registries are per-worker by default. No global lock,
   no cross-thread pool, no shared mutable state on the request path.
4. **Zero request-path allocation.** Module request paths use startup slabs,
   caller-owned buffers, or explicit bounded arenas. A module that cannot meet
   this must document the allocation and obtain an ADR exception.
5. **Explicit types.** No OOP, no hidden service locator, no reflection-driven
   schema. Named config, named errors, named callbacks, and explicit context
   pointers only.
6. **Fail closed.** TLS verification, credential handling, session keys, JWKS,
   SQL parameters, S3 signatures, and job leases fail closed with stable
   errors. No secret in logs, error strings, metrics labels, or traces.
7. **C ABI stays core.** New modules are Zig-only in the first release. Any C
   ABI expansion needs a separate ADR, header synchronization, and C/C++
   consumer tests.
8. **No mandatory new build tool.** SQLite is compiled from a pinned
   amalgamation with `zig cc`; no CMake, Ninja, Perl, Python, or Go build step.
9. **One module, one owner.** The architect names the module owner and the
   reviewer domain before implementation. Shared files stay serialized.

### 17.2 Current module inventory and naming

This is the state at 2.1.6. Do not create a duplicate module where an existing
one already owns the behavior.

| Capability | Current state | Public name today | New module or change |
| --- | --- | --- | --- |
| HTTP conditional GET / ETag | Implemented in `src/http/cache.zig` | `uz.cache` | Keep; do not reuse the name for the new cache |
| Cookies | RFC 6265 parsing and HMAC signing in `src/http/cookie.zig` | `uz.cookie` | Build `uz.sessions` on top |
| Auth middleware | Basic/Bearer, CORS, security headers, rate limit in `src/http/middleware.zig` | `uz.middleware` | Extract only when it reduces complexity |
| Metrics | Fixed counters and Prometheus in `src/observability/metrics.zig` | `uz.metrics` | Expand in place |
| JSON-RPC | `src/rpc/json_rpc.zig` | `uz.json_rpc` | Keep |
| OpenAPI | `src/http/openapi.zig` | `uz.openapi` | Keep |
| HTTP client | Bounded HTTP/1.1 in `src/client/` | `uz.client` | S3, JWKS, and OTLP exporter use it |
| Web Crypto subset | AES-GCM/HMAC/SHA in `src/crypto/subtle.zig` | `uz.crypto_subtle` | Sessions/JWT use it |
| SQL | Not present; planned in section 9 | none | `uz.sql` |
| S3 | Not present | none | `uz.s3` |
| Jobs | Not present | none | `uz.jobs` |
| In-process cache | Not present | none | `uz.memory_cache` |
| Sessions | Not present as a module | none | `uz.sessions` |
| JWT | Not present; planned in section 13 | none | `uz.jwt` |
| Protobuf | Not present; planned in section 11 | none | `uz.proto` |
| Tracing | Not present | none | `uz.trace` |

**Naming decision:** `uz.cache` is already the HTTP ETag/conditional-GET helper.
Do not silently change it. Export the new cache as `uz.memory_cache` and state
the distinction in `docs/api.md`. A future major release may rename the HTTP
helper to `uz.http_cache` and give `uz.cache` to the store; that is a separate
breaking-change ADR, not part of this program.

### 17.3 FS-0: Module foundation, lifecycle, and feature gates

**Priority:** P0 for the module program; blocks every module that owns a
connection, worker, or background task.

**Problem:** the core app has no shared lifecycle for per-worker resources.
SQL pools, S3 clients, job workers, caches, and trace exporters need to start
after the listener binds, fail startup cleanly, report readiness, and stop in
reverse order after drain. A module must not invent its own hidden global or
spawn an unowned thread.

**Tasks:**

- [ ] Define `src/modules/service.zig` (or `src/core/service.zig`) with named,
      explicit types:
      - `WorkerContext`: worker index, `std.Io`, opaque loop handle, config
        pointer, and a `*anyopaque` module context.
      - `ServiceHooks`: `start`, `stop`, `ready`, and `deinit` named function
        pointers plus a context pointer.
      - `ServiceError`: a bounded error set with `Unexpected` and module
        errors; modules map their internal errors into it.
  - Do not use `anytype` in the public API. Do not hide state behind a global
    registry.
- [ ] Add `App.provide(hooks)` or an equivalent explicit registration. The App
      owns the hook list in its existing fixed-capacity storage. No dynamic
      allocation after `init`.
- [ ] Startup order: bind listeners, then start services in registration order,
      then log ready. A service start failure stops the services already
      started and returns a stable error naming the service.
- [ ] Shutdown order: stop accepting, drain connections, stop services in
      reverse registration order, then destroy the loop. A service that owns a
      task must stop it before the loop is destroyed.
- [ ] Cluster: each worker gets its own service instance and `WorkerContext`.
      A service that needs shared state must use SQL or an external system, not
      shared memory. Provide a bounded way to report per-worker start failure
      to the cluster's existing `WorkerFailure` record.
- [ ] Readiness: a service may return a reason string or null. The health route
      asks services, not the process. Bound the reason length; no secrets.
- [ ] Feature gates: add build options and conditionals for `sql`, `sqlite`,
      `s3`, `jobs`, `cache`, `sessions`, `jwt`, `proto`, `metrics`, `trace`.
      A program that disables a module must not link its code or C dependency.
- [ ] Add a module test harness that starts a real loop, a fake worker context,
      and a bounded service with start/stop/ready/drain assertions.
- [ ] Document the lifecycle in `docs/modules.md` and the ADR for the module
      foundation.

**Acceptance:**

- A service starts once per worker, reports readiness, stops once, and leaves
  no pending task when the loop is destroyed.
- A failed start rolls back already-started services and preserves the first
  error.
- A disabled module is absent from the binary; verify with `nm`/link map.
- No new allocation on the steady-state request path.

### 17.4 FS-1: SQL (`uz.sql`)

**Release:** v2.3.0 (PostgreSQL), v2.3.1 if SQLite/migrations slip.

**Canonical tasks:** Section 9, D-0 through D-11. This section adds the module
integration contract only.

- [ ] Export `uz.sql` with `Sql`, `Db`, `Tx`, `Rows`, `Value`, `FromRow`, and
      `ToParam` from `src/sql/`.
- [ ] PostgreSQL first; SQLite optional and feature-gated.
- [ ] Per-worker pool; no global pool; no mutex on the query path.
- [ ] Parameter binding only; no string interpolation.
- [ ] Bound statement, parameter, row, field, and response bytes.
- [ ] SQLite amalgamation pinned under `vendor/sqlite/`, compiled by `zig cc`.
- [ ] Migrations with checksums and an advisory/exclusive lock.
- [ ] SQL pool metrics added to `uz.metrics`.
- [ ] Trace child spans with statement name, not parameter values.
- [ ] Integration tests: SQLite in CI; PostgreSQL service container with a
      written skip reason when unavailable.
- [ ] Update `docs/sql.md`, `README.md`, and `docs/roadmap.md`.

**Depends on:** FS-0, client TLS, timing wheel, metrics, trace (optional).

### 17.5 FS-2: S3 (`uz.s3`)

**Release:** provisional v2.10.0, or after the client pooling boundary
(v3.7) if the maintainer requires pooled connections for production S3.

**Problem:** object storage is the most common external service after SQL.
Nilo ships `nilo_s3`; Dusty recommends an external client. µWebZockets has the
HTTP client, BoringSSL, and bounded buffers, but no SigV4, multipart, or
presigned URL surface.

**Tasks:**

- [ ] Define `src/s3/` with `S3` service config, per-worker client, operation
      errors, and bounded request/response buffers.
- [ ] SigV4:
      - Canonical request, canonical headers, signed headers, payload hash.
      - HMAC-SHA256 signing key derivation with the existing crypto module.
      - Constant-time comparison for any MAC verification.
      - Clock skew handling and `RequestTimeTooSkewed` mapping.
      - `UNSIGNED-PAYLOAD` policy only over verified TLS, documented.
- [ ] Operations:
      - `headObject`, `getObject`, `putObject`, `deleteObject`, `copyObject`.
      - `listObjectsV2` with bounded keys, continuation token, and page size.
      - Multipart create/upload part/complete/abort with bounded part counts
        and part size.
      - Presigned GET/PUT URL generation as a pure function with an expiry.
- [ ] Streaming:
      - GET streams into a caller-owned buffer or sink; never buffers the
        whole object.
      - PUT accepts a bounded body or a producer callback; no unbounded
        retry of a non-rewindable body.
      - Multipart part bodies are bounded and can be retried individually.
- [ ] Retries:
      - Idempotent operations only; bounded attempts, exponential backoff with
        jitter, and a deadline.
      - Honor `Retry-After` and `SlowDown` within the bound.
      - Do not retry a partially consumed stream unless it is rewindable.
- [ ] Security:
      - TLS verification is required; no `verify = false` shortcut.
      - Endpoint validation and an optional allowlist; handle region redirects
        only to the configured endpoint/region.
      - Credentials are never logged, traced, or placed in URL query strings
        except the intended presigned URL.
      - SSRF controls for a caller-supplied endpoint; do not fetch arbitrary
        redirects.
- [ ] Errors: map HTTP status and S3 error codes to a stable error set;
      include the request id for support without leaking credentials.
- [ ] Add a bounded XML reader for the S3 error and ListObjectsV2 shapes. Do
      not add a general XML dependency; parse only the documented elements and
      reject unexpected nesting or oversized text.
- [ ] Metrics/tracing: operation, status, bytes, retries, and latency; span
      attributes exclude bucket secrets and object bodies.
- [ ] Tests:
      - SigV4 golden vectors and presigned URL vectors.
      - Mock S3 loopback server for success, 403, 404, 409, 429, 500, slow
        body, truncated body, and redirect.
      - Multipart complete/abort and part retry.
      - Optional MinIO integration gate with a documented skip reason.
      - Fuzz the canonicalization and XML error parser.
- [ ] Docs: `docs/s3.md`, a local MinIO example, a presigned-upload example,
      and an explicit "not an AWS SDK" boundary.

**Depends on:** FS-0, `uz.client`, BoringSSL, `uz.proto` (optional for XML?
No, S3 uses XML; proto not required), metrics/trace optional.

### 17.6 FS-3: Jobs (`uz.jobs`)

**Release:** provisional v2.11.0, after `uz.sql`.

**Problem:** background work is a core framework capability. Nilo's jobs are a
database-backed queue with retries and schedules. µWebZockets needs the same
without adding a broker or a hidden global thread.

**Tasks:**

- [ ] Define `src/jobs/` with `Jobs`, `JobContext`, `JobHandler`, `Enqueue`,
      `Schedule`, and `RetryPolicy`.
- [ ] Storage schema:
      - `id`, `kind`, `payload`, `state`, `attempts`, `max_attempts`,
        `run_at`, `leased_until`, `lease_owner`, `last_error`,
        `created_at`, `updated_at`, `idempotency_key` (optional).
      - Indexes for claim order and lease expiry.
      - Migration owned by `uz.sql` migrations.
- [ ] Enqueue:
      - `enqueue(tx, job)` commits with the caller's transaction.
      - `enqueueDetached` is explicit and documented; no hidden transaction.
      - Payload size and kind length are bounded.
- [ ] Claim:
      - PostgreSQL: `SELECT ... FOR UPDATE SKIP LOCKED` with a bounded batch.
      - SQLite: single-writer `BEGIN IMMEDIATE` or documented single worker.
      - Lease duration, heartbeat, and expired-lease recovery.
      - At-least-once delivery is the contract; idempotency is the caller's
        responsibility and is documented.
- [ ] Execution:
      - Per-worker worker pool with a fixed concurrency.
      - `JobContext` exposes `io`, attempt, deadline, and cancellation.
      - Retry with backoff, max attempts, and dead-letter state.
      - A handler error is recorded with a bounded message; no secret leakage.
- [ ] Schedules:
      - Cron or interval schedules with an explicit overlap policy
        (`skip`, `queue`, `replace`) and missed-tick policy.
      - Use the timing wheel or a bounded poll; no per-job thread.
      - A schedule must declare its policy at compile time or startup; no
        silent default.
- [ ] Shutdown:
      - Stop claiming, let in-flight jobs finish within a deadline, release
        leases, and stop before the SQL service.
- [ ] Metrics/tracing: enqueued, claimed, completed, failed, retried, dead,
      queue depth, oldest age, lease expiry; a span per job execution.
- [ ] Tests:
      - Enqueue in a committed and rolled-back transaction.
      - Exactly one claim under concurrent workers (where the backend supports
        it); at-least-once semantics under lease expiry.
      - Retry/backoff, max attempts, dead letter, schedule overlap, missed
        tick, shutdown drain, SQLite behavior.
      - No unbounded payload or result storage.
- [ ] Docs: `docs/jobs.md`, a Postgres example, a SQLite example, a scheduled
      job example, and the at-least-once/idempotency contract.

**Depends on:** FS-0, FS-1 SQL, timing wheel, metrics/trace optional.

### 17.7 FS-4: In-process cache (`uz.memory_cache`)

**Release:** provisional v2.12.0, independent of SQL/S3.

**Problem:** applications need a bounded in-process cache for sessions, JWKS,
rate-limit metadata, rendered fragments, and idempotency data. The existing
`uz.cache` is HTTP ETag/conditional GET, not a key/value store.

**Tasks:**

- [ ] Define `src/cache/memory.zig` and export `uz.memory_cache`.
      Do not rename or repurpose `uz.cache` in this program.
- [ ] API:
      - Fixed-capacity typed keyspace. A value is a fixed-size value or a
        byte slice copied into the cache arena; pointers inside a value are
        forbidden and checked where the language permits.
      - `get`, `put`, `remove`, `contains`, `clear`, `stats`.
      - Optional TTL per entry and a default TTL.
      - Atomic `getOrPut` is not required; per-worker single-threaded use is
        the default.
- [ ] Storage:
      - Open-addressed table with bounded probe work.
      - Value arena with a fixed byte budget; eviction when full.
      - LRU or CLOCK eviction; state the tie break and cost.
      - Lazy TTL expiration on access plus a bounded sweep; no background
        thread unless the user starts one.
      - No allocation after `init`; a value larger than the budget returns
        `error.ValueTooLarge`.
- [ ] Isolation:
      - Per-worker cache by default. Document that two workers do not share
        entries.
      - Optional shared cache through SQL or an external service is a separate
        module, not this one.
      - No global lock; no cross-thread mutation.
- [ ] Stats: hits, misses, evictions, expirations, bytes, entries, oldest age.
- [ ] Security: keys and values are not logged; a cache used for secrets must
      zero values on removal where practical. Do not claim secure erasure
      unless it is implemented and tested.
- [ ] Tests: collisions, overwrite, eviction, TTL, capacity, stats, value too
      large, no allocation after init, and no pointer-bearing value.
- [ ] Docs: `docs/cache.md`, a session/JWKS example, and a "when not to use
      this" section (no cross-worker consistency, no persistence).

**Depends on:** FS-0 only.

### 17.8 FS-5: Sessions (`uz.sessions`)

**Release:** v2.7.0.

**Canonical tasks:** Section 13, M-1 and M-5. Summary:

- [ ] Sealed-cookie sessions with AES-256-GCM and a keyring.
- [ ] Bounded payload/cookie size; no request-path allocation.
- [ ] `HttpOnly`, `Secure`, `SameSite`, `Path`, `Max-Age`, expiry.
- [ ] Session fixation prevention and rotation on privilege change.
- [ ] Optional store-backed sessions for revocation; stateless default.
- [ ] CSRF token helper and constant-time comparison.
- [ ] Tests for tamper, replay, expiry, rotation, size, and concurrent use.
- [ ] Docs and login/logout examples.

**Depends on:** FS-0, `uz.cookie`, `uz.crypto_subtle`.

### 17.9 FS-6: JWT (`uz.jwt`)

**Release:** v2.7.0.

**Canonical tasks:** Section 13, M-4 and M-5. Summary:

- [ ] Strict compact JWT parsing; reject `none` and non-canonical base64url.
- [ ] HS256, RS256, ES256, EdDSA; algorithm allowlist mandatory.
- [ ] `exp`, `nbf`, `iat`, `iss`, `aud`, `sub`, `jti`; configurable skew.
- [ ] Bounded token/header/claim sizes; borrowed claims for request lifetime.
- [ ] Optional JWKS cache with TTL, unknown-`kid` refresh, and SSRF controls.
- [ ] Constant-time comparison; zeroize secrets; no token logging.
- [ ] Tests: vectors, alg confusion, expiry, audience/issuer, malformed,
      oversized, rotation, missing key.
- [ ] Docs and protected-route examples.

**Depends on:** FS-0, `uz.crypto_subtle`/BoringSSL, optional `uz.client` for
JWKS.

### 17.10 FS-7: Protobuf and gRPC (`uz.proto`, `uz.grpc`)

**Release:** v2.5.0.

**Canonical tasks:** Section 11, R-0 through R-5. Summary:

- [ ] Shared `uz.proto` codec; no second decoder under `src/grpc/`.
- [ ] Varint, zigzag, fixed32/64, length-delimited, repeated, maps, oneofs,
      unknown-field skipping, bounded recursion.
- [ ] Zero allocation: decode borrows input; encode writes caller storage.
- [ ] Canonical protobuf vectors and round-trip tests.
- [ ] gRPC 5-byte framing, HTTP/2 trailers, cancellation, and status mapping.
- [ ] OTLP tracing uses `uz.proto` for its payload.
- [ ] Docs: `docs/proto.md`, `docs/grpc.md`.

**Depends on:** FS-0, HTTP/2 server, metrics/trace optional.

### 17.11 FS-8: Metrics (`uz.metrics`)

**Release:** v2.8.0.

**Canonical tasks:** Section 14, O-1 through O-4 and O-8. Summary:

- [ ] Expand the existing counter registry with gauges and bounded histograms.
- [ ] Per-worker state; scrape aggregates without a request-path lock.
- [ ] Prometheus/OpenMetrics rendering with no allocation.
- [ ] HTTP, WebSocket, HTTP/2, QUIC, SQL, S3, jobs, cache, JWKS, and trace
      metrics.
- [ ] Slab saturation, queue depth, pool occupancy, and error counters.
- [ ] Cardinality bounds; no request-derived labels.
- [ ] Docs and `/metrics` examples.

**Depends on:** FS-0; modules add their own counters when they land.

### 17.12 FS-9: Tracing (`uz.trace`)

**Release:** v2.8.0 or v2.8.1.

**Canonical tasks:** Section 14, O-5 through O-8. Summary:

- [ ] W3C `traceparent`/`tracestate` parse and emit.
- [ ] Trace/span IDs from injected entropy; sampling decision.
- [ ] Bounded span, attribute, event, and queue sizes; per-worker buffers.
- [ ] Server span per request; child spans for SQL, S3, jobs, cache, and
      outbound client.
- [ ] OTLP/HTTP protobuf exporter with TLS, batch, retry, and shutdown flush.
- [ ] Redaction of credentials, cookies, tokens, and raw query parameters.
- [ ] Golden OTLP tests and a local receiver/mock.
- [ ] Docs: `docs/tracing.md`, a full request -> SQL -> S3 -> job trace.

**Depends on:** FS-0, FS-7 proto, `uz.client`, metrics optional.

### 17.13 FS-10: Integration, recipes, and release surface

**Release:** v2.13.0 provisional, or the first release after all enabled
modules are green.

- [ ] Add `docs/modules.md` with the module matrix, feature flags, lifecycle,
      ownership, and C ABI boundary.
- [ ] Add runnable recipes:
      - SQLite CRUD.
      - PostgreSQL CRUD + transaction + jobs.
      - S3 upload/download + presigned URL.
      - Sessions + JWT login.
      - Cache-backed JWKS/session/idempotency.
      - Metrics + tracing dashboard.
- [ ] Update `README.md` from "server framework" to "server framework with
      optional application modules" without overclaiming.
- [ ] Update `docs/roadmap.md` and remove or narrow any deliberate boundary
      that the modules close.
- [ ] Update `docs/memory_model.md` with module startup costs and per-worker
      storage.
- [ ] Add the module boundaries to the v3 security register:
      SQL injection/TLS, S3 SigV4/SSRF, sessions AEAD/replay, JWT alg
      confusion/JWKS, proto bombs, jobs lease/idempotency, cache secrecy,
      tracing redaction, metrics cardinality.
- [ ] Add the module matrix to the release checklist and CI.
- [ ] Do not expose modules through the C ABI in this program.

### 17.14 Module release map and dependencies

| Release | Modules | Depends on | Gate |
| --- | --- | --- | --- |
| v2.3.0 | `uz.sql` PostgreSQL + typed rows | FS-0, TLS, timing wheel | PG integration + allocation + p99 |
| v2.3.1 | SQLite + migrations (if not in 2.3.0) | v2.3.0 | SQLite CI + migration tests |
| v2.5.0 | `uz.proto`, gRPC | FS-0, HTTP/2 | Proto vectors + gRPC interop |
| v2.7.0 | `uz.sessions`, `uz.jwt` | FS-0, cookie, crypto, client (JWKS) | Tamper/replay + alg confusion |
| v2.8.0 | `uz.metrics`, `uz.trace` | FS-0, proto, client | Prometheus parse + OTLP golden |
| v2.10.0 (prov.) | `uz.s3` | FS-0, client, BoringSSL | SigV4 vectors + mock S3 |
| v2.11.0 (prov.) | `uz.jobs` | FS-0, `uz.sql`, timing wheel | Claim/retry/lease/shutdown |
| v2.12.0 (prov.) | `uz.memory_cache` | FS-0 | Eviction/TTL/allocation |
| v2.13.0 (prov.) | Integration, recipes, docs | all enabled modules | Full matrix + docs |
| v2.14.0 (prov.) | MCP server tools-only | JSON-RPC, OpenAPI, SSE, auth/sessions, trace | MCP conformance + security |

Provisional means the maintainer may move the release slot after the
dependency and security evidence is known. Do not start S3 before the client
TLS verification boundary is understood; S3 may use the current one-request
client, but production guidance must state the pooling limitation.

### 17.15 Module test matrix and gates

Every module must pass:

- Unit tests for its pure codec/parser/verification logic.
- A real loopback integration test where the module speaks a protocol.
- A bounded-capacity test: every queue, pool, table, and buffer has a limit and
  a stable error when full.
- An allocation test: no request-path allocation after startup.
- A secret-redaction test: no token, password, cookie, or key in logs, errors,
  metrics, or traces.
- ASan, UBSan, LSan; fuzz targets for every peer-controlled parser.
- A feature-gate test: disabled module absent from the binary.
- A documentation example that compiles.
- Optional service integration (PostgreSQL, S3/MinIO, OTLP receiver) with a
  written skip reason when the service is unavailable.

Add these gates to `CI_CD_PIPELINE.md` and `docs/operations.md` in the same
change that lands the module.

### 17.16 Module risks and non-goals

**Risks:**

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Core becomes a monolith | Slow builds, forced dependencies | Optional imports, feature gates, linker check |
| Module allocates on request path | p99 and slab regressions | Allocation tests and explicit arenas |
| SQL/S3 protocols are subtle | Security and correctness bugs | Golden vectors, fuzz, mock servers, optional live gates |
| JWT/session crypto is wrong | Account compromise | Use existing audited crypto, constant-time, vectors, review |
| Jobs deliver twice | Duplicate side effects | At-least-once contract, idempotency keys, docs |
| Cache hides cross-worker inconsistency | Stale data | Per-worker default, explicit docs, no shared claim |
| Tracing leaks secrets or blocks | Compliance and latency | Redaction, bounded queue, drop counter, shutdown deadline |
| Module creep delays v3 security closure | Roadmap slip | Module track has its own FS IDs; v3 boundaries are not weakened |

**Non-goals:**

- No ORM, no query builder, no automatic schema reflection in the first SQL
  release.
- No protobuf compiler or `.proto` file parser.
- No full AWS SDK; `uz.s3` is an S3 subset with explicit limits.
- No distributed cache, no Redis client in the first cache release.
- No job broker; jobs use the SQL database you already have.
- No C ABI for modules in this program.
- No mandatory S3/SQL/JWT dependency in the core server.

### 17.17 Definition of done for the module program

- [ ] FS-0 lifecycle and feature gates are green.
- [ ] `uz.sql` supports PostgreSQL and SQLite with typed rows and migrations.
- [ ] `uz.s3` supports SigV4, get/put/head/delete/list, multipart, and
      presigned URLs with mock/live gates.
- [ ] `uz.jobs` supports enqueue-in-transaction, leases, retries, and
      schedules with at-least-once documentation.
- [ ] `uz.memory_cache` is fixed-capacity, evicting, TTL-aware, and
      allocation-free after init.
- [ ] `uz.sessions` and `uz.jwt` pass tamper, replay, and algorithm-confusion
      suites.
- [ ] `uz.proto` passes canonical vectors and backs gRPC and OTLP.
- [ ] `uz.metrics` and `uz.trace` are integrated, redacted, bounded, and
      exportable.
- [ ] Every module has a feature gate, docs, a runnable recipe, and a test
      matrix entry.
- [ ] `README.md`, `docs/roadmap.md`, `docs/api.md`, `docs/memory_model.md`,
      `CI_CD_PIPELINE.md`, and `CHANGELOG.md` describe the shipped surface.
- [ ] No module weakens the zero-allocation, shared-nothing, or C ABI
      contracts.

### 17.18 Agent execution for module work

- **Architect:** choose one FS ID, list the module's public surface, ownership,
  feature gate, storage budget, error set, and acceptance tests. Name the
  module owner and reviewer. Do not implement.
- **Developer:** land one module slice per PR. Keep the core import graph clean.
  Add the unit/integration/allocation/fuzz tests with the code. Report exact
  commands and raw results.
- **Reviewer:** check dependency direction, feature gate, allocation, secret
  handling, error mapping, capacity bounds, and docs. Reject a module that
  forces a core dependency or hides global state.
- **Integrator:** verify the combined module matrix, feature-gated builds,
  docs, changelog, and release mapping. Do not mark a module complete without
  the evidence listed in section 17.15.

---

## 18. MCP Server Integration (MCP-1 to MCP-7)

**Status:** proposed. Depends on the JSON-RPC, OpenAPI, SSE, auth/session, and
tracing work. This is the Zig-native equivalent of exposing typed procedures as
Model Context Protocol tools, inspired by
<https://orpc.dev/docs/integrations/mcp>. It is not a port of the TypeScript
`@orpc/mcp` package and it does not add a Node/TypeScript build step.

**Objective:** let an application expose selected routes or JSON-RPC procedures
as MCP tools over Streamable HTTP, reusing the same handler, middleware,
authentication, schemas, error mapping, and observability as the HTTP surface.

**Why it fits this project:** MCP is JSON-RPC 2.0 over a bounded transport.
µWebZockets already has a strict JSON-RPC registry, an OpenAPI route registry,
SSE streaming, auth middleware, sessions, tracing, and bounded request/response
buffers. The missing pieces are MCP metadata, a tool dispatcher, the Streamable
HTTP transport, and a security policy for agent-facing tools.

### 18.1 Scope and non-goals

In scope:

- MCP server over Streamable HTTP: `initialize`, `notifications/initialized`,
  `ping`, `tools/list`, `tools/call`, `notifications/cancelled`, and
  `notifications/progress`.
- Tool discovery from OpenAPI/route metadata plus explicit overrides.
- Input/output JSON Schema, structured content, and tool annotations.
- Same handler and middleware path as the HTTP route, with a tool-specific
  context.
- Optional resources and prompts after tools are stable.
- Optional stdio transport for local agents, as a separate build target.

Not in scope for the first release:

- An MCP client that connects to other servers.
- A TypeScript SDK dependency or a Node runtime.
- Automatic tool generation from arbitrary Zig function reflection.
- Unbounded tool output, unbounded sessions, or a hidden global registry.
- C ABI exposure. MCP is Zig-only until a separate ADR.

### 18.2 Protocol and transport contract

- MCP messages are JSON-RPC 2.0 objects. Reuse the existing JSON-RPC parser and
  error model where it is compatible; do not create a second JSON parser.
- Endpoint default: `POST /mcp`, with optional `GET /mcp` for server-to-client
  SSE and `DELETE /mcp` for session termination.
- Require `Accept` to include both `application/json` and
  `text/event-stream` for Streamable HTTP requests. Return `406` when the
  client cannot accept the required representation.
- `Mcp-Session-Id` is an opaque, bounded, unpredictable identifier. A session
  table is fixed-capacity and per-worker; expired sessions are reaped by the
  timing wheel. No unbounded session map.
- `initialize` negotiates a supported protocol version and declares
  capabilities. An unsupported version returns a JSON-RPC error, not a silent
  downgrade.
- Batch requests are allowed only if the configured maximum batch is non-zero;
  otherwise reject them explicitly.
- Every request, response, header, session id, and SSE event has a configured
  byte limit.
- Cancellation maps `notifications/cancelled` to the existing async response
  token cancellation or the tool handler's abort token.
- Progress maps `notifications/progress` to SSE events; a tool that does not
  request progress produces none.
- Shutdown drains in-flight tool calls, sends a final event where possible, and
  closes sessions before the loop is destroyed.

### 18.3 Tool registry and metadata

- Add bounded OpenAPI metadata to the route registry:
  `operation_id`, `summary`, `description`, `tags`, `deprecated`,
  `input_schema`, `output_schema`, and `mcp` overrides.
- If `operationId` is absent, derive the tool name from the route path joined
  with `_`, for example `planet_list`. Refuse duplicate names at registration.
- Derive:
  - `title` from `summary`
  - `description` from `description`, otherwise `summary`
  - annotations from the method: `GET`/`HEAD`/`QUERY` => `readOnlyHint`;
    `PUT`/`DELETE` => `idempotentHint`; explicit overrides win.
- Add explicit MCP metadata:
  - `name`, `title`, `description`
  - `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`,
    `openWorldHint`)
  - `icons` (bounded URL and MIME type)
  - `filter`/`enabled` policy
- Filtering: skip internal, deprecated, or non-exposed routes. A route is not a
  tool unless it opts in or the application explicitly registers it.
- Input schema must describe a JSON object. A non-object input is nested under
  an `input` property, matching the orpc behavior.
- Output schema is advertised only when every result has structured content
  matching it. A streamed or binary result is not advertised as a structured
  output schema.
- No reflection-driven schema generation. The schema is declared explicitly in
  route metadata or generated from the existing OpenAPI/schema declarations.

### 18.4 Tool invocation

- A tool call dispatches through the same route handler and middleware chain as
  the equivalent HTTP request. Do not create a second handler path that skips
  authorization, rate limiting, CSRF, or tracing.
- Build a bounded synthetic request from the tool arguments:
  method, path, headers, body, and a tool context. Do not loop back over the
  network for an in-process tool.
- `McpContext` carries: authenticated principal, session, trace context,
  deadline, tool name, request id, and a cancellation token. It does not expose
  the raw socket.
- Tool arguments are validated against the advertised input schema before the
  handler runs. A validation failure is a defined MCP tool error, not a 500.
- Tool results:
  - `undefined`/empty => empty content
  - text => text content plus structured content
  - JSON value => text content plus `structuredContent`
  - binary/image/audio => embedded resource content with MIME type
  - stream => SSE progress/events; the final event is the result
- Errors:
  - Defined application errors => `isError: true` with bounded structured
    JSON the model can read.
  - Unexpected errors => generic internal error; log the detail, never return
    a secret or stack trace.
- Tool handlers must not block the worker loop. Use the handler I/O model in
  WS-9/Part II P13 and the bounded blocking pool for external calls.

### 18.5 Security policy

- The MCP endpoint is privileged. Authentication is required by default:
  Bearer token, session cookie, or mTLS, using the existing auth/session
  middleware.
- A loopback-only development mode may explicitly disable authentication; it
  must be named in config and logged at startup.
- Require an `Origin` check for browser-originated requests; reject an
  unexpected origin unless explicitly allowed.
- Apply CSRF protection where cookie auth is used. Do not rely on the MCP
  session id as CSRF protection.
- Bound rate limits per principal, session, and tool. A destructive tool should
  be rate-limited more tightly.
- Tool annotations are hints, not enforcement. The application owns confirmation
  policy for destructive tools; the protocol cannot prove a human confirmed.
- Do not expose secrets, internal URLs, stack traces, or raw SQL in tool
  descriptions, schemas, errors, or logs.
- Log tool name, principal, status, duration, and request id. Do not log raw
  arguments by default; redact configured fields.
- Resource URLs and icons are untrusted input. Apply SSRF controls and MIME
  allowlists if the server fetches them.
- Prompt injection is an application-layer risk. Document that tool output is
  data, not instructions, and do not let model output drive privileged actions
  without policy.

### 18.6 MCP tasks and milestones

#### MCP-1: Metadata and registry

- [ ] Extend the OpenAPI route metadata with operation id, summary, description,
      tags, deprecated, input schema, output schema, and MCP overrides.
- [ ] Add bounded storage for tool metadata to the router/app startup slab.
- [ ] Add duplicate-name, oversized-description, invalid-icon, and
      non-object-input rejection tests.
- [ ] Add a filter that excludes internal/deprecated routes.
- [ ] Document metadata authoring in `docs/mcp.md`.

#### MCP-2: Tools/list and tools/call

- [ ] Implement JSON-RPC dispatch for `initialize`, `ping`, `tools/list`, and
      `tools/call`.
- [ ] Validate arguments against the advertised schema.
- [ ] Dispatch through the same route handler and middleware as HTTP.
- [ ] Map text/JSON/binary/stream results and defined errors.
- [ ] Add bounded request, response, argument, and result limits.
- [ ] Add golden JSON-RPC tests for discovery, calls, and errors.

#### MCP-3: Streamable HTTP and SSE

- [ ] Register `POST`, `GET`, and `DELETE` handlers for the MCP endpoint.
- [ ] Implement session creation, `Mcp-Session-Id`, expiry, and termination.
- [ ] Implement SSE for progress and server-to-client messages.
- [ ] Implement cancellation and shutdown drain.
- [ ] Test JSON and SSE negotiation, session expiry, cancellation, and a slow
      client.

#### MCP-4: Auth, security, and observability

- [ ] Require authentication by default; add explicit loopback development mode.
- [ ] Add origin checks, CSRF for cookie auth, rate limits, and tool allowlists.
- [ ] Add metrics and trace spans for tool calls, sessions, errors, and drops.
- [ ] Add secret-redaction tests for descriptions, arguments, results, and logs.
- [ ] Document the destructive-tool confirmation policy.

#### MCP-5: Resources and prompts (optional)

- [ ] Add explicit resource registration for static files, OpenAPI documents,
      and application docs.
- [ ] Add prompt registration with bounded templates and arguments.
- [ ] Do not auto-expose every route as a resource or prompt.
- [ ] Add `resources/list`, `resources/read`, `prompts/list`, and
      `prompts/get` tests.

#### MCP-6: stdio transport (optional)

- [ ] Add a separate `mcp_stdio` build target for local agents.
- [ ] Frame JSON-RPC over stdin/stdout with bounded lines and clean shutdown.
- [ ] Do not run stdio on a worker loop that also serves HTTP unless the
      process is explicitly configured for it.
- [ ] Add an integration test with a pipe client.

#### MCP-7: Conformance, docs, and example

- [ ] Add a conformance suite covering initialize, capability negotiation,
      tools/list, tools/call, errors, cancellation, sessions, and SSE.
- [ ] Test with the official MCP Inspector or an equivalent client.
- [ ] Add `examples/mcp_server.zig` exposing two read-only tools and one
      destructive tool with a confirmation policy.
- [ ] Add `docs/mcp.md` with security guidance, schema authoring, and the
      difference between MCP tools and HTTP routes.
- [ ] Add MCP to the metrics/tracing example and to the v3 security register
      (SB-64: tool authorization, session, argument/result redaction, SSRF).

### 18.7 Release mapping

- Suggested slot: v2.14.0 provisional, after v2.13.0 module integration.
- Dependencies: JSON-RPC, OpenAPI metadata, SSE, auth/sessions, tracing,
  bounded JSON, and the module lifecycle (FS-0).
- Do not ship MCP before the auth and session boundaries are green.
- MCP is Zig-only; no C ABI in the first release.
- If resources/prompts or stdio are not ready, ship tools-only and state the
  boundary explicitly.

### 18.8 Acceptance criteria

- [ ] An MCP client can initialize, list tools, call a read-only tool, and get
      structured content.
- [ ] Tool calls use the same auth, middleware, and tracing as the HTTP route.
- [ ] A destructive tool is filtered or requires the documented policy.
- [ ] Invalid arguments, unknown tools, and unexpected errors return bounded
      MCP errors without secrets.
- [ ] Sessions expire; cancellation and shutdown drain.
- [ ] No request-path allocation; no unbounded session or output storage.
- [ ] Metrics and traces record tool calls without raw argument leakage.
- [ ] `docs/mcp.md` and the example compile and pass the conformance suite.

### 18.9 References

- orpc MCP integration:
  <https://orpc.dev/docs/integrations/mcp>
- Model Context Protocol specification:
  <https://modelcontextprotocol.io/specification/latest>
- MCP tools:
  <https://modelcontextprotocol.io/specification/latest/server/tools>
- MCP Streamable HTTP transport:
  <https://modelcontextprotocol.io/specification/latest/basic/transports>
- MCP Inspector:
  <https://github.com/modelcontextprotocol/inspector>
- Existing local modules: `src/rpc/json_rpc.zig`, `src/http/openapi.zig`,
  `src/http/response.zig` (`ServerSentEvents`), `src/http/middleware.zig`,
  `src/observability/trace.zig` (planned), `src/sessions/` (planned).

---

## Part II: Design Dossiers and Acceptance Evidence

This part is the merged `uWZ-Disadvantages.md`. It preserves its own
P-numbering (`P0` through `P27`) so the detailed design dossiers, rejected
options, and evidence criteria stay stable when Part I milestones move.

**Authority:** Part I is authoritative for release numbers, checkboxes,
dependency pins, and current scheduling. Part II is authoritative for the
design rationale, acceptance evidence, and the reasons a simpler option was
rejected. If they disagree about *what to do now*, Part I wins; if they
disagree about *why* or *what proof is required*, Part II wins.

**How to read it:** start with the workstream that owns your change, read its
problem and acceptance criteria, then return to the Part I milestone that
tracks it. The main crosswalk is: WS-1 engine seam, WS-2 idle memory, WS-3 build
weight, WS-4 docs/DX, WS-5 four-axis budget, WS-6 Windows, WS-7 Zig 0.17, WS-8
client, WS-9 handler I/O, WS-10 typed API, WS-11 full-stack modules.

---

## P0. Vision in one paragraph

µWebZockets is already a strong specialized server framework: its protocol
breadth, zero-allocation hot path, conformance evidence, cluster model, and C
ABI are real differentiators. It is not yet a general-purpose "decent Zig
framework" in the Dusty/nilo sense, because its engine boundary is leaky, its
per-idle-connection memory is unmeasured, its default build is heavy, and its
docs/DX are behind. The full-stack module gap is now in scope: SQL, S3, jobs,
cache, sessions, JWT, proto, metrics, and tracing are planned as optional
modules, not as a monolithic clone of nilo. The P0 work remains WS-1 (engine
seam) and WS-2 (idle memory). The P1 work is WS-5 (quality budget), WS-4/WS-3
(docs and build weight), and WS-11/FS-0 (module lifecycle and feature gates).
Windows, the client, Zig 0.17, and the remaining modules follow. Keep libxev
and the Farben fork throughout.

---

## P1. Fixed decisions and constraints

These are not open for debate inside this program unless a written ADR changes
them.

1. **Keep libxev.** The runtime stays on the maintained
   `farbenbuilds/libxev` fork pinned in `build.zig.zon`.
   - Current pin: `c49f6dfb83038c146232472c063e4b2681d098d8`
     (`uwz/zig-0.16`, XEV-001 through XEV-005).
   - Do not migrate to `std.Io.Evented`, `zio`, or a home-grown event loop as
     part of this work.
   - Do not push, open issues, or submit patches to `mitchellh/libxev`.
   - Follow `docs/dependency_forks.md`; pin full 40-hex commits only.
2. **Zig 0.16 now, Zig 0.17 later.** Do not mix the upgrade into engine-seam or
   memory work. The 0.17 upgrade is its own milestone and its own libxev
   integration branch (`uwz/zig-0.17`, already anticipated by policy).
3. **Keep the zero-allocation request path.** No request, parse, route, or write
   path may allocate in steady state. New features must either fit the startup
   slab, use caller-owned storage, or be explicitly opt-in with a documented
   cost.
4. **Keep fixed capacity and explicit exhaustion.** Do not replace bounded
   capacities with unbounded growth. `error.WouldBlock` and structured
   rejection documents stay.
5. **Keep the C ABI.** Changes must not silently break
   `include/uWebZockets.h` or the C ABI tests.
6. **Full-stack modules are in scope, but as optional modules.** SQL, S3, jobs,
   cache, sessions, JWT, proto, metrics, and tracing are implemented as
   independently importable modules with feature gates. They must not become
   mandatory dependencies of the core server, must not add a global service
   locator or hidden state, and must not be exposed through the C ABI without a
   separate ADR. This replaces the earlier "recipes only, no modules" position.
7. **Do not weaken tests, lints, thresholds, sanitizers, or benchmarks to make a
   change pass.** A regression is a finding, not an obstacle.
8. **No new build-time Python, CMake, Ninja, Go, Perl, or system zlib
   requirements.** Benchmark/report tooling may use existing scripts, but
   `zig build` must remain Zig-native. SQLite is compiled from a pinned
   amalgamation with `zig cc` when the optional SQLite backend is enabled.

### What "good enough" means

A framework is good enough when all of the following are true:

- A new user can build and run a real service from a clean checkout without
  reading the source.
- The cost of a connection, a request, and a feature is measured and published,
  not inferred.
- The runtime boundary is explicit enough that an engine change or a test fake
  is possible without rewriting application code.
- Platform support claims are backed by a green native job for the release
  commit.
- The project has a quality budget that catches regressions before release.
- The protocol and conformance evidence remains stronger than the competition.

µWebZockets is already strong on the last point. The first five are the work.

---

## P2. Current strengths that must not regress

Record these before changing anything. They are the baseline and the moat.

- HTTP/1.1, HTTP/2, HTTP/3/QUIC, WebSocket, WebTransport helpers, RFC 8441
  tunnels, RFC 10008 `QUERY`, and a transport-neutral handler boundary.
- 517/517 Autobahn server cases accepted, h1spec, HTTP/2 and HTTP/3
  cross-implementation gates, fuzzing, sanitizers, and a 1,300-test suite.
- One startup slab, no request-path allocation, bounded write queues,
  `WouldBlock`/`drain` backpressure, and explicit structured rejections.
- Shared-nothing cluster workers with per-worker loops, slabs, TLS contexts,
  and lock-free rings.
- BoringSSL TLS 1.3, mTLS, ALPN, 0-RTT policy, ephemeral certificates, kTLS
  helper, and a versioned C ABI.
- Benchmarks with archived evidence: HTTP throughput regression contract and
  HTTP/2-over-TLS scaling records.

Any proposal that trades one of these away needs an ADR with measured evidence.

### Recorded baseline at the time of writing

| Item | Value | Source |
| --- | --- | --- |
| Release | 2.1.6 | `src/version.zig`, `CHANGELOG.md` |
| Toolchain | Zig 0.16.0 | `build.zig.zon` |
| libxev pin | `c49f6dfb83038c146232472c063e4b2681d098d8` | `build.zig.zon` |
| Default slab for `ServerConfig{}` | `683_382_400` bytes for 1,024 connections | `src/tests/config_tests.zig` |
| Reserved per connection (before router subtraction) | about 651 KiB, lazily touched | derived from the slab total; not RSS |
| HTTP/2 streams per connection | 8 | `src/core/tcp.zig`, `src/http2/server.zig` |
| Test count | about 1,300 `test` declarations | `src/tests/` |
| Windows runtime claim | compile plus CI job; official support gated on a green release run | `README.md`, `docs/roadmap.md` |
| H1 throughput evidence | relative regression contract, not an absolute capacity claim | `benchmarks/http_throughput_guarantee.md` |
| H2/TLS scaling evidence | 276,534.80 req/s at 1,024 connections/1 stream; 669,300.80 at 8 streams, 4 workers | `benchmarks/results/h2_tls_scaling_v1/2026_10_19/README.md` |
| Application modules | None shipped; SQL/S3/jobs/cache/sessions/JWT/proto/tracing planned | `TODO.md` Section 17 |

Do not edit this table by hand after a release. Re-measure and update it with
the benchmark record link.

---

## P3. Executive summary of gaps

| ID | Gap | Priority | Milestone | Primary risk if ignored |
| --- | --- | --- | --- | --- |
| WS-1 | libxev types leak through the application and test surface | P0 | M1-M2 | Engine lock-in, brittle tests, backend quirks spread across modules |
| WS-2 | No measured bytes per idle connection; HTTP/2 storage is paid by every connection | P0 | M3 | Poor density story for WebSocket/HTTP1 deployments; surprises at 10k connections |
| WS-3 | Heavy default build and dependency graph | P1 | M4 | Slow first build, Nix requirement, adoption barrier |
| WS-4 | No docs site or generated API reference; onboarding is heavy | P1 | M4 | Users cannot evaluate or adopt quickly |
| WS-5 | No enforced four-axis quality budget | P1 | M0-M4 | Regressions ship silently; claims are not credible |
| WS-6 | Windows runtime support still gated on CI evidence | P2 | M5 | Platform claim remains incomplete |
| WS-7 | Zig 0.17 not supported | P1 (later) | M7 | Toolchain isolation; ecosystem moves ahead |
| WS-8 | Client is HTTP/1.1 only and one request per connection | P2 | M6 | Missing half of a framework; no WebSocket client |
| WS-9 | Handlers have no safe I/O model; request bodies are fully buffered | P2 | M8 | Blocking calls stall the loop; large uploads capped |
| WS-10 | Handler API is manual; no optional typed extraction layer | P3 | M9 | DX gap versus Dusty/nilo |
| WS-11 | Full-stack modules are absent: SQL, S3, jobs, cache, sessions, JWT, proto, metrics, tracing | P1 | M10-M18 | Users must bring every application primitive themselves; nilo/Dusty look more complete |
| FS-0 | No module lifecycle or feature-gate foundation for per-worker services | P1 | M10 | Every module invents its own start/stop and dependency path |
| FS-1..FS-10 | Individual module gaps and integration contracts | P1-P2 | M11-M18 | See Part II P15 for the per-module design and acceptance evidence |

Priority meanings:

- **P0**: Do first. Blocks credible framework positioning.
- **P1**: Do before the next minor release that claims framework quality.
- **P2**: Important, but can follow the core architecture work.
- **P3**: Optional or ecosystem work; do not let it delay P0/P1.

---

## P4. How an agent or maintainer should use this document

### P4.1 Before starting

1. Read `AGENTS.md`, `CODING_CONVENTION.md`, and `docs/dependency_forks.md`.
2. If `graphify-out/graph.json` exists, run `graphify query "<question>"`
   before grepping or reading source for a codebase question.
3. Read the workstream, its evidence links, and every referenced file.
4. Confirm the current baseline numbers before starting. See Part II P9
   (quality budget), Part II P18 (global gates), and the committed benchmark
   records. Do not start a performance or memory change without a recorded
   baseline.
5. Create a branch named after the workstream, for example
   `ws-1-engine-seam` or `ws-2-idle-memory`.

### P4.2 While working

- Keep changes small and land them in reviewable slices.
- Add the test before or with the implementation. Prove behavior, not intent.
- Update `CHANGELOG.md`, the relevant `docs/*.md`, and an ADR when a decision
  changes.
- Do not mark a checkbox complete without an evidence artifact: test name,
  command output, benchmark record, CI run URL, or a committed document.
- Do not edit vendored skills or upstream fetch-only repositories.
- After changing code, run `graphify update .` so the knowledge graph stays
  current.

### P4.3 Before declaring a workstream complete

Run the global gates in Part II P18. For a task that cannot run locally (Windows
CI, hosted benchmark), link the run and state exactly what it proves.

### P4.4 Status legend

- `[ ]` not started
- `[~]` in progress
- `[x]` complete with evidence
- `[!]` blocked, with a written reason and next action
- `[-]` deliberately deferred, with an ADR or policy reference

### P4.5 Suggested agent assignment

Use the project agent team in `.opencode/agents/` and `.codex/agents/`. Keep the
root agent responsible for scope, decisions, and the final report.

| Workstream | Lead | Review | Notes |
| --- | --- | --- | --- |
| WS-1 Engine seam | `transport_io` | `reviewer`, `dx_router` | Keep edits to shared app files serialized |
| WS-2 Idle memory | `transport_io`, `verification` | `reviewer`, `http_protocol` | Measurement harness first |
| WS-3 Lite build | `build_vendor` | `reviewer` | Build graph and feature matrix |
| WS-4 Docs/DX | `dx_router` | `reviewer`, `verification` | No Python/Node build dependency |
| WS-5 Budget | `verification` | `reviewer`, `build_vendor` | Allocations, memory, binary, p99 |
| WS-6 Windows | `transport_io` | `verification` | Native CI evidence required |
| WS-7 Zig 0.17 | `build_vendor` | `transport_io`, `reviewer` | Fork branch and pin audit |
| WS-8 Client | `developer` | `http_protocol`, `ws_protocol` | Phase C1/C2 first |
| WS-9 Handler I/O | `transport_io`, `dx_router` | `http_protocol`, `reviewer` | ADR before implementation |
| WS-10 Typed API | `dx_router` | `reviewer` | Spike only until adopted |
| WS-11 Module program | `dx_router`, `developer` | `reviewer`, `verification`, `crypto_tls` | FS-0 first; one module per PR; feature gates and allocation evidence required |
| FS-1 SQL | `developer` | `http_protocol`, `crypto_tls`, `verification` | Wire protocol, TLS, pool bounds |
| FS-2 S3 | `developer` | `crypto_tls`, `http_protocol` | SigV4, SSRF, streaming |
| FS-3 Jobs | `dx_router` | `verification` | SQL lease semantics |
| FS-4 Cache | `dx_router` | `verification` | No allocation, eviction |
| FS-5 Sessions / FS-6 JWT | `crypto_tls`, `dx_router` | `verification`, `reviewer` | AEAD, key rotation, alg confusion |
| FS-7 Proto | `http_protocol` | `verification` | Canonical vectors |
| FS-8 Metrics / FS-9 Tracing | `verification` | `dx_router`, `transport_io` | Cardinality, redaction, export |

Phase discipline: architect produces the scoped plan and acceptance criteria;
developer implements one slice; reviewer independently checks the diff and
evidence; integrator resolves overlaps and checks the combined result. Do not
advance past a phase while its output is missing.

---

## P5. WS-1: Make libxev an implementation detail, not the application API

**Priority:** P0  
**Milestone:** M1 (phase 1), M2 (phase 2)  
**Status:** `[ ]`  
**Owner:** transport/runtime + app/API

### P5.1 Problem

libxev is allowed to be the engine. It is not allowed to be the framework's
public shape. Today it leaks into nearly every layer:

- `TcpConnection` embeds `*xev.Loop`, `xev.TCP`, and five `xev.Completion`
  fields (`src/core/tcp.zig`, around the connection struct and
  `read_completion`, `write_completion`, `close_completion`,
  `read_cancel_completion`, `write_cancel_completion`).
- The listener path embeds `xev.Completion` for accept, cancel, retry, and
  close (`src/core/tcp.zig`, listener struct).
- `src/core/loop.zig` exposes `get_xev_loop()` and returns `*xev.Loop` to
  transport integrations.
- `src/router/app.zig` stores `xev.Async` and `xev.Completion` for cluster
  wakeup, calls `get_xev_loop()` for the file watcher, and passes
  `&self.loop.xev_loop` into connection setup.
- `src/client/connection.zig` embeds `*xev.Loop`, `xev.TCP`, and the same
  completion/cancel pattern.
- `src/observability/file_watch.zig` embeds `*xev.Loop`, `xev.Timer`,
  `xev.Completion`, and `xev.File`.
- Tests such as `src/tests/xev_tests.zig` and `src/tests/router_tests.zig`
  name xev directly.
- `src/core/xev.zig` is a shim, but it re-exports libxev types rather than
  defining a contract. It is a compatibility layer, not an engine seam.

This has three costs:

1. A future engine swap, or even a test fake, requires touching the transport,
   app, client, observability, and tests.
2. Backend-specific behavior (`cancel_abandons_target()`,
   `submit_before_cancel()`, `is_kqueue()`, ring retry policy) is spread across
   call sites instead of being owned by one adapter.
3. The public/test surface teaches users libxev concepts even when they only
   want `Request`/`Response`.

### P5.2 Goal and definition of done

One internal engine module owns libxev. Application, router, client,
observability, and tests use engine-neutral types. libxev remains the only
implementation. The hot path does not gain a virtual dispatch or an allocation.

Definition of done:

- Exactly one production source file imports `xev_impl` /
  `@import("xev")`: the libxev adapter.
- `src/router/`, `src/client/`, `src/observability/`, and `src/tests/` contain
  no `xev.` symbols and no `*xev.Loop`.
- The adapter owns backend selection, fallback, cancellation semantics, and
  Windows/IOCP workarounds.
- A compile-time or shell check fails if the boundary is violated.
- All protocol tests pass; throughput is within 2 percent of the recorded
  baseline; binary size grows by no more than 1 percent.

### P5.3 Proposed design

Do not build a fully generic completion framework. That would add complexity
and likely a hot-path cost. Build a **narrow engine capability interface** that
matches what the server actually uses.

Recommended shape:

- `src/core/engine.zig` defines the contract:
  - `Loop`: opaque handle with `init`, `deinit`, `run`, `request_stop`.
  - `Completion`: opaque, fixed-size, alignment-checked slot.
  - `CallbackAction`: `disarm` / `rearm`.
  - `Backend`: `io_uring` / `epoll` / `kqueue` / `iocp`, for runtime selection
    reporting only.
  - Operations: `accept`, `read`, `write`, `connect`, `close`, `shutdown`,
    `timer`, `cancel`, `wakeup`, `file_poll`, `udp_send`, `udp_recv`.
  - Cancellation policy: `cancel_abandons_target()` and
    `submit_before_cancel()` live in the adapter and are not exposed to callers
    unless a caller genuinely needs the distinction.
  - A documented `CompletionState` query for the close path, so Windows queued
    close logic is not duplicated.
- `src/core/engine/libxev.zig` is the only file that imports `xev_impl`. It may
  use `@import("xev")` only through the build shim.
- `src/core/xev.zig` is either deleted or reduced to a compatibility re-export
  for the adapter. Do not keep two competing seams.
- `src/core/loop.zig` becomes the public engine-neutral wrapper:
  - `pub fn init()`, `deinit`, `run`, `request_stop`, `backend`.
  - No `get_xev_loop()`.
  - Transport integration receives `*engine.Loop`, not `*xev.Loop`.
- `TcpConnection` uses `engine.Completion` and `engine.Socket` instead of
  `xev.Completion` and `xev.TCP`.
- `app.zig` uses `engine.Async` or `engine.Wakeup` for cluster wakeup, and
  `engine.FilePoll` for the file watcher.
- Tests either use the real libxev adapter or a small deterministic fake
  engine. A fake is optional for phase 1; the boundary check is mandatory.

Why this shape:

- It keeps the completion model, which is the project's performance advantage.
- It hides libxev types without forcing an async/fiber rewrite.
- It concentrates backend quirks in one file.
- It is reversible: the adapter can later host another completion engine, or a
  future std.Io/zio bridge, without changing application code.

### P5.4 Implementation steps

#### Phase 1: loop, timer, wakeup, selection

- [ ] Inventory every `xev.` reference:
  ```sh
  rg -n 'xev\.|@import\("xev"\)' src builds tests examples
  ```
  Record the count and file list in the workstream PR description.
- [ ] Define `src/core/engine.zig` with opaque `Loop`, `Completion`,
  `Socket`, `Timer`, `Wakeup`, `FilePoll`, and `CallbackAction`.
- [ ] Update `builds/targets/native.zig` so the `xev`/engine module's root is
  the adapter (`src/core/engine/libxev.zig`) and it receives the `xev_impl`
  dependency. Do not leave the old `src/core/xev.zig` shim as the module root.
- [ ] Move backend detection, `detect`, `prefer`, dynamic union dispatch, ring
  retry policy, and thread-pool ownership into
  `src/core/engine/libxev.zig`.
- [ ] Keep `ring_retry_decision` behavior and tests. Add a table-driven test
  for every backend/error combination.
- [ ] Convert `src/core/loop.zig` to engine-neutral `Loop`.
- [ ] Remove `get_xev_loop()`.
- [ ] Convert timer scheduler creation and cluster wakeup (`xev.Async`) to the
  engine interface.
- [ ] Add `scripts/check_engine_seam.sh`:
  ```sh
  # Fail if production code outside the adapter imports xev directly.
  rg -n '@import\("xev"\)|@import\("xev_impl"\)' src \
    --glob '!src/core/engine/libxev.zig' && exit 1
  # Fail if app/router/client/observability/tests name xev symbols.
  rg -n '\bxev\.' src/router src/client src/observability src/tests && exit 1
  exit 0
  ```
  Wire it into `zig build test` or the lint workflow.
- [ ] Add an ADR: `docs/adr/0008-engine-seam.md` describing the contract,
  why libxev stays, and what is deliberately not abstracted.

#### Phase 2: TCP, UDP/QUIC, client, observability

- [ ] Convert `TcpConnection` fields to `engine.Completion`, `engine.Socket`,
  and `*engine.Loop`.
- [ ] Convert listener accept/cancel/retry/close completions.
- [ ] Convert read/write/close/cancel paths in `src/core/tcp.zig`.
- [ ] Convert `src/core/tcp_file.zig` descriptor access.
- [ ] Convert `src/core/udp.zig` and the QUIC transport integration.
- [ ] Convert `src/client/connection.zig` and `src/client/client.zig`.
- [ ] Convert `src/observability/file_watch.zig` poll/timer/cancel.
- [ ] Convert `src/core/signal.zig` only where it names loop types; keep the
  self-pipe/console-control implementation.
- [ ] Convert tests that name xev. Prefer behavior tests over completion-state
  tests; keep the state tests that protect close ordering.
- [ ] Add compile-time assertions:
  ```zig
  comptime {
      assert(@sizeOf(engine.Completion) == @sizeOf(xev.Completion));
      assert(@alignOf(engine.Completion) == @alignOf(xev.Completion));
  }
  ```
  Keep these in the adapter, not in application code.
- [ ] Run the full matrix:
  ```sh
  zig fmt src builds examples tests fuzz
  sh scripts/check_conventions.sh
  zig build test
  zig build test -Dsanitize=true -Doptimize=ReleaseSafe
  zig build test-compile -Doptimize=ReleaseSafe
  ```
- [ ] Run the HTTP throughput contract and compare against the baseline.
- [ ] Run H2/TLS scaling and WebSocket smoke tests.

### P5.5 Acceptance criteria

- `rg -l '@import\("xev"\)' src` returns only the adapter.
- `rg '\bxev\.' src/router src/client src/observability src/tests` returns
  nothing.
- No `get_xev_loop()` remains.
- All tests, sanitizers, conformance suites, and benchmarks pass.
- Throughput regression is at most 2 percent; binary growth is at most 1
  percent; p99 does not regress by more than the benchmark noise threshold.
- The adapter is the only place that knows about kqueue/epoll/io_uring/IOCP
  differences.
- The ADR and `docs/architecture.md` describe the seam.

### P5.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Opaque completion size/alignment differs on Windows | Compile-time assertions for every target; Windows CI; keep the slot a wrapper around the native type, not a byte blob |
| Inline wrapper adds overhead | Use inline functions and compile-time backend selection; no vtable on the hot path; benchmark |
| Dynamic backend fallback becomes harder to reason about | Keep selection in the adapter; expose `backend()` for logs/tests; add a state-machine test |
| Tests become too abstract | Keep behavior tests; allow a test-only adapter that wraps the real libxev |
| Scope explosion | Phase 1 is loop/timer/wakeup only; TCP and client follow only after phase 1 is green |

### P5.7 References

- `src/core/xev.zig`
- `src/core/loop.zig`
- `src/core/tcp.zig` (connection and listener completion fields)
- `src/router/app.zig` (cluster wakeup, file watcher, listener setup)
- `src/client/connection.zig`
- `src/observability/file_watch.zig`
- `src/tests/xev_tests.zig`, `src/tests/router_tests.zig`
- `docs/architecture.md`
- `docs/dependency_forks.md`
- nilo's Bulkhead design:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/engine.md> and
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/001-zio-as-the-engine-behind-the-bulkhead.md>
- Dusty's `std.Io` deployment model:
  <https://lalinsky.github.io/dusty/server/deployment/>

---

## P6. WS-2: Measure and reduce bytes per idle connection

**Priority:** P0  
**Milestone:** M3  
**Status:** `[ ]`  
**Owner:** transport + memory + verification

### P6.1 Problem

The project publishes slab bytes, not resident bytes per idle connection. Those
are different numbers.

Evidence:

- `ServerConfig{}` plans `683_382_400` bytes for the default 1,024
  connections. That is about 651 KiB reserved per configured connection before
  subtracting the router region. See `src/tests/config_tests.zig` around the
  "default slab carries the router region at the end" test.
- `docs/memory_model.md` says the embedded eight-stream HTTP/2 session
  dominates the per-connection footprint.
- `TcpConnection` embeds `Http2Session` by value, and every connection carves
  `h2_session_stride` storage. A WebSocket-only or HTTP/1.1-only deployment
  still pays for HTTP/2 capacity.
- The kqueue investigation notes that RSS rises with "lazily touched pages of
  the fixed slab". That is the correct model: reserved is not resident. But the
  project has no published idle RSS number to compare with competitors.

External reference points:

- nilo publishes 4,669 bytes per idle HTTP/1.1 connection and 5,183 bytes per
  idle WebSocket, measured to 10,000 connections, with marginal cost flat
  within about 20 bytes of average. See nilo ADR 062 and
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/memory.md>.
- Dusty does not publish a single idle-connection number in its README, but its
  model is lighter by construction: no fixed HTTP/2 session storage, and its
  default `std.Io.Threaded` is replaced by zio coroutines in production.
  See <https://lalinsky.github.io/dusty/server/deployment/>.

This does not prove µWebZockets is worse. It proves the claim is unmeasured.

### P6.2 Goal and definition of done

Publish a reproducible bytes-per-idle-connection number for:

- HTTP/1.1 keep-alive
- WebSocket
- HTTP/2 (for completeness)

at 1,000 and 10,000 connections, with warmup, multiple samples, baseline
subtraction, and marginal-vs-average analysis. Then reduce the WebSocket and
HTTP/1.1 cost by making HTTP/2 storage optional.

Definition of done:

- A new benchmark harness records the numbers in a committed JSON/README.
- `docs/memory_model.md` states the measured floor for HTTP/1.1 and WebSocket.
- A WebSocket-only preset or build does not reserve the full eight-stream
  HTTP/2 session per connection.
- HTTP/2 remains available in the default build.
- No request-path allocation is introduced.
- Throughput regression is at most 2 percent for the affected presets.

### P6.3 Proposed solution

Do it in this order.

#### Step 1: Build the measurement harness first

Do not change memory layout before you can measure it.

- Add `benchmarks/idle_memory.zig` (a Zig client) or a small shell/Zig wrapper
  that:
  1. Starts a benchmark server with a `/health` route and a WebSocket route.
  2. Records baseline RSS after startup and warmup.
  3. Opens `N` idle keep-alive HTTP/1.1 connections, or `N` WebSocket
     connections.
  4. Holds them idle for a fixed period.
  5. Reads server RSS from `/proc/<pid>/status` or `smaps_rollup` on Linux.
  6. Repeats at 1,000 and 10,000 connections, with at least 5 samples.
  7. Records `(rss_after - rss_baseline) / N`, marginal cost between connection
     levels, and the full sample set.
- On macOS, use `footprint -p <pid>` or `vmmap`; document the difference.
- Add `scripts/benchmark_idle_memory.sh` as the stable entry point.
- Add a nightly workflow or a manual dispatch job. Do not make a noisy shared
  runner a hard gate at first; publish the number and compare trends.
- Record the pre-change baseline in the workstream before any optimization.

Acceptance for Step 1:

- The harness reproduces the same order of magnitude across two runs.
- It distinguishes reserved slab from resident RSS.
- It reports HTTP/1.1, WebSocket, and HTTP/2 separately.
- It stores raw evidence, not only a summary.

#### Step 2: Add an HTTP/2 storage toggle

There are two independent things to control:

1. **Runtime memory:** whether a connection carves and initializes the HTTP/2
   session storage.
2. **Compile-time code:** whether HTTP/2 code is linked into the binary.

Start with runtime memory; it is lower risk.

Proposed API:

- Add `ServerConfig.http2: bool = true`.
- When `false`:
  - `h2_session_bytes()` returns 0.
  - `layout_offsets` skips the H2 region.
  - `App` initializes the connection's H2 storage as an empty slice.
  - `TcpConnection.reset_protocol()` does not call `h2.reset()`.
  - Protocol detection rejects the HTTP/2 client preface and does not
    negotiate `h2` over ALPN.
  - The rejection is explicit and documented. Do not silently fall back to
    HTTP/1.1 after an h2 preface.
- Add a new preset, for example `Presets.websocket_only`, rather than changing
  `Presets.websocket_chat` semantics. The new preset sets `http2 = false`
  and sizes buffers for chat.
- Keep the default `true` until the memory number and compatibility tests are
  green.

Then, if binary size matters:

- Add a build option `-Dhttp2=false` that eliminates HTTP/2 code paths at
  compile time. This likely requires a comptime `include_http2` parameter in
  the connection/app type or a separate connection type. Do it only after the
  runtime toggle is stable.
- Measure binary size and compile time; update the budget.

#### Step 3: Reduce or defer H2 capacity where it is still enabled

If a deployment needs HTTP/2 but not eight streams of 16 KiB bodies:

- Make `max_http2_streams` configurable through connection-type
  specialization (already on the roadmap).
- Add presets that lower `max_h2_body_size`, `max_h2_header_block_size`, and
  response header storage.
- Document the exact cost of each knob.

#### Step 4: Only if needed, release idle buffers

If the measured idle RSS is still high after H2 is optional, consider:

- A per-worker buffer pool that returns request/write/WS buffers when a
  connection idles, with bounded reacquisition.
- `madvise(MADV_DONTNEED)` on per-connection regions at idle, if the slab
  layout makes it safe and the measurement proves a win.
- A separate "idle connection" representation that keeps only the socket,
  parser state, and timer, and restores buffers on the next request.

These are larger changes. Do not start them without the harness showing that
buffers, not connection state or H2 storage, are the dominant cost.

### P6.4 Implementation steps

- [ ] Build the idle-memory harness and record the baseline.
- [ ] Publish the baseline in `docs/memory_model.md` and the benchmark record.
- [ ] Add `ServerConfig.http2` runtime toggle.
- [ ] Add `Presets.websocket_only` or equivalent.
- [ ] Make `h2_session_bytes()` and `layout_offsets` honor the toggle.
- [ ] Make `TcpConnection.reset_protocol()` skip H2 initialization when
      disabled.
- [ ] Reject h2 preface/ALPN explicitly when disabled.
- [ ] Add tests for enabled/disabled behavior.
- [ ] Re-measure at 1,000 and 10,000 connections.
- [ ] Add a `-Dhttp2=false` compile-time option if binary size justifies it.
- [ ] Add configurable HTTP/2 stream counts if the preset still needs HTTP/2.
- [ ] Update `docs/memory_model.md`, `docs/deployment.md`, `README.md`, and
      `Presets` docs.
- [ ] Add the idle-memory number to the release checklist.

### P6.5 Acceptance criteria

- `docs/memory_model.md` contains a measured bytes-per-idle-connection table
  for HTTP/1.1 and WebSocket at 1k and 10k, with raw evidence links.
- A WebSocket-only preset does not reserve the full H2 session storage.
- The default build still serves HTTP/2 and passes all H2 tests.
- The disabled build rejects HTTP/2 clearly and does not crash or silently
  downgrade.
- No request-path allocation is added.
- The benchmark record shows no throughput regression above 2 percent for the
  affected presets.
- The number is reproducible from a clean checkout.

### P6.6 Target numbers

Do not treat these as gates until the baseline is measured. They are direction.

- **Stretch:** under 16 KiB resident per idle HTTP/1.1 connection and under
  20 KiB per idle WebSocket, excluding TLS handshake state.
- **Competitive reference:** nilo is 4,669 bytes HTTP/1.1 and 5,183 bytes
  WebSocket, without TLS. Matching that exactly is not required; being within
  a small multiple is credible.
- **Red flag:** more than 64 KiB resident per idle connection in a
  WebSocket-only deployment. That is a product problem, not a benchmark
  detail.

### P6.7 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Disabling HTTP/2 silently changes behavior | Explicit rejection, tests, docs, separate preset |
| The H2 type is embedded and hard to remove | Start with runtime storage skip; defer compile-time elimination |
| Memory harness is noisy | Multiple samples, baseline subtraction, nightly/dedicated runner, report-only first |
| Idle buffer release breaks zero-allocation | Keep the slab; return pages only if measured; reacquisition must be bounded and non-allocating |
| Preset changes break existing users | Add a new preset; do not change existing semantics without a major release |

### P6.8 References

- `src/router/config.zig` (defaults, `h2_session_bytes`, `layout_offsets`,
  `Presets`)
- `src/http2/server.zig` (`Capacities`, `Storage`, `storage_bytes`)
- `src/core/tcp.zig` (`TcpConnection`, `h2`, `reset_protocol`)
- `docs/memory_model.md`
- `src/tests/config_tests.zig` (default slab total, H2 storage tests)
- nilo memory design:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/memory.md>
- nilo ADR 062:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/062-where-a-connection-waits-is-what-it-costs.md>
- nilo ADR 017:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/017-the-trade-budget-has-four-axes.md>

---

## P7. WS-3: Reduce default build and dependency weight

**Priority:** P1  
**Milestone:** M4  
**Status:** `[ ]`  
**Owner:** build/vendor

### P7.1 Problem

The default build is heavy for a first-time user:

- `builds/targets/native.zig` always configures and links BoringSSL, lsquic,
  libdeflate, and zlib, plus the libxev fork.
- `build.zig.zon` always fetches every dependency, even if a program never uses
  HTTP/3 or TLS.
- The README recommends Nix as the shortest path, which raises the barrier for
  a Zig developer who just wants `zig build`.
- Dusty's first build is much lighter, and its dependency list is a
  differentiator. nilo is modular and lets a program avoid SQL/S3 if unused.

### P7.2 Goal and definition of done

Add opt-in feature flags so a plain HTTP/1.1 + WebSocket build does not compile
or link BoringSSL/lsquic. Keep the default full build.

Definition of done:

- `zig build -Dminimal` (or equivalent) builds and tests HTTP/1.1, WebSocket,
  router, static files, and JSON-RPC without BoringSSL or lsquic.
- The full build remains the default and still passes.
- `zig build lib` remains full-featured and keeps the C ABI.
- Build time and binary size for the minimal configuration are measured and
  documented.
- No build-time Python/CMake/Ninja/Go/Perl requirement.

### P7.3 Proposed solution

Add a feature matrix, not a single boolean.

Suggested options:

- `-Dtls=false` — omit BoringSSL and TLS/HTTPS initializers.
- `-Dhttp3=false` — omit lsquic, QPACK, QUIC transport, HTTP/3, WebTransport.
- `-Dcompression=false` — omit libdeflate/zlib and gzip/WS compression.
- `-Dclient=false` — omit the outbound HTTP client.
- `-Dc_api=false` — omit the C ABI static library.
- `-Dminimal=true` — convenience preset that disables the above except what
  HTTP/1.1 + WebSocket need.

Implementation notes:

- Introduce `build_options` into the `uWebZockets` module.
- Guard imports with `if (build_options.tls)` so the linker never sees the
  dependency when disabled. Do not rely on dead-code elimination alone.
- Make `builds/vendor/root.zig` conditionally configure and link each
  dependency.
- Keep the C ABI full-only. A minimal C ABI is a separate product.
- Because `build.zig.zon` still fetches all dependencies, document that
  `-Dminimal` reduces compile/link time and binary size, not initial fetch
  size. If fetch size matters, plan a separate `uWebZockets-lite` package with
  its own manifest. Do not pretend a feature flag removes the fetch.
- Add a CI matrix: full, minimal, minimal+tls, minimal+http3, and at least one
  sanitizer combination. Do not test every combination; test the boundaries.

### P7.4 Implementation steps

- [ ] Add build options and a `build_options` module.
- [ ] Add compile-time guards in `src/root.zig` and the dependency-owning
      modules.
- [ ] Make vendor configuration conditional.
- [ ] Add `-Dminimal` preset.
- [ ] Add tests/examples for the minimal configuration.
- [ ] Measure build time and stripped binary size for full vs minimal.
- [ ] Add a CI matrix job.
- [ ] Document the matrix in `docs/operations.md` and `README.md`.
- [ ] Add a `docs/adr/0009-build-feature-matrix.md`.
- [ ] Decide later whether a separate lite package is worth the release
      overhead.

### P7.5 Acceptance criteria

- `zig build -Dminimal` passes the HTTP/1.1 + WebSocket test subset.
- `nm`/`ldd` or a link map shows no BoringSSL/lsquic symbols in the minimal
  binary.
- Full build and C ABI unchanged.
- Build time and binary size improvements are recorded.
- Documentation states exactly what is omitted and what is not.

### P7.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Combinatorial CI explosion | Test representative boundaries, not all combinations |
| Conditional imports create untested dead code | Compile and run each supported configuration in CI |
| C ABI breaks in minimal mode | Keep C ABI full-only and document it |
| Dependency fetch still heavy | Document the distinction; plan a lite package only if users ask |
| Feature flags weaken the zero-allocation guarantee | Each configuration must keep the same allocation rules and tests |

### P7.7 References

- `build.zig`
- `builds/targets/native.zig`
- `builds/vendor/root.zig`
- `build.zig.zon`
- `scripts/check_package_paths.sh`
- `scripts/check_static_archive.sh`
- `docs/operations.md`
- Dusty README and build options:
  <https://github.com/lalinsky/dusty>
  <https://lalinsky.github.io/dusty/build-options/>

---

## P8. WS-4: Documentation site, API reference, and first-run experience

**Priority:** P1  
**Milestone:** M4  
**Status:** `[ ]`  
**Owner:** DX/docs

### P8.1 Problem

The repository has substantial Markdown documentation and examples, but:

- There is no docs site and no generated API reference.
- The shortest path in the README requires Nix.
- A new user must understand capacities, slabs, TLS initializers, and the
  cluster model before running a trivial server.
- Dusty has a docs site, an API reference, and a very small first example.
  nilo has a guide, design pages, reference pages, and ADRs for almost every
  decision.
- The handler API is manual (`fn (*Request, *Response) void`) and there is no
  typed extraction layer to make examples as short as Dusty's or nilo's.

### P8.2 Goal and definition of done

A new user can go from a clean machine with Zig installed to a running,
tested server without Nix, in one page. The API reference is generated from
the source. The docs site is built by Zig, not by a new Python/Node toolchain.

Definition of done:

- `zig build docs` produces a browsable site and API reference.
- `docs/getting_started.md` has a "no Nix" path that CI tests.
- Every public type and function has a doc comment that survives generation.
- Five recipes are runnable and covered by compile tests.
- `scripts/check_docs.sh` checks links, snippets, and generated output.
- No Python/MkDocs/Node requirement is added to `zig build`.

### P8.3 Proposed solution

#### Docs site

- Use Zig's built-in documentation generation for the API reference if the
  pinned toolchain supports it. Otherwise write a small Zig static-site
  generator under `builds/docs/`.
- Keep the source of truth in `docs/*.md`; generate the site into
  `zig-out/docs` or `docs/site/out` (gitignored).
- Add a GitHub Pages deployment workflow that runs `zig build docs`. The
  workflow may use a prebuilt Zig toolchain, but not a Python build dependency.
- Add a landing page with: what it is, what it is not, a 20-line server, a
  20-line WebSocket, and links to protocols, memory model, deployment, and
  C ABI.

#### First-run path

- Add `docs/quickstart.md` with:
  ```sh
  zig fetch --save 'git+https://github.com/farbenbuilds/uWebZockets#<tag>'
  # add the import to build.zig
  zig build run
  ```
- Remove the implication that Nix is required. Keep Nix as a reproducible
  development/CI path, not the only path.
- Add a `tests/package_consumer` scenario that follows the quickstart exactly
  and runs the server.
- Add a troubleshooting section for the top five first-run failures:
  dependency fetch, BoringSSL build, linker, port in use, TLS certificate.

#### API reference

- Add doc comments to every public declaration in `src/root.zig` and the
  modules it re-exports.
- Generate a reference index grouped by module: App, Request, Response,
  Router, Middleware, WebSocket, Client, TLS, RPC, OpenAPI, C ABI.
- Link every type to its protocol document.
- Add a "stability" marker: public, experimental, internal.

#### Recipes

Create `docs/recipes/` and `examples/recipes/` for:

1. Auth + session cookie (signed cookie, login/logout, protected route).
2. Database access with a community Postgres client (`pg.zig`) or SQLite.
3. Static SPA with fallback and cache headers.
4. WebSocket chat with rooms/topics and backpressure.
5. JSON-RPC service with typed procedures and OpenAPI.
6. Server-Sent Events and streaming responses.
7. Reverse proxy + TLS deployment (nginx/Caddy) and trusted proxy headers.

Each recipe must compile in CI. Live database recipes can skip if the service
is absent, but the compile test must run.

#### API ergonomics

Do not build a reflection-heavy typed framework. The project's convention is
named, explicit types. Add a small, optional, explicit extraction layer only
after a design spike:

- `Path(T)`, `Query(T)`, `Json(T)`, `Form(T)` wrappers where `T` explicitly
  implements a trait.
- No `@typeInfo`-driven handler generation.
- No `anytype` in the public API where the accepted types are known.
- Benchmark compile time and binary size before adopting.

This is WS-10, not a blocker for the docs milestone.

### P8.4 Implementation steps

- [ ] Add `zig build docs`.
- [ ] Add a docs landing page and navigation.
- [ ] Generate the API reference from source.
- [ ] Add the no-Nix quickstart.
- [ ] Add the package-consumer test for the quickstart.
- [ ] Add the seven recipes and compile tests.
- [ ] Extend `scripts/check_docs.sh` for links, snippets, and generated output.
- [ ] Add a GitHub Pages workflow.
- [ ] Add a "what µWebZockets is not" section to prevent wrong expectations.
- [ ] Add a comparison page that is factual and does not disparage competitors.

### P8.5 Acceptance criteria

- A clean machine with Zig 0.16 can build and run the quickstart server.
- `zig build docs` succeeds without Python/Node.
- The API reference covers every public declaration.
- All recipes compile; live-service recipes skip cleanly.
- The docs CI job is green.
- The README links to the site and the quickstart.

### P8.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Zig docs generation changes across versions | Keep the generator small; test it in CI; pin the toolchain |
| Adding a JS/static-site toolchain violates project rules | Use Zig-native generation; no Python/Node in `zig build` |
| Recipes rot | Compile tests in CI; pin dependency versions; review quarterly |
| Docs promise more than the code does | Every claim links to a test/benchmark or is marked as a boundary |

### P8.7 References

- `README.md`
- `docs/` (all pages)
- `docs/getting_started.md`
- `scripts/check_docs.sh`
- Dusty docs: <https://lalinsky.github.io/dusty/>
- nilo guide: <https://nevindra.github.io/nilo/latest/>
- nilo reference: <https://github.com/nevindra/nilo/blob/v0.8.0/docs/reference/README.md>

---

## P9. WS-5: Adopt a four-axis quality budget

**Priority:** P1  
**Milestone:** M0 (define), M4 (enforce)  
**Status:** `[ ]`  
**Owner:** verification + maintainer

### P9.1 Problem

The project has benchmarks and a memory model, but not a per-feature budget
that a reviewer can enforce. nilo's ADR 017 is the model:

- Throughput and p99: a nicer API may cost up to 10 percent, measured on a real
  machine.
- Allocations per request: hard invariant; no new allocation on a path that did
  not ask for it.
- Memory per idle connection: hard invariant; every feature states its cost.
- Binary size: disclosed and tracked, not silently grown.

µWebZockets currently has:

- A throughput regression contract for HTTP/1.1.
- H2/TLS scaling records.
- A config test that counts one application allocation.
- No request-path allocation gate across all routes.
- No idle-memory record.
- No binary-size record.
- No p99 gate or report.

### P9.2 Goal and definition of done

Add `docs/budget.md` or ADR 0009 with the four axes, then enforce what can be
enforced deterministically.

Definition of done:

- The budget document exists and is linked from `CONTRIBUTING`.
- A request-path allocation test covers HTTP/1.1, HTTP/2, and WebSocket steady
  state.
- An idle-memory benchmark records HTTP/1.1 and WebSocket at 1k and 10k.
- A binary-size check records stripped ReleaseFast sizes for the examples.
- Throughput/p99 reports are recorded per release; failures are investigated,
  not ignored.
- Every feature PR states its cost on all four axes.

### P9.3 Proposed budget

Start conservative and tighten after the baseline.

| Axis | Proposed rule | Where enforced |
| --- | --- | --- |
| Allocations per request | 0 in steady state for request/parse/route/write; explicit API allocations are documented | Unit test with counting allocator |
| Bytes per idle connection | Measured; no regression above 5 percent without an ADR; WebSocket-only target documented | Idle-memory harness, nightly |
| Throughput and p99 | No regression above 10 percent on the pinned benchmark; investigate above 5 percent | Benchmark workflow, release report |
| Binary size | Stripped ReleaseFast size recorded; no unexplained growth above 1 percent per feature | `scripts/check_binary_size.sh` |

Notes:

- Shared CI runners are noisy. Throughput/p99 should be report-only on PRs and
  a release gate on a dedicated runner or a pinned local cohort. Allocations,
  idle memory (with enough samples), and binary size are stable enough for
  hard gates.
- The budget is a floor, not a marketing claim. State the workload and the
  machine.
- Do not compare numbers across different runner cohorts. Record the cohort.

### P9.4 Implementation steps

- [ ] Write `docs/budget.md` and an ADR.
- [ ] Add `src/tests/allocation_tests.zig` with a counting allocator around a
      full request path for HTTP/1.1, HTTP/2, and WebSocket.
- [ ] Add `scripts/check_binary_size.sh` and a baseline JSON.
- [ ] Add idle-memory records to the benchmark history.
- [ ] Extend the benchmark workflow to record p99 and median.
- [ ] Add a release checklist item: "budget report reviewed."
- [ ] Add a PR template question: "What does this cost on the four axes?"
- [ ] Add a `docs/budget.md` table per feature, like nilo's running total.

### P9.5 Acceptance criteria

- A PR that adds an allocation to the request path fails a test.
- A PR that grows the binary above the threshold fails unless it updates the
  baseline with an ADR.
- The release report contains all four axes.
- The budget document is referenced from `CONTRIBUTING` and the PR template.

### P9.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Noisy performance gates block legitimate work | Make throughput/p99 report-only on shared runners; gate on a dedicated cohort |
| Binary-size gate is gamed by stripping more | Compare like-for-like stripped ReleaseFast, record the exact command |
| Allocation test misses a path | Cover H1, H2, WS, static, RPC, TLS handshake separately |
| Budget becomes bureaucracy | Keep it to four numbers and one table per feature |

### P9.7 References

- `benchmarks/http_throughput_guarantee.md`
- `benchmarks/h2_tls_scaling_guarantee.md`
- `scripts/benchmark_http.sh`
- `scripts/benchmark_h2_tls.sh`
- `src/tests/config_tests.zig` (CountingAllocator)
- nilo ADR 017:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/017-the-trade-budget-has-four-axes.md>
- nilo design principles:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/principles.md>

---

## P10. WS-6: Turn Windows runtime support into evidence

**Priority:** P2  
**Milestone:** M5  
**Status:** `[ ]`  
**Owner:** transport/runtime + CI

### P10.1 Problem

The README says Windows has a native compile and runtime job, and official
support is claimed only after that job is green for the release commit. The
roadmap still lists Windows runtime as gated. Dusty and nilo can point to a
portable `std.Io`/zio story; µWebZockets needs a green native run, not a
compile-only claim.

### P10.2 Goal and definition of done

The `windows-2025` runtime job runs the full test suite on the release commit,
and the release notes link the run.

Definition of done:

- `windows.yml` runs `zig build test --summary all` and
  `zig build test-compile -Doptimize=ReleaseSafe` successfully.
- No Windows test is skipped except a documented platform limitation.
- The IOCP accept and queued-close regressions have tests.
- README, roadmap, and ADR 0004 status are updated.
- The release checklist requires the Windows run URL.

### P10.3 Implementation steps

- [ ] Run the current `windows.yml` job and record every failure.
- [ ] Fix or quarantine each failure with an issue and a test.
- [ ] Verify the accept lifecycle and queued-close regression tests.
- [ ] Verify the TLS cluster tests use `getsockname`/`SO_RCVTIMEO` and do not
      skip.
- [ ] Pin the runner image for reproducibility.
- [ ] Add the run URL to the release checklist and changelog.
- [ ] Update README/roadmap/ADR 0004 from "gated" to "supported" only after a
      green release-commit run.

### P10.4 Acceptance criteria

- Green Windows runtime job for the release commit.
- No unexplained skips.
- No divergence between the Windows completion layout and the POSIX layout
      assumptions; compile-time assertions cover both.
- Release notes contain the evidence.

### P10.5 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Hosted runner flakiness | Pin image; retry with evidence; do not hide failures |
| IOCP completion width differs | Compile-time assertions; Windows-specific tests |
| Tests assume POSIX sockets | Use `ws2_32` helpers; audit tests |
| Claiming support too early | Require a green run before changing the README |

### P10.6 References

- `.github/workflows/windows.yml`
- `docs/roadmap.md` (Windows runtime blocker details)
- `docs/adr/0004-windows-iocp-accept-and-queued-close.md`
- `src/core/tcp.zig` (Windows branches)
- `src/core/signal.zig` (Windows console control)

---

## P11. WS-7: Zig 0.17 upgrade path

**Priority:** P1, scheduled after the core P0 work  
**Milestone:** M7  
**Status:** `[ ]`  
**Owner:** build/vendor + runtime + verification

### P11.1 Problem

The project pins Zig 0.16.0. Dusty already supports 0.16 and 0.17. The Zig
ecosystem will move; staying on 0.16 indefinitely narrows adoption and makes
every dependency upgrade harder. The libxev fork policy already anticipates an
`uwz/zig-0.17` branch.

### P11.2 Goal and definition of done

Support Zig 0.17 on a maintained libxev integration branch without breaking the
0.16 release line during the transition.

Definition of done:

- A new `farbenbuilds/libxev` branch `uwz/zig-0.17` exists, based on a
  compatible upstream commit, carrying the XEV patches that still apply.
- The pin is a full 40-hex commit, updated in all four zon views, the Nix
  hash, and the lock file.
- `minimum_zig_version` and the README state the supported range.
- CI runs 0.17 tests, sanitizers, h1spec, Autobahn, H2/H3 gates, and the
  package-consumer fixture.
- 0.16 remains green until the 0.17 release is proven; then publish a
  deprecation policy.

### P11.3 Implementation steps

- [ ] Read `docs/dependency_forks.md` and follow the sync/security review
      process.
- [ ] Create `uwz/zig-0.17` from the newest upstream commit compatible with
      Zig 0.17. Do not merge 0.17-only upstream into `uwz/zig-0.16`.
- [ ] Rebase/merge XEV-001 through XEV-005; drop or rewrite patches that 0.17
      made unnecessary.
- [ ] Run the full libxev test suite on Linux and macOS; add Windows evidence.
- [ ] Update `build.zig.zon` and all four views with a full commit and hashes.
- [ ] Update `flake.nix`, `flake.lock`, and the CI toolchain.
- [ ] Fix Zig 0.17 language/std changes across the project.
- [ ] Add a CI matrix for 0.16 and 0.17 during the transition.
- [ ] Update README, `CONTRIBUTING`, `docs/operations.md`, and the changelog.
- [ ] Publish an ADR for the toolchain transition and the fork branch.

### P11.4 Acceptance criteria

- 0.17 build/test/sanitizer/benchmark gates are green.
- 0.16 remains green during the overlap.
- The fork pin is on `uwz/zig-0.17`, not a branch or tag.
- The dependency policy checks pass.
- The release notes state the supported Zig versions and any deprecation date.

### P11.5 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| libxev fork diverges across Zig versions | Separate integration branches; never merge 0.17-only commits into 0.16 |
| Zig 0.17 std changes break `std.Io` usage | Isolate changes; run the full matrix; keep the 0.16 branch |
| Dependency hashes drift across four views | Use the existing update script and fork checks |
| C dependencies fail on 0.17 | Re-run native builds for BoringSSL/lsquic/zlib/libdeflate; pin toolchain |
| Users cannot upgrade | Document a support window and a migration guide |

### P11.6 References

- `build.zig.zon`
- `docs/dependency_forks.md` (the `uwz/zig-0.17` future row)
- `scripts/check_libxev_fork.sh`
- `scripts/update_zon_files.sh`
- `scripts/check_dependency_forks.sh`
- `flake.nix`, `flake.lock`
- `.github/workflows/test.yml`
- Zig 0.17 release notes (when available)

---

## P12. WS-8: Complete the client surface

**Priority:** P2  
**Milestone:** M6  
**Status:** `[ ]`  
**Owner:** client + protocol

### P12.1 Problem

The client is deliberately small: HTTP/1.1 only, one request per connection,
no DNS resolution, no redirects, no cookies, no proxy, no connection pooling,
no mTLS, and no HTTP/2/HTTP/3 or WebSocket client. `docs/roadmap.md` lists the
WebSocket client first.

Dusty has a full HTTP/1.1 client with pooling, HTTPS, Unix sockets, and a
WebSocket client. nilo has `nilo_fetch` with targets, deadlines, pools, and
S3 integration. For a framework, the client gap is visible.

### P12.2 Goal and definition of done

At minimum:

- WebSocket client over the existing transport.
- Keep-alive and bounded connection pooling for HTTP/1.1.
- DNS resolution through `std.Io` with a timeout.
- Documented redirect, cookie, proxy, and mTLS policy.

Optional later:

- HTTP/2 client.
- HTTP/3 client.
- WebSocket client compression.

Definition of done:

- Each phase has tests, docs, and a benchmark or a bounded-cost note.
- The plaintext request path remains allocation-free.
- No unbounded buffer growth; every response has a bound.
- The client can talk to the µWebZockets server and to a standard external
  server.

### P12.3 Implementation steps

#### Phase C1: WebSocket client

- [ ] Reuse the existing client transport and zslay client framing/masking.
- [ ] Add handshake, subprotocol negotiation, ping/pong, close, and
      fragmented messages.
- [ ] Add tests against the in-process server and a live loopback server.
- [ ] Document `docs/client.md`.

#### Phase C2: Keep-alive and pooling

- [ ] Add bounded connection reuse and idle timeouts.
- [ ] Add per-host pool limits and a queue with a deadline.
- [ ] Prove no request-path allocation.
- [ ] Benchmark against one-request-per-connection.

#### Phase C3: DNS

- [ ] Add hostname resolution through `std.Io` (or a bounded resolver).
- [ ] Add a resolution timeout and a numeric-address fast path.
- [ ] Document security and failure behavior.

#### Phase C4: Policy features

- [ ] Redirects with a bounded count and cross-origin rules.
- [ ] Cookie jar with bounded entries.
- [ ] Proxy support (HTTP CONNECT and/or SOCKS) if required.
- [ ] mTLS client certificates.
- [ ] Document every default and limit.

#### Phase C5: HTTP/2 client (optional)

- [ ] Reuse HPACK and frame code where safe.
- [ ] Add ALPN and multiplexing.
- [ ] Do not claim support until a cross-implementation gate exists.

### P12.4 Acceptance criteria

- C1 and C2 are complete before calling the client "framework-grade."
- All new paths are bounded and documented.
- `docs/client.md` and `README.md` reflect the actual limits.
- Tests cover timeouts, resets, partial reads, and close ordering.

### P12.5 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Scope creep turns the client into a second framework | Phase it; ship C1/C2 first; defer H2/H3 |
| Unbounded response buffering | Keep fixed capacities and `WouldBlock` |
| DNS/proxy security bugs | Fail closed; document trust; add tests |
| TLS allocation on every connection | Pool TLS sessions if needed; measure |

### P12.6 References

- `docs/client.md`
- `docs/roadmap.md` (near-term direction)
- `src/client/connection.zig`
- `src/client/client.zig`
- `src/client/http1.zig`
- Dusty client docs: <https://lalinsky.github.io/dusty/client/requests/>
- Dusty WebSocket client: <https://lalinsky.github.io/dusty/client/websocket/>

---

## P13. WS-9: Handler I/O model and incremental request bodies

**Priority:** P2  
**Milestone:** M8  
**Status:** `[ ]`  
**Owner:** app/API + transport

> Note: this is Part II P13 in the document outline and WS-9 in the workstream
> numbering. The global gates are Part II P18.

### P13.1 Problem

Handlers are synchronous `fn (*Request, *Response) void`. There is no standard
`std.Io` handle in `Request`, and no documented way to perform an outbound
network or database call without blocking the loop thread. `route_async` can
defer a response, but it does not give the handler a safe blocking/I/O model.

Request bodies are buffered up to `max_body_size`; large uploads cannot stream
past the cap. The roadmap lists both gaps:

- WebSocket client (client workstream)
- Incremental request bodies for HTTP/1.1
- Configurable HTTP/2 stream counts
- Handler I/O is not listed but follows from the same problem.

Dusty gives handlers `std.Io` and recommends zio for production; nilo has
`nilo.blocking`, `nilo.sleep`, and explicit deadlines. µWebZockets needs an
equivalent that works with libxev, not a migration to zio.

### P13.2 Goal and definition of done

A handler can:

- Perform a bounded blocking operation (database, file, external API) without
  stalling the event loop, using an explicit API.
- Stream a request body past `max_body_size` with bounded memory and
  backpressure.
- Use an `Io` handle that is engine-neutral and does not expose libxev.

Definition of done:

- `Request.io` or `HandlerContext.io` exists and is documented.
- A bounded blocking pool or `std.Io` offload path exists; it cannot grow
  unboundedly.
- A `BodyReader` streams request bodies with a fixed buffer and
  `error.WouldBlock`/read semantics.
- Examples and tests prove both.
- The zero-allocation steady-state rule is preserved for routes that do not
  use these features.

### P13.3 Proposed solution

#### Handler I/O

Option A: expose `std.Io` directly:

- Add `io: std.Io` to a new `HandlerContext` or to `Request` (prefer a context
  type; do not bloat `Request`).
- Document that the `Io` may be a thread-backed implementation and that
  blocking calls belong in `app.blocking`.
- Add `App.blocking` / `Cluster.blocking` with a fixed worker count, a bounded
  queue, a timeout, and a shutdown drain.
- `route_async` remains the way to complete a response from a worker; ensure
  the completion is thread-safe and generation-checked.

Option B: keep handlers synchronous and provide only a blocking pool:

- `app.blocking.run(fn, args)` blocks the handler thread; the loop must have a
  spare thread. This is simpler but does not help a single-threaded build.
- Document that `threads = 1` cannot use blocking calls without stalling.

Recommendation: Option A, with `HandlerContext` and an explicit
`app.blocking` pool. Keep `Request` lean.

#### Incremental request bodies

- Add a `BodyReader` with:
  - fixed buffer capacity,
  - `read`/`readAll`/`next` semantics,
  - a deadline per read,
  - `error.WouldBlock` only if the caller opts into nonblocking,
  - no unbounded accumulation.
- Wire it into HTTP/1.1 first; HTTP/2 already has stream flow control and can
  follow.
- Add a route option `body = .stream` or a separate registration API, so
  existing buffered routes keep their semantics.
- Add a hard cap and a minimum-rate deadline, like the existing body policy.
- Add tests for slowloris, partial reads, reset, and shutdown.

### P13.4 Implementation steps

- [ ] Write an ADR for handler I/O and body streaming.
- [ ] Add `HandlerContext` or an equivalent explicit context.
- [ ] Add a bounded blocking pool with lifecycle and shutdown.
- [ ] Add `route_async` documentation and a worker-completion example.
- [ ] Add `BodyReader` for HTTP/1.1.
- [ ] Add route registration for streaming bodies.
- [ ] Add HTTP/2 streaming body support if the protocol layer allows it.
- [ ] Add tests and a recipe.
- [ ] Update `docs/api.md`, `docs/http.md`, `docs/http2.md`, and
      `docs/roadmap.md`.

### P13.5 Acceptance criteria

- A handler can run a blocking call off-loop and complete a response.
- A large upload streams with bounded memory.
- Existing buffered routes are unchanged.
- No unbounded queue or allocation.
- Shutdown drains the blocking pool.
- The zero-allocation path is still tested.

### P13.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Thread pool grows unbounded | Fixed worker count and bounded queue |
| Lifetimes cross threads unsafely | Copy or own request data; generation-checked response token |
| Streaming bodies complicate backpressure | Fixed buffers, per-read deadlines, explicit `WouldBlock` |
| Behavior diverges across H1/H2 | Separate tests; document protocol differences |
| `std.Io` handle exposes too much | Provide a narrow interface; do not expose libxev |

### P13.7 References

- `docs/roadmap.md` (incremental request bodies, near-term direction)
- `docs/api.md` (handler registrations)
- `src/router/app.zig` (`route_async`, `AsyncResponse`)
- `src/http/response.zig` (`AsyncResponseState`, stream producers)
- `src/c_api/types.zig` (`std.Io.Threaded` usage)
- `docs/memory_model.md` (backpressure)
- Dusty deployment/Io model:
  <https://lalinsky.github.io/dusty/server/deployment/>
- nilo deadlines and blocking:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/deadlines.md>

---

## P14. WS-10: Optional explicit typed handler layer

**Priority:** P3  
**Milestone:** M9  
**Status:** `[-]` deferred until WS-9 is stable  
**Owner:** app/API

### P14.1 Problem

Dusty has typed extraction (`Param("name", T)`) and concise response helpers.
nilo has typed handlers, resolved values, and compile-time route metadata. The
µWebZockets handler is manual: `fn (*Request, *Response) void`, with helpers
for query, form, JSON, cookies, and parameters.

This is not a correctness gap. It is an ergonomics gap. It becomes worth
solving only if user research or examples show that the manual API is the main
adoption blocker.

### P14.2 Goal and definition of done

An optional, explicit typed layer that:

- Does not use `@typeInfo`-driven reflection or inline anonymous structs.
- Uses named traits such as `FromRequest` and `IntoResponse`.
- Keeps the existing handler API unchanged.
- Adds no steady-state allocation.
- Has a measured compile-time and binary-size cost.
- Is documented as experimental until stable.

Definition of done for a spike:

- A prototype supports `Path(T)`, `Query(T)`, `Json(T)`, `Form(T)`, and
  `IntoResponse`.
- A test route uses it end to end.
- Compile time and binary size are measured against the manual API.
- A decision memo recommends adopt or reject.

### P14.3 Implementation steps

- [ ] Write a design spike, not a full implementation.
- [ ] Define explicit traits and named wrappers.
- [ ] Implement one route in `examples/typed_route.zig`.
- [ ] Measure compile time, binary size, and request-path allocations.
- [ ] Compare readability with the manual API.
- [ ] Write an ADR: adopt, reject, or keep experimental.
- [ ] If adopted, add docs and migrate one recipe only; do not rewrite all
      examples.

### P14.4 Acceptance criteria

- The spike is measurable and reversible.
- No reflection-driven type construction.
- No public `anytype` where the accepted types are known.
- No regression in the existing API.

### P14.5 References

- `CODING_CONVENTION.md` sections 7 and 8
- `docs/api.md`
- Dusty handlers: <https://lalinsky.github.io/dusty/server/handlers/>
- nilo handlers: <https://nevindra.github.io/nilo/latest/handlers/>

---

## P15. WS-11: Full-stack module program (SQL, S3, jobs, cache, sessions, JWT, proto, metrics, tracing)

**Priority:** P1 (FS-0), P1-P2 (modules)  
**Milestone:** M10-M18  
**Status:** `[ ]`  
**Owner:** `dx_router` + `developer`; `crypto_tls` for secrets; `verification`
for vectors and integration

### P15.1 Problem

nilo ships SQL, S3, jobs, cache, JWT, proto, sessions, metrics, and tracing.
Dusty recommends community libraries for databases, Redis, NATS, templating,
and serialization. µWebZockets has JSON-RPC, OpenAPI, SSE, static files,
cookies, forms, multipart, auth middleware, counters, and a bounded HTTP client,
but no database, object storage, durable jobs, in-process cache, session layer,
JWT verifier, general protobuf codec, or tracing exporter.

The earlier position in this document was "ecosystem recipes only." That is no
longer the target. The target is a set of **optional, independently importable
modules** that feel integrated without turning the core into a monolith. This
is the difference between nilo's module set and nilo's monolith shape: adopt the
capability, reject the forced dependency and hidden service locator.

### P15.2 Goal and definition of done

A user can opt into any module and get:

- An explicit config type, a per-worker service handle, and a documented
  start/stop lifecycle.
- Bounded storage and a stable error set.
- No request-path allocation after startup.
- No global lock on the steady-state path.
- A runnable example, a test matrix entry, and a security boundary.
- A feature gate that removes the module and its dependencies when unused.

Definition of done for the program:

- FS-0 through FS-10 are green in `TODO.md` Section 17.
- Every module has a feature-gated build, a disabled-build link check, and a
  docs page.
- The core server can be built with no module enabled.
- The C ABI remains core-only unless a separate ADR expands it.
- The module boundaries are in the v3 security register.

### P15.3 Module architecture rules

1. **Optional import, not a framework kernel.** `src/root.zig` re-exports a
   module only under its build option. A program that never imports SQL must not
   link a SQL driver.
2. **Per-worker ownership.** Pools, clients, caches, job workers, trace buffers,
   and metric registries are per-worker. Cross-worker coordination goes through
   SQL or an external service, never shared mutable memory.
3. **Explicit lifecycle.** A module service starts after the listener binds,
   reports readiness, and stops before the loop is destroyed. No module starts a
   hidden thread in `init`.
4. **Bounded storage.** Every statement, row, object, job payload, cache value,
   token, span, and metric label has a configured maximum. Exhaustion returns a
   stable error.
5. **No reflection-driven schema.** SQL row mapping and protobuf field mapping
   declare their contract explicitly beside the type. No ORM, no `.proto`
   generator, no runtime registry.
6. **Fail closed.** TLS verification, signatures, sessions, JWKS, S3
   canonicalization, and job leases are security-sensitive and must reject
   ambiguity.
7. **No secrets in observability.** Tokens, cookies, passwords, keys, and raw
   query parameters are redacted from logs, metrics labels, traces, and error
   strings.
8. **C ABI stays core.** Modules are Zig-only in this program. The C ABI gets a
   separate ADR if it ever needs them.
9. **One module per PR.** The module owner is named by the architect. Shared
   files stay serialized.

### P15.4 Module inventory and naming

The current `uz.cache` is HTTP ETag/conditional GET, not a key/value store. Do
not repurpose it. The new cache is `uz.memory_cache`; a future major release may
rename the HTTP helper to `uz.http_cache` and give `uz.cache` to the store.

| Module | Public name | Current state | New work |
| --- | --- | --- | --- |
| SQL | `uz.sql` | none | PostgreSQL wire + pool + typed rows + migrations; SQLite optional |
| S3 | `uz.s3` | none | SigV4, CRUD, list, multipart, presigned URLs |
| Jobs | `uz.jobs` | none | SQL-backed queue, leases, retries, schedules |
| Cache | `uz.memory_cache` | `uz.cache` is HTTP ETag | Fixed-capacity typed cache |
| Sessions | `uz.sessions` | cookie parser + HMAC signing exist | Sealed-cookie sessions, keyring, CSRF |
| JWT | `uz.jwt` | none | HS/RS/ES/EdDSA, claims, JWKS |
| Proto | `uz.proto` | none | Shared protobuf codec for gRPC and OTLP |
| Metrics | `uz.metrics` | counters + Prometheus exist | Gauges, histograms, module metrics |
| Tracing | `uz.trace` | none | W3C context, spans, OTLP/HTTP |

### P15.5 FS-0: Module foundation and lifecycle

This blocks SQL, S3, jobs, and tracing, and it is the difference between a set
of libraries and a framework.

Proposed design:

- `WorkerContext`: worker index, `std.Io`, opaque loop handle, module context,
  and a bounded error reporter. No `*xev.Loop` in the module API.
- `ServiceHooks`: named function pointers for `start`, `stop`, `ready`, and
  `deinit`, plus a `*anyopaque` context. No `anytype`, no hidden registry.
- `App.provide(hooks)`: fixed-capacity registration; no allocation after
  `init`.
- Startup: bind, start services in order, log ready. Failure stops the services
  already started and returns a stable error naming the service.
- Shutdown: stop accepting, drain, stop services in reverse order, destroy the
  loop.
- Cluster: one service instance per worker, with per-worker failure reported
  through the existing `WorkerFailure` record.
- Feature gates: `sql`, `sqlite`, `s3`, `jobs`, `cache`, `sessions`, `jwt`,
  `proto`, `metrics`, `trace`. Disabled modules must be absent from the binary.

Acceptance:

- A service starts once per worker, reports readiness, stops once, and leaves no
  pending task.
- Failed startup rolls back.
- Disabled modules are absent from `nm`/link map.
- No steady-state request allocation.
- ADR and `docs/modules.md` exist.

### P15.6 FS-1: SQL (`uz.sql`)

Canonical tasks: `TODO.md` Section 9, D-0 through D-11.

Design summary:

- Pure-Zig PostgreSQL wire protocol first: startup, MD5/SCRAM-SHA-256, Parse,
  Bind, Execute, Describe, Sync, ReadyForQuery, TLS through the existing client
  context.
- Per-worker pool of 8-16 connections, no locks, bounded acquire queue, health
  check, reconnect backoff.
- Parameter binding only; no string interpolation. Row decoding into a bounded
  read slab; borrowed slices expire on the next row/query.
- Transactions, savepoints, deadlines, and connection-state quarantine on
  cancellation.
- Optional SQLite backend from a pinned amalgamation compiled by `zig cc`;
  WAL, busy timeout, one writer per worker, documented concurrency.
- Migrations with checksums and advisory/exclusive locks.
- Typed row mapping later, explicit traits only, no ORM/reflection.

Acceptance:

- PostgreSQL and SQLite integration tests; PG service container or written skip.
- Transaction rollback, cancellation, pool exhaustion, oversized row/field.
- Fuzz the wire decoder and migration parser.
- No request-path allocation; p50/p99 query and pool wait recorded.
- `docs/sql.md` and examples compile.

### P15.7 FS-2: S3 (`uz.s3`)

Design summary:

- Per-worker S3 client built on `uz.client` and BoringSSL.
- SigV4 canonical request, signed headers, payload hash (or documented
  `UNSIGNED-PAYLOAD` over verified TLS), HMAC-SHA256 key derivation, clock-skew
  handling.
- Operations: head/get/put/delete/copy, list V2 with pagination, multipart
  create/upload/complete/abort, presigned GET/PUT URLs.
- A bounded XML reader for S3 error and ListObjectsV2 shapes; no general XML
  dependency, reject unexpected nesting or oversized text.
- Streaming get/put: bounded buffers, caller sink, no whole-object buffering.
  Retry only idempotent or rewindable bodies.
- TLS verification required; endpoint validation/allowlist; region redirect
  only within the configured endpoint; SSRF controls.
- Credentials never logged/traced; error mapping includes request id without
  secrets.
- Tests: SigV4 and presigned golden vectors, mock S3 for 200/403/404/409/429/500,
  truncated/slow bodies, multipart, retries, bounded XML error/list parsing;
  optional MinIO gate.
- Docs: `docs/s3.md`, local MinIO example, presigned upload example, explicit
  "not an AWS SDK" boundary.

Depends on FS-0 and the client. S3 may use the current one-request client at
first; production guidance must state the pooling limitation until WS-8 C2
lands.

### P15.8 FS-3: Jobs (`uz.jobs`)

Design summary:

- SQL-backed queue using the database the application already has.
- Schema: id, kind, payload, state, attempts/max, run_at, leased_until,
  lease_owner, last_error, timestamps, optional idempotency key.
- `enqueue(tx, job)` commits with the caller's transaction; detached enqueue is
  explicit.
- Claim: PostgreSQL `FOR UPDATE SKIP LOCKED`; SQLite single-writer path or
  documented single worker. Bounded batch, lease, heartbeat, expired-lease
  recovery.
- At-least-once semantics; idempotency is the caller's responsibility and is
  documented.
- Per-worker concurrency limit, retry/backoff, max attempts, dead letter.
- Schedules with explicit overlap (`skip`, `queue`, `replace`) and missed-tick
  policy; timing wheel or bounded poll, no per-job thread.
- Shutdown stops claiming, drains within a deadline, releases leases, stops
  before SQL.
- Metrics/tracing: enqueued/claimed/completed/failed/retried/dead, queue depth,
  oldest age, lease expiry, span per execution.
- Tests: enqueue commit/rollback, single claim, lease expiry, retry, dead
  letter, schedule overlap, shutdown, SQLite behavior.

Depends on FS-0, FS-1, timing wheel.

### P15.9 FS-4: Cache (`uz.memory_cache`)

Design summary:

- Fixed-capacity typed keyspace; values are fixed-size or bytes copied into a
  cache arena. No pointers inside values; check where the language permits.
- `get`, `put`, `remove`, `contains`, `clear`, `stats`; optional per-entry TTL
  and default TTL.
- Open-addressed table with bounded probes; value arena with a byte budget;
  LRU/CLOCK eviction with a stated tie break; lazy TTL plus bounded sweep.
- No allocation after `init`; oversized value returns `error.ValueTooLarge`.
- Per-worker by default; no cross-worker consistency claim. Shared cache via
  SQL/external service is a separate module.
- Stats: hits, misses, evictions, expirations, bytes, entries, oldest age.
- No secret logging; do not claim secure erasure unless implemented.
- Tests: collisions, overwrite, eviction, TTL, capacity, stats, no allocation,
  pointer-bearing value rejection.

Depends on FS-0 only.

### P15.10 FS-5: Sessions (`uz.sessions`)

Canonical tasks: `TODO.md` Section 13, M-1/M-5.

Design summary:

- Sealed cookie by default: AES-256-GCM with a keyring and key ids; previous
  keys verify during rotation, then retire.
- Bounded payload/cookie size; typed binary or explicit JSON codec; no
  request-path allocation.
- `HttpOnly`, `Secure`, `SameSite`, `Path`, `Max-Age`, expiry; explicit domain.
- Session fixation prevention, rotation on login/privilege change, idle and
  absolute timeouts, logout.
- Optional store-backed sessions for revocation; stateless default and its
  revocation limit documented.
- CSRF token bound to the session, constant-time compare.
- Tests: tamper, truncation, wrong key id, expiry, replay, fixation, rotation,
  oversize, concurrent use.
- Depends on FS-0, `uz.cookie`, `uz.crypto_subtle`.

### P15.11 FS-6: JWT (`uz.jwt`)

Canonical tasks: `TODO.md` Section 13, M-4/M-5.

Design summary:

- Strict compact JWT parsing; reject `none`, padded/non-canonical base64url.
- HS256, RS256/384/512, ES256/384, EdDSA; algorithm allowlist mandatory. Never
  choose the verifier from the token header alone.
- Claims: exp, nbf, iat, iss, aud, sub, jti; configurable skew and required
  claims; duplicate keys rejected.
- Bounded token/header/claim sizes; claims borrow the token for request
  lifetime; `.keep()` for deferred use.
- Optional JWKS service: bounded cache, `kid` lookup, unknown-key refresh with
  rate limit, TTL, TLS verification, SSRF controls.
- Constant-time comparisons; zeroize secrets; never log a token or key.
- Tests: RFC vectors, alg confusion, expiry, audience/issuer, malformed,
  oversized, key rotation, missing key.
- Depends on FS-0, crypto, optional client for JWKS.

### P15.12 FS-7: Proto (`uz.proto`)

Canonical tasks: `TODO.md` Section 11, R-0 through R-5.

Design summary:

- Shared codec for gRPC, OTLP, and application messages; no second decoder under
  `src/grpc/`.
- Varint, zigzag, fixed32/64, length-delimited, repeated, packed, optional,
  maps, oneofs, unknown-field skipping, bounded recursion.
- Decode borrows input; encode writes caller storage; no allocation.
- Canonical protobuf vectors, round-trip, truncated/overlong/oversized tests.
- gRPC 5-byte framing, HTTP/2 trailers, cancellation and status mapping.
- No `.proto` parser or protoc; the struct declares its field numbers.
- Depends on FS-0, HTTP/2.

### P15.13 FS-8: Metrics (`uz.metrics`)

Canonical tasks: `TODO.md` Section 14, O-1 through O-4/O-8.

Design summary:

- Extend the existing counter registry; do not create a second registry.
- Counters, gauges, bounded histograms; per-worker state; scrape aggregation
  without a request-path lock; saturating counters.
- Prometheus/OpenMetrics rendering with no allocation.
- HTTP/WebSocket/H2/QUIC, SQL/S3/jobs/cache/JWKS, slab/queue/pool, and trace
  drop metrics.
- Cardinality bounds; no request-derived labels.
- Depends on FS-0; modules add counters as they land.

### P15.14 FS-9: Tracing (`uz.trace`)

Canonical tasks: `TODO.md` Section 14, O-5 through O-8.

Design summary:

- W3C `traceparent`/`tracestate` parse/emit with strict validation.
- Trace/span IDs from injected entropy; sampling (parent-based + ratio).
- Bounded spans, attributes, events, and per-worker queue; drop counters.
- Server span per request; child spans for SQL, S3, jobs, cache, client.
- OTLP/HTTP protobuf exporter via `uz.proto` and `uz.client`; TLS, batch,
  retry/backoff, shutdown flush with deadline.
- Redact credentials, cookies, tokens, raw query parameters; no blocking export.
- Golden OTLP tests and a local receiver/mock.
- Depends on FS-0, FS-7, client.

### P15.15 FS-10: Integration, recipes, and release surface

- `docs/modules.md` with the module matrix, feature flags, lifecycle,
  ownership, and C ABI boundary.
- Recipes: SQLite CRUD; PostgreSQL CRUD + transaction + jobs; S3
  upload/download + presigned URL; sessions + JWT login; cache-backed
  JWKS/session/idempotency; metrics + tracing dashboard.
- Update `README.md` from "server framework" to "server framework with optional
  application modules" without overclaiming.
- Update `docs/roadmap.md`, `docs/api.md`, `docs/memory_model.md`,
  `CI_CD_PIPELINE.md`, and `CHANGELOG.md`.
- Add module boundaries to the v3 security register (SB-55 through SB-63 in
  `TODO.md`).
- Do not expose modules through the C ABI in this program.

### P15.16 Release mapping

| Release | Modules | Depends on | Gate |
| --- | --- | --- | --- |
| v2.3.0 | `uz.sql` PostgreSQL + typed rows | FS-0, TLS, timing wheel | PG integration + allocation + p99 |
| v2.3.1 | SQLite + migrations (if not in 2.3.0) | v2.3.0 | SQLite CI + migration tests |
| v2.5.0 | `uz.proto`, gRPC | FS-0, HTTP/2 | Proto vectors + gRPC interop |
| v2.7.0 | `uz.sessions`, `uz.jwt` | FS-0, cookie, crypto, client (JWKS) | Tamper/replay + alg confusion |
| v2.8.0 | `uz.metrics`, `uz.trace` | FS-0, proto, client | Prometheus parse + OTLP golden |
| v2.10.0 (prov.) | `uz.s3` | FS-0, client, BoringSSL | SigV4 vectors + mock S3 |
| v2.11.0 (prov.) | `uz.jobs` | FS-0, `uz.sql`, timing wheel | Claim/retry/lease/shutdown |
| v2.12.0 (prov.) | `uz.memory_cache` | FS-0 | Eviction/TTL/allocation |
| v2.13.0 (prov.) | Integration, recipes, docs | all enabled modules | Full matrix + docs |

Provisional means the maintainer may move the slot after dependency and
security evidence is known. S3 may use the current one-request client at first;
production guidance must state the pooling limitation until WS-8 C2 lands.

### P15.17 Module test matrix

Every module:

- Unit tests for pure codecs/parsers/verification.
- A loopback integration test where the module speaks a protocol.
- A bounded-capacity test for every queue/pool/table/buffer.
- A no-request-path-allocation test after startup.
- A secret-redaction test for logs, errors, metrics, and traces.
- ASan/UBSan/LSan; fuzz for every peer-controlled parser.
- A feature-gate test: disabled module absent from the binary.
- A compiling documentation example.
- Optional live service test (PostgreSQL, S3/MinIO, OTLP receiver) with a
  written skip reason when unavailable.

### P15.18 Risks and non-goals

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Core becomes a monolith | Slow builds, forced dependencies | Optional imports, feature gates, link check |
| Module allocates on request path | p99 and slab regressions | Allocation tests, caller-owned buffers |
| SQL/S3 protocols are subtle | Security/correctness bugs | Vectors, fuzz, mock servers, optional live gates |
| JWT/session crypto is wrong | Account compromise | Audited crypto, constant-time, vectors, review |
| Jobs deliver twice | Duplicate side effects | At-least-once contract, idempotency keys, docs |
| Cache hides cross-worker inconsistency | Stale data | Per-worker default, explicit docs |
| Tracing leaks secrets or blocks | Compliance/latency | Redaction, bounded queue, drop counter |
| Module creep delays v3 closure | Roadmap slip | FS IDs, v3 boundaries not weakened |

Non-goals:

- No ORM, query builder, or automatic schema reflection in the first SQL
  release.
- No protobuf compiler or `.proto` parser.
- No full AWS SDK; `uz.s3` is an explicit subset.
- No distributed cache or Redis client in the first cache release.
- No job broker; jobs use the SQL database.
- No C ABI for modules in this program.

### P15.19 References

- `TODO.md` Section 9 (SQL), Section 11 (proto/gRPC), Section 13
  (sessions/JWT), Section 14 (metrics/tracing), Section 17 (module program)
- nilo SQL/S3/jobs/cache/JWT/proto/sessions/metrics/tracing guide:
  <https://nevindra.github.io/nilo/latest/>
- nilo design pages:
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/>
- Dusty recommended libraries:
  <https://github.com/lalinsky/dusty#recommended-libraries>
- PostgreSQL Frontend/Backend Protocol:
  <https://www.postgresql.org/docs/current/protocol.html>
- SQLite amalgamation:
  <https://www.sqlite.org/amalgamation.html>
- AWS SigV4:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-signing-elements.html>
- RFC 7515/7518/7519 (JWT/JWS/JWA)
- W3C Trace Context: <https://www.w3.org/TR/trace-context/>
- OpenTelemetry Protocol: <https://opentelemetry.io/docs/specs/otlp/>
- Protocol Buffers encoding: <https://protobuf.dev/programming-guides/encoding/>

---

## P16. Milestones and sequencing

Estimates assume one senior systems engineer full-time plus part-time review
and verification. Re-estimate after M0. Do not treat them as commitments.

| Milestone | Workstreams | Outcome | Estimate |
| --- | --- | --- | --- |
| M0 | WS-5, WS-2 baseline | Baseline numbers, budget draft, inventory | 2-3 weeks |
| M1 | WS-1 phase 1 | Engine seam for loop/timer/wakeup, boundary check | 3-5 weeks |
| M2 | WS-1 phase 2 | TCP/UDP/client/observability/tests behind the seam | 6-9 weeks |
| M3 | WS-2 | Idle-memory harness, HTTP/2 toggle, published numbers | 4-6 weeks |
| M4 | WS-3, WS-4, WS-5 | Lite build, docs site, first-run path, enforced budget | 6-9 weeks |
| M5 | WS-6 | Green Windows runtime evidence | 2-4 weeks |
| M6 | WS-8 | WebSocket client, keep-alive/pooling, DNS | 8-12 weeks |
| M7 | WS-7 | Zig 0.17 support on `uwz/zig-0.17` | 6-10 weeks |
| M8 | WS-9 | Handler I/O and streaming bodies | 6-10 weeks |
| M9 | WS-10 | Typed API spike | 3-5 weeks |
| M10 | WS-11 / FS-0 | Module lifecycle, feature gates, module docs | 4-6 weeks |
| M11 | FS-1 | `uz.sql` PostgreSQL + typed rows + SQLite/migrations | 10-16 weeks |
| M12 | FS-5, FS-6 | `uz.sessions` + `uz.jwt` | 6-9 weeks |
| M13 | FS-7 | `uz.proto` + gRPC extraction | 6-9 weeks |
| M14 | FS-8, FS-9 | `uz.metrics` + `uz.trace` | 6-9 weeks |
| M15 | FS-2 | `uz.s3` | 6-9 weeks |
| M16 | FS-3 | `uz.jobs` | 6-9 weeks |
| M17 | FS-4 | `uz.memory_cache` | 3-5 weeks |
| M18 | FS-10 | Integration, recipes, docs, release surface | 4-6 weeks |

Parallelism:

- M1 and M3 can run in parallel after M0.
- M2 depends on M1.
- M4 depends on M3 for the memory budget and on M1 for the seam.
- M5 is independent.
- M6 depends on M2 for a clean client seam.
- M7 is independent but should not overlap a release freeze.
- M8 depends on M1 and M2 for engine-neutral I/O.
- M9 depends on M8 for handler context.
- M10 (FS-0) can start after M1 phase 1 because modules need the engine-neutral
  loop and worker context. Do not start a module that owns a connection before
  M10 is green.
- M11 (SQL) depends on M10 and the timing wheel.
- M12 (sessions/JWT) depends on M10 and crypto; it does not depend on SQL.
- M13 (proto/gRPC) depends on M10 and HTTP/2.
- M14 (metrics/tracing) depends on M10, M13, and the client.
- M15 (S3) depends on M10 and the client; it can run before SQL.
- M16 (jobs) depends on M11 (SQL) and M10.
- M17 (cache) depends only on M10.
- M18 depends on the modules that are actually enabled for the release.

Recommended order for a solo maintainer:

1. M0 baseline.
2. M1 engine seam phase 1.
3. M3 memory harness and H2 toggle.
4. M2 engine seam phase 2.
5. M4 docs/lite build/budget.
6. M10 module lifecycle and feature gates.
7. M11 SQL (Postgres first, SQLite/migrations next).
8. M12 sessions/JWT.
9. M13 proto/gRPC.
10. M14 metrics/tracing.
11. M15 S3.
12. M16 jobs.
13. M17 cache.
14. M18 integration/docs.
15. M5 Windows.
16. M6 client.
17. M8 handler I/O.
18. M7 Zig 0.17 when the ecosystem requires it.
19. M9 optional typed API.

The module track can overlap with the v3 security closure only where the
dependency rows are green. Do not start a module that owns a connection before
FS-0 is green, and do not call a module production-ready before its SB rows are
closed or accepted.

---

## P17. Dependency graph

```text
M0 Baseline
 ├─> M1 Engine seam phase 1
 │    └─> M2 Engine seam phase 2
 │         ├─> M6 Client
 │         └─> M8 Handler I/O
 │              └─> M9 Typed API
 ├─> M3 Idle memory + H2 toggle
 │    └─> M4 Docs / lite build / budget
 ├─> M5 Windows evidence
 ├─> M7 Zig 0.17 (independent, release-gated)
 └─> M10 Module foundation (FS-0)
      ├─> M11 SQL (FS-1)
      │    └─> M16 Jobs (FS-3)
      ├─> M12 Sessions + JWT (FS-5, FS-6)
      ├─> M13 Proto + gRPC (FS-7)
      │    └─> M14 Metrics + tracing (FS-8, FS-9)
      ├─> M15 S3 (FS-2)
      ├─> M17 Cache (FS-4)
      └─> M18 Integration/docs (FS-10)
```

Do not start M2 before M1 is green. Do not start M6 before M2 is green. Do not
start a module that owns a connection before M10 is green. Do not start M7 in
the middle of a release freeze.

---

## P18. Global verification gates

Every code-changing PR must run the project gates. The canonical list is in
`AGENTS.md`; this section records the expected commands and adds the new checks.

### P18.1 Required every time

```sh
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
zig build test
```

### P18.2 Required for transport/runtime changes

```sh
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
sh scripts/check_static_archive.sh
```

Run the relevant conformance suite:

- HTTP/1.1: h1spec
- WebSocket: Autobahn
- HTTP/2: h2spec / project gate
- HTTP/3: curl/ngtcp2 and aioquic gate
- Windows: `windows.yml`

### P18.3 Required for performance/memory changes

```sh
scripts/benchmark_http.sh <candidate> <baseline> <out-dir>
scripts/benchmark_h2_tls.sh <candidate> <baseline> <out-dir>
scripts/benchmark_idle_memory.sh <candidate> <out-dir>
```

Record the runner cohort, CPU, kernel, toolchain, and source revisions. Do not
compare across cohorts.

### P18.4 Required for dependency/toolchain changes

```sh
sh scripts/check_dependency_forks.sh
sh scripts/check_libxev_fork.sh
sh scripts/check_mirror_state.sh
sh scripts/check_package_paths.sh
```

For a Zig 0.17 change, also run the 0.16 compatibility matrix until the
deprecation is announced.

### P18.5 New checks to add

- [ ] `scripts/check_engine_seam.sh` — WS-1.
- [ ] `scripts/check_binary_size.sh` — WS-5.
- [ ] `scripts/benchmark_idle_memory.sh` — WS-2.
- [ ] `scripts/check_docs_links.sh` or extend `check_docs.sh` — WS-4.
- [ ] `scripts/check_feature_matrix.sh` — WS-3.
- [ ] `scripts/check_module_gates.sh` — WS-11: disabled-module link check,
      allocation/secret-redaction tests, and optional-service skips.
- [ ] `scripts/check_module_vectors.sh` — FS-1/FS-2/FS-6/FS-7 golden vectors
      and fuzz corpus.

---

## P19. Risks, trade-offs, and things not to do

### P19.1 Do not migrate to std.Io or zio as part of this plan

- The fixed decision is libxev on the maintained fork.
- Zig's `std.Io.Evented` still has no Windows backend in 0.16 and current
  master, and its networking API lacks the vectors the project needs.
- nilo uses `zio`, not `std.Io.Evented`; Dusty uses `std.Io` but recommends
  zio for production. That is evidence for keeping a proven engine, not for
  rewriting.
- The engine seam makes a future evaluation cheap. Do it for isolation, not as
  a migration step.

### P19.2 Do not copy nilo's monolithic shape

- SQL, S3, jobs, cache, sessions, JWT, proto, metrics, and tracing are in
  scope, but as optional modules with feature gates. They are not a second
  framework kernel.
- Keep the core lean and zero-allocation. A module that becomes mandatory, or
  that forces a dependency on every build, has violated the module contract.
- No hidden service locator, no global registry, no module that starts an
  unowned thread. Use the explicit lifecycle in WS-11/FS-0.
- If a module cannot meet the four-axis budget, it needs an ADR exception and a
  documented cost, not a silent regression.

### P19.3 Do not trade away zero allocation for convenience

- Every new helper must either use caller-owned storage, the startup slab, or
  an explicitly documented allocation API.
- `Request.clone(allocator)` and `req.json(T, allocator)` remain the only
  allocating request APIs unless a new ADR says otherwise.
- A typed handler layer must prove no request-path allocation.

### P19.4 Do not make performance claims without a cohort

- Shared-runner throughput is noisy.
- Record the runner, CPU, kernel, compiler, dependency pins, and workload.
- Report medians and p99, not a single best run.
- Do not compare TLS/H2 numbers with plaintext/H1 numbers.

### P19.5 Do not let the engine seam become a second framework

- The engine interface should be narrow and boring: accept, read, write,
  connect, close, timer, wakeup, poll.
- No plugin system, no dynamic loading, no generic completion algebra.
- If a capability is used by one file, keep it in the adapter.

---

## P20. Definition of done for the overall program

The program is complete when all of the following are true:

- [ ] WS-1: only the adapter imports libxev; app/tests are engine-neutral;
      throughput regression <= 2 percent.
- [ ] WS-2: bytes per idle HTTP/1.1 and WebSocket are measured at 1k and 10k;
      HTTP/2 storage is optional; a WebSocket-only preset is documented.
- [ ] WS-3: a minimal HTTP/1.1 + WebSocket build compiles without BoringSSL or
      lsquic; full build unchanged.
- [ ] WS-4: `zig build docs` works; API reference and quickstart exist; recipes
      compile.
- [ ] WS-5: four-axis budget is enforced or reported; allocation and binary
      size are hard gates.
- [ ] WS-6: Windows runtime job is green for the release commit and the claim
      is updated.
- [ ] WS-7: Zig 0.17 is supported on `uwz/zig-0.17`; 0.16 remains green during
      the transition.
- [ ] WS-8: WebSocket client and HTTP/1.1 keep-alive/pooling are complete.
- [ ] WS-9: handler I/O and streaming request bodies are available and tested.
- [ ] WS-10: optional typed API decision is recorded and either adopted or
      rejected with evidence.
- [ ] WS-11/FS-0 through FS-10: module lifecycle, SQL, S3, jobs, cache,
      sessions, JWT, proto, metrics, and tracing pass their gates, feature
      gates, docs, and security boundaries.
- [ ] All global gates pass; no test, lint, threshold, or sanitizer was
      weakened.

---

## P21. References

### P21.1 Local project references

- `AGENTS.md`
- `TODO.md` (execution tracker; Section 17 for modules)
- `CODING_CONVENTION.md`
- `docs/dependency_forks.md`
- `docs/architecture.md`
- `docs/memory_model.md`
- `docs/api.md`
- `docs/client.md`
- `docs/roadmap.md`
- `docs/operations.md`
- `docs/deployment.md`
- `docs/libxev_kqueue_findings.md`
- `docs/adr/0004-windows-iocp-accept-and-queued-close.md`
- `docs/adr/0005-libxev-fork.md`
- `docs/adr/0006-dependency-forks.md`
- `build.zig.zon`
- `builds/targets/native.zig`
- `src/core/xev.zig`
- `src/core/loop.zig`
- `src/core/tcp.zig`
- `src/core/timer.zig`
- `src/core/udp.zig`
- `src/core/signal.zig`
- `src/client/connection.zig`
- `src/client/client.zig`
- `src/observability/file_watch.zig`
- `src/observability/metrics.zig`
- `src/router/app.zig`
- `src/router/config.zig`
- `src/http/cookie.zig`
- `src/http/middleware.zig`
- `src/crypto/subtle.zig`
- `src/http2/server.zig`
- `src/rpc/json_rpc.zig`
- `src/tests/config_tests.zig`
- `src/tests/xev_tests.zig`
- `benchmarks/http_throughput_guarantee.md`
- `benchmarks/h2_tls_scaling_guarantee.md`

### P21.2 Dusty references

- Repository: <https://github.com/lalinsky/dusty>
- Documentation: <https://lalinsky.github.io/dusty/>
- Deployment on zio: <https://lalinsky.github.io/dusty/server/deployment/>
- Server routing: <https://lalinsky.github.io/dusty/server/routing/>
- Handlers: <https://lalinsky.github.io/dusty/server/handlers/>
- WebSocket: <https://lalinsky.github.io/dusty/server/websocket/>
- Client: <https://lalinsky.github.io/dusty/client/requests/>
- Build options: <https://lalinsky.github.io/dusty/build-options/>

### P21.3 nilo references

- Repository: <https://github.com/nevindra/nilo>
- Guide: <https://nevindra.github.io/nilo/latest/>
- Engine design: <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/engine.md>
- Memory design: <https://github.com/nevindra/nilo/blob/v0.8.0/docs/design/memory.md>
- ADR 001 (zio behind the Bulkhead):
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/001-zio-as-the-engine-behind-the-bulkhead.md>
- ADR 017 (four-axis budget):
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/017-the-trade-budget-has-four-axes.md>
- ADR 062 (where a connection waits):
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/062-where-a-connection-waits-is-what-it-costs.md>
- ADR 199 (pinned scheduling):
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md>
- ADR 200 (one acceptor per executor):
  <https://github.com/nevindra/nilo/blob/v0.8.0/docs/adr/200-every-executor-accepts.md>

### P21.4 Zig and libxev references

- Zig `std.Io` source (0.16):
  <https://github.com/ziglang/zig/blob/0.16.0/lib/std/Io.zig>
- Zig `std.Io` current master:
  <https://github.com/ziglang/zig/blob/master/lib/std/Io.zig>
- libxev fork: <https://github.com/farbenbuilds/libxev>
- Upstream libxev (fetch-only, do not push):
  <https://github.com/mitchellh/libxev>
- uWebSockets (the performance reference):
  <https://github.com/uNetworking/uWebSockets>

### P21.5 Module references

- `TODO.md` Section 17 (canonical module tasks and release map)
- PostgreSQL protocol:
  <https://www.postgresql.org/docs/current/protocol.html>
- SQLite amalgamation:
  <https://www.sqlite.org/amalgamation.html>
- SQLite WAL:
  <https://www.sqlite.org/wal.html>
- AWS SigV4:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-signing-elements.html>
- Amazon S3 API:
  <https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html>
- RFC 7515 (JWS), RFC 7518 (JWA), RFC 7519 (JWT)
- RFC 6749 (OAuth 2.0) for bearer-token context
- W3C Trace Context: <https://www.w3.org/TR/trace-context/>
- OpenTelemetry Protocol: <https://opentelemetry.io/docs/specs/otlp/>
- Protocol Buffers encoding:
  <https://protobuf.dev/programming-guides/encoding/>
- nilo module guide: <https://nevindra.github.io/nilo/latest/>
- Dusty recommended libraries:
  <https://github.com/lalinsky/dusty#recommended-libraries>

---

## P22. Appendix A: current libxev surface inventory

This is the starting inventory for WS-1. Re-run `rg` before starting; line
numbers drift.

| File | What it owns today | Target owner after WS-1 |
| --- | --- | --- |
| `src/core/xev.zig` | Dynamic backend shim, cancel helpers, fd access | Adapter only; delete or re-export |
| `src/core/loop.zig` | Loop lifecycle, thread pool, `get_xev_loop` | Engine-neutral `Loop` |
| `src/core/tcp.zig` | TCP/UDP watchers, completions, listener completions | Transport using engine types |
| `src/core/timer.zig` | Timer scheduler and wheel | Engine-neutral timer API |
| `src/core/udp.zig` | UDP watcher | Engine-neutral UDP API |
| `src/core/signal.zig` | Self-pipe/console control | Engine-neutral wakeup/read |
| `src/core/tcp_file.zig` | Socket/descriptor access | Engine-neutral fd access |
| `src/client/connection.zig` | Client loop, completions | Engine-neutral client transport |
| `src/client/client.zig` | Client lifecycle | Engine-neutral client API |
| `src/observability/file_watch.zig` | Poll watcher, timer, cancel | Engine-neutral file poll |
| `src/router/app.zig` | Cluster wakeup, listener setup, file watcher | Engine-neutral app |
| `src/tests/xev_tests.zig` | Backend selection and completion tests | Adapter tests |
| `src/tests/router_tests.zig` | Some xev-named tests | Behavior tests |

Command to refresh the inventory:

```sh
rg -n 'xev\.|@import\("xev"\)|@import\("xev_impl"\)' src builds tests examples
```

---

## P23. Appendix B: external comparison facts

Use these as context, not as a scoreboard.

| Fact | Dusty | nilo | µWebZockets |
| --- | --- | --- | --- |
| Product | HTTP client/server library | Full-stack framework | Server framework + C ABI, optional modules (planned) |
| Application modules | Recommended community libraries | SQL, S3, jobs, cache, JWT, proto, sessions, metrics, tracing | Optional `uz.sql`, `uz.s3`, `uz.jobs`, `uz.memory_cache`, `uz.sessions`, `uz.jwt`, `uz.proto`, `uz.metrics`, `uz.trace` (WS-11) |
| HTTP/1.1 | Yes | Yes | Yes |
| HTTP/2 | No | Yes | Yes |
| HTTP/3/QUIC | No | No | Yes |
| WebSocket server | Yes | Yes | Yes |
| WebSocket client | Yes | No WebSocket client | No (planned) |
| Client pooling | Yes | `nilo_fetch` | No (one request per connection) |
| SSE | Yes | Yes | Yes |
| Static files | Yes | Yes | Yes |
| TLS | tls.zig | Fronted / optional | BoringSSL |
| Engine | `std.Io` (Threaded/zio) | zio | libxev |
| Engine swap | Yes | Bulkhead | No (WS-1 fixes this) |
| Zig versions | 0.16, 0.17 | 0.16 | 0.16 (0.17 planned) |
| Idle memory | Not published in README | 4,669 B HTTP/1.1, 5,183 B WS | Unpublished; slab bytes only |
| Throughput evidence | HttpArena H1/WS | 1.4M req/s H1, p99 69us | H2/TLS scaling, H1 regression contract |
| Docs site | Yes | Yes | No (WS-4) |
| API reference | Yes | Yes | No (WS-4) |
| ADRs | Some design docs | 280+ | Yes, but fewer |
| C ABI | No | No | Yes |
| Cluster | No | Threads, no C ABI | Shared-nothing cluster |
| License | MIT | Check repository | Check repository |

Notes:

- nilo's throughput number is plaintext HTTP/1.1 on four cores with 64
  connections, not TLS/H2. Do not compare it directly to the H2/TLS scaling
  records.
- Dusty's `std.Io.Threaded` default gives each connection an OS thread; zio is
  recommended for production. Feature lists are not deployment models.
- µWebZockets' slab bytes are reserved, not resident. Do not quote them as RSS.

---

## P24. Appendix C: proposed ADRs

Create these as decisions land. Keep them short and link the evidence.

| ADR | Topic | Workstream |
| --- | --- | --- |
| 0008 | Engine seam: libxev behind a narrow capability interface | WS-1 |
| 0009 | Build feature matrix: minimal/full configurations | WS-3 |
| 0010 | Four-axis quality budget | WS-5 |
| 0011 | HTTP/2 storage optional and WebSocket-only preset | WS-2 |
| 0012 | Handler I/O and bounded blocking pool | WS-9 |
| 0013 | Streaming request body contract | WS-9 |
| 0014 | Typed handler layer: adopt, reject, or experimental | WS-10 |
| 0015 | Zig 0.17 support and `uwz/zig-0.17` fork branch | WS-7 |
| 0016 | Client pooling and WebSocket client | WS-8 |
| 0017 | Windows support claim and release evidence | WS-6 |
| 0018 | Optional module lifecycle, feature gates, and C ABI boundary | WS-11 / FS-0 |
| 0019 | SQL module: PostgreSQL wire, SQLite, pools, migrations, typed rows | FS-1 |
| 0020 | S3 module: SigV4, streaming, multipart, presigned URLs, SSRF policy | FS-2 |
| 0021 | Jobs module: SQL queue, leases, retries, schedules, at-least-once | FS-3 |
| 0022 | In-process cache: fixed capacity, eviction, TTL, per-worker isolation | FS-4 |
| 0023 | Sessions: sealed cookies, key rotation, fixation, revocation | FS-5 |
| 0024 | JWT: algorithm allowlist, claims, JWKS, key zeroization | FS-6 |
| 0025 | Proto: shared wire codec, gRPC, OTLP, unknown fields | FS-7 |
| 0026 | Metrics and tracing: cardinality, redaction, OTLP export | FS-8, FS-9 |
| 0027 | Module integration, recipes, and release surface | FS-10 |

Numbering may collide with existing ADRs; assign the next free numbers when
writing. Existing ADRs 0001 through 0007 are already in `docs/adr/`; the table
above starts at 0008.

---

## P25. Appendix D: useful commands

### Inventory

```sh
rg -n 'xev\.|@import\("xev"\)|@import\("xev_impl"\)' src builds tests examples
rg -n 'xev\.' src/router src/client src/observability src/tests
rg -n 'get_xev_loop|xev_loop' src
```

### Tests

```sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build lib -Doptimize=ReleaseFast --summary all
```

### Formatting and conventions

```sh
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_docs.sh
sh scripts/check_release_version.sh
```

### Dependency policy

```sh
sh scripts/check_dependency_forks.sh
sh scripts/check_libxev_fork.sh
sh scripts/check_mirror_state.sh
sh scripts/check_package_paths.sh
```

### Memory and performance

```sh
scripts/benchmark_http.sh <candidate> <baseline> <out-dir>
scripts/benchmark_h2_tls.sh <candidate> <baseline> <out-dir>
scripts/benchmark_idle_memory.sh <candidate> <out-dir>
```

### Graphify

```sh
graphify query "where does libxev leak into the application layer?"
graphify update .
```

### Modules

```sh
# A minimal core build with all optional modules disabled.
zig build -Dsql=false -Ds3=false -Djobs=false -Dcache=false \
  -Dsessions=false -Djwt=false -Dproto=false -Dtrace=false

# The module test matrix for one module.
zig build test -Dsql=true -Dsqlite=true
zig build test -Dsql=false
zig build -Dminimal=true
```

The exact option names must match the build graph once FS-0 lands. These
commands are the contract to add to `scripts/check_feature_matrix.sh`.

---

## P26. Appendix E: review checklist for every PR

- [ ] Does this change add a request-path allocation? If yes, is it an
      explicit allocation API with an ADR?
- [ ] Does this change add bytes per idle connection? If yes, what is the
      measured cost?
- [ ] Does this change add binary size? If yes, what is the stripped
      ReleaseFast delta?
- [ ] Does this change add a libxev type outside the adapter? If yes, move it.
- [ ] Does this change add a public API? Is it documented and tested?
- [ ] Does this change touch a platform-specific path? Is the native CI job
      green?
- [ ] Does this change touch the dependency graph? Are the fork/mirror checks
      green?
- [ ] Does this change weaken a test, lint, threshold, or sanitizer? If yes,
      reject or require an ADR.
- [ ] Does this change update `CHANGELOG.md`, the relevant docs, and an ADR?
- [ ] Can a new user follow the quickstart after this change?
- [ ] If this is a module change: is the module behind a feature gate, absent
      from the binary when disabled, and free of a mandatory core dependency?
- [ ] If this is a module change: does it have a per-worker lifecycle, a
      bounded storage budget, a stable error set, and a secret-redaction test?
- [ ] If this is a module change: does it have a runnable recipe and a test
      matrix entry in `TODO.md` Section 17?
- [ ] If this is a module change: is its v3 security boundary (SB row) named
      and linked?

---

## P27. Appendix F: open questions

These are not blockers; record answers as decisions.

1. What is the measured idle RSS per connection for HTTP/1.1 and WebSocket at
   1k and 10k today?
2. How much of that is the HTTP/2 session storage versus the connection struct,
   request buffer, write queue, and WebSocket message region?
3. Does a WebSocket-only preset need HTTP/2 code at all, or only a runtime
   storage toggle?
4. Can the engine seam be zero-cost on the hot path, or does it need a
   specialized compile-time path per backend?
5. Does the project want a typed handler layer, or is the manual API the
   deliberate design?
6. Is a separate lite package needed to reduce fetch weight, or is compile-time
   weight enough?
7. When does Zig 0.17 become the minimum supported version?
8. What is the target connection count for the commercial WebSocket story:
   1k, 10k, 100k per worker? The answer changes the memory priority.
9. Does the client need HTTP/2, or is HTTP/1.1 + WebSocket enough?
10. Which platform is the next support claim after Windows: BSD, 32-bit ARM,
    or WASI?
11. Which module ships first after FS-0: SQL (v2.3) or cache (independent)?
    The dependency graph says SQL is on the critical path; confirm the product
    priority.
12. Does SQLite ship in the first `uz.sql` release or in a follow-up?
13. Does S3 wait for client keep-alive/pooling, or ship on the one-request
    client with a documented limitation?
14. Is the new cache named `uz.memory_cache`, or does a future major release
    rename the HTTP `uz.cache` to `uz.http_cache` first?
15. Do sessions need a store-backed revocation mode in the first release, or is
    the sealed-cookie default sufficient?
16. Does tracing export OTLP/protobuf only, or also OTLP/JSON for easier local
    debugging?
17. Does the C ABI ever expose modules, or is it permanently core-only?

---

End of Part II.

---

## 19. Master release checklist

### v1.9.0 checklist (Declared-Limits Closure)

- [x] M0: the maintainer-created `v1.9.0` tag exists; provenance is archived in
      `benchmarks/results/h2_tls_scaling_v1/2026_10_19/`.
- [x] M1: the probe table is filled from the archived shared-host run; nonzero
      RPS at 1,024 connections is recorded. This is not a quiet-host claim.
- **External:** M2 HttpArena `baseline-h2` restoration and official fresh
      results are user/maintainer-owned after the release tag.
- [x] M3: H2 window work is closed as measured, not needed, with regression
      coverage.
- **External:** M4 native Windows runtime is red as of run 40094814541
      (2026-10-24); both blockers remain linked.
- [x] M5: the dated MSan dependency-boundary contract is recorded.
- [x] M6: each follow-up is closed, documented, or re-declared.
- [x] M7: published numbers link to archived raw artifacts; `http-throughput-v1`
      is unchanged.
- [x] `CHANGELOG.md`, docs, and ADRs describe the shipped behavior.

### Deferred GraphQL checklist

- **Deferred:** G-0 through G-4 pass their listed checks once the track is
  scheduled.

### v2.0.0 checklist (High-Throughput Performance)

- [x] Worker scaling (P-1, P-2) builds on the shipped cluster API, with M1
      evidence for any new tuning and runtime `UWEBZOCKETS_WORKERS` selection.
- **External evidence:** HTTP pipelining (P-3) exceeds 10M RPS on the
      designated host. Implementation and unit coverage landed; evidence is
      2.1-C1.
- **External evidence:** WebSocket batching (P-4) meets its target on the
      designated host. SIMD and frame batching landed; evidence is 2.1-C1.
- **External evidence:** Compression pooling (P-5) exceeds 400K RPS on
      `json-comp` with P99 below 50 ms. Per-worker codecs and
      `Response.end_gzip` landed; evidence is 2.1-C1.
- [x] H2 window work (P-7) is closed as measured, not needed; H3 transmit
      GSO is implemented and unit-tested. Receive GRO is 2.1-C2.
- [x] Multi-port startup barrier (P-8) removes port 8080 reset races.
- [x] TRACE routing (P-9) is available in `Router`/`App`, the client, the C
      ABI, HTTP/2, HTTP/3, OpenAPI, and the live HTTP/3 compliance gate;
      TRACE is opt-in and documented.
- **External evidence:** `latency-1m` P99 remains at or below 160 us.
      Evidence is 2.1-C1.

### v2.1.0 checklist (Timer Engine and Deadlines)

- [x] Timing wheel (T-1, T-2) passes millisecond precision tests.
- [x] `/delay/{ms}` (T-3) implementation and unit coverage are present.
- [x] Idle and header read timeouts (T-4) reap inactive connections.
- **External evidence:** HttpArena `async` adapter activation (2.2-C3) and
      quiet-host evidence (2.2-C1) remain user/designated-host tasks.

### v2.1.5 checklist (API Hardening and Worker Manager)

- [x] Public `threads`, `thread_count`, `worker_failed`, `deinitialized`,
      `publish`, and `deinit` stay source-compatible.
- [x] Cluster lifecycle, worker count, failure phase/count, and publish
      reports are typed and documented.
- [x] `src/router/worker_group.zig` owns lifecycle transitions, release
      claiming, borrowed thread start/join, and first-failure capture; thread
      storage and compatibility fields stay in `Cluster`.
- [x] `Cluster.configure` uses the named `ConfigureCallback`.
- [x] `deinit_checked()` provides a typed release path; `deinit()` keeps its
      panic contract.
- [x] ADR 0007, `docs/api.md`, `docs/architecture.md`, `CODEBASE.md`, and
      `README.md` describe the surface.
- [x] Unit tests cover worker-group start/join/failure and cluster
      lifecycle/publish-report behavior.
- [x] Full release matrix on CI: Debug, ReleaseSafe sanitizers, cross-target
      compile, package consumer, and C/C++ ABI checks.

### v2.2.0 checklist (Streaming and Static Assets)

- [x] Chunked and multipart streaming (S-1, S-2) handles 100 MB streams.
      H1/TLS live uploads and H2/H3 live socket-pair proofs pass; multipart has
      a 100 MB logical test.
- [x] `sendfile(2)` and kTLS (S-3, S-4) pass `static-h2`, `static-h3`,
      `static-tls`. Plaintext sendfile and framed static delivery pass; kTLS
      remains the v3.5.0 SB-31 boundary and the external `static-*` profiles are
      re-declared in the [deliberate boundaries](docs/roadmap.md#deliberate-boundaries).
- [x] 100 KiB TLS echo (S-5) passes HttpArena `8gbit`. The TLS echo proof
      passes; the external `8gbit` run is re-declared in the [deliberate boundaries](docs/roadmap.md#deliberate-boundaries).
- [x] lsquic fork migration (2.2-C9): pin `85bd081c` and remove the overlay and
      patch are done; the HTTP/3 cross-implementation gate passes in CI.
- [x] h1spec fork migration (2.2-C10): pin `999ba9e8` and remove the CI patch
      are done; the h1spec gate passes in CI.
- [x] `patches/` and `vendor/lsquic_overlay` are absent from the tracked tree,
      package paths, cache keys, and build graph (2.2-C11).
- [x] ADR 0001 implementation (2.2-C12) is explicitly re-deferred with a
      dated trigger; the capability bits and `SECURITY.md` match the actual
      wire behavior.
- [x] Fork archives and second-machine resolution cover libxev, lsquic, and
      h1spec (2.2-C13). Final archives and second-machine resolution are
      re-declared as release-owner actions in the [deliberate boundaries](docs/roadmap.md#deliberate-boundaries).

### v2.3.0 checklist (`uz.sql`)

- [ ] Module foundation (FS-0) starts/stops the SQL service per worker and
      feature-gates it.
- [ ] PostgreSQL wire parser (D-1) connects and authenticates, including
      SCRAM-SHA-256 and TLS.
- [ ] Per-core pool (D-2, D-3) runs with no locks or cross-thread sharing.
- [ ] Typed rows (D-4, D-9) and transactions (D-7) are bounded and tested.
- [ ] Migrations (D-8) are idempotent and checksum-protected.
- [ ] SQLite (D-6) is optional and links only when enabled.
- [ ] `/db`, `/queries`, `/updates` (D-5) exceed 300K RPS.
- [ ] No request-path allocation; pool and row buffers are startup-owned.
- [ ] `docs/sql.md` and the examples compile.

### v2.4.0 checklist (Comptime SSR Engine)

- [ ] Comptime template parser (H-1) validates models at compile time.
- [ ] SIMD HTML escaper (H-2) beats scalar loops in a measured comparison.
- [ ] `/fortunes` (H-4) renders with exact byte accuracy.

### v2.5.0 checklist (`uz.proto` and gRPC)

- [ ] `uz.proto` (R-0, R-1) passes canonical vectors with no allocation.
- [ ] gRPC framing and trailers (R-2, R-3) conform to the specification.
- [ ] Unary and streaming modes (R-4) map cancellation and status correctly.
- [ ] `unary-grpc` and `unary-grpc-tls` (R-5) pass all iterations.
- [ ] `docs/proto.md` and `docs/grpc.md` are published.
- [ ] R-6.1: `zig-0-17` installed, `zig-0.16` removed, `skills-lock.json` and
      agent prompts updated.
- [ ] R-6: Zig 0.17.0 toolchain pin and migration gates are green.

### v2.5.5 checklist (Follow-up Closure)

- [ ] 11.1.0 preflight: `untangle-codebase` installed, `skills-lock.json` and
      agent prompts updated, one untangle pass recorded.
- [ ] M0 baseline: main at the v2.5.0 release commit; 2.1.6 immutable;
      current libxev pin; clean worktree.
- [ ] M1 XEV-006: timer timespec carry fixed in the libxev fork; scheduler
      workaround removed; all backend views updated.
- [ ] M2 XEV-007: queued-result cancellation has one documented, tested
      meaning; no accepted-fd or read-data loss.
- [ ] M3 scheduler fail-stop and macOS reset-log classification pass.
- [ ] M4 macOS runtime job green with no unexplained skips.
- [ ] M5 full H2/TLS matrix archived with fresh cohorts and listener evidence.
- [ ] M6 lsquic mirror and integration pin are consistent; HTTP/3 gate green.
- [ ] M7 version surfaces, changelog, fork ledger, and 2.5.5 tag/release are
      consistent.
- [ ] No 2.1.6 tag, release, or commit was moved.

### v2.6.0 checklist (Server-Sent Events)

- [ ] SSE session (E-1, E-2) streams over HTTP/1.1 and HTTP/2.
- [ ] Reconnection (E-3) parses `Last-Event-ID`.
- [ ] Slow-client policy (E-4) protects bounded slabs.

### v2.7.0 checklist (`uz.sessions`, `uz.jwt`, and Security)

- [ ] Existing cookie parser and middleware are reused, not duplicated.
- [ ] Sessions (M-1) seal, rotate, expire, and reject tamper/replay.
- [ ] Rate limiter (M-2) keeps exact-oldest eviction and bounded work.
- [ ] CORS and security headers (M-3) emit expected policies.
- [ ] JWT (M-4) verifies HS256/RS256/ES256/EdDSA with an algorithm allowlist.
- [ ] JWKS cache (M-4) is bounded, TLS-verified, and refresh-limited.
- [ ] Session/JWT integration (M-5) has login/logout and protected-route
      examples.
- [ ] Secrets are zeroized and never logged, traced, or labeled.

### v2.8.0 checklist (`uz.metrics` and `uz.trace`)

- [ ] Counters, gauges, and histograms (O-1) track without request contention.
- [ ] `/metrics` (O-2) outputs valid Prometheus/OpenMetrics text.
- [ ] Structured logger (O-3) is bounded, redacted, and non-blocking.
- [ ] Slab and module diagnostics (O-4) warn above 85 percent.
- [ ] `uz.trace` (O-5, O-6) parses/emits W3C context and creates bounded spans.
- [ ] OTLP exporter (O-7) batches, retries, redacts, and flushes on shutdown.
- [ ] A request -> SQL -> S3 -> job trace is visible end to end.
- [ ] No request-path allocation and no blocking export.

### v2.9.0 checklist (High Availability and Multi-OS)

- [ ] Windows carry-over tasks (A-1, A-2) are closed or confirmed already
      closed by v1.9.0 M4.
- [ ] Graceful drain (A-3) emits `GOAWAY` and WebSocket 1001 cleanly under
      load.
- [ ] Zero-downtime socket handoff (A-4) verified with `SO_REUSEPORT` and
      `systemd` socket activation.

### v2.10.0 provisional checklist (`uz.s3`)

- [ ] SigV4 canonicalization and presigned URLs pass golden vectors.
- [ ] get/put/head/delete/list are bounded and tested against a mock S3.
- [ ] A bounded XML error/ListObjectsV2 reader rejects unexpected shapes.
- [ ] Multipart upload completes and aborts correctly.
- [ ] TLS verification, endpoint allowlist, and credential redaction pass.
- [ ] Retries are idempotent-only and bounded.
- [ ] Optional MinIO gate passes or skips with a written reason.
- [ ] `docs/s3.md` and examples compile.

### v2.11.0 provisional checklist (`uz.jobs`)

- [ ] Enqueue-in-transaction commits and rolls back with the caller.
- [ ] Claim uses `FOR UPDATE SKIP LOCKED` or the documented SQLite path.
- [ ] Lease expiry, heartbeat, retry, max attempts, and dead letter pass.
- [ ] Schedules declare overlap and missed-tick policy.
- [ ] Shutdown drains in-flight jobs and releases leases.
- [ ] At-least-once semantics and idempotency are documented.
- [ ] `docs/jobs.md` and examples compile.

### v2.12.0 provisional checklist (`uz.memory_cache`)

- [ ] Fixed-capacity table, value arena, and eviction are bounded.
- [ ] TTL, overwrite, remove, clear, and stats pass.
- [ ] No allocation after init; oversized value fails closed.
- [ ] Per-worker isolation is documented; no shared-cache claim.
- [ ] `docs/cache.md` and examples compile.

### v2.13.0 provisional checklist (Module Integration)

- [ ] `docs/modules.md` lists every module, feature flag, and lifecycle hook.
- [ ] Every module has a runnable recipe and a CI compile test.
- [ ] Disabled modules are absent from the binary.
- [ ] Module boundaries are added to the v3 security register.
- [ ] `README.md`, `docs/roadmap.md`, `docs/api.md`, `docs/memory_model.md`,
      `CI_CD_PIPELINE.md`, and `CHANGELOG.md` are synchronized.
- [ ] No module weakens zero-allocation, shared-nothing, or the C ABI.

### v2.14.0 provisional checklist (MCP Server)

- [ ] OpenAPI metadata carries operation id, summary, description, schemas,
      and MCP overrides.
- [ ] `initialize`, `ping`, `tools/list`, and `tools/call` pass golden tests.
- [ ] Tool calls use the same route, middleware, auth, and trace path as HTTP.
- [ ] Streamable HTTP, SSE progress, sessions, cancellation, and shutdown drain
      pass.
- [ ] Auth, origin, CSRF, rate limits, tool allowlist, and destructive-tool
      policy are documented and tested.
- [ ] No raw arguments, results, secrets, or stack traces leak into logs or
      traces.
- [ ] MCP Inspector/tools-only conformance and `examples/mcp_server.zig` pass.
- [ ] SB-64 is added to the security register and linked.

### v3.0.0 checklist (Security Boundary Baseline)

- [ ] SB-01: every `SECURITY.md` claim has a boundary ID, owner, class, target,
      and proof link.
- [ ] SB-02: threat model covers network, TLS, HTTP, WebSocket, QUIC, router,
      C ABI, and admin boundaries.
- [ ] SB-03: `scripts/check_security_boundaries.sh` fails on incomplete rows
      and runs in lint and release gates.
- [ ] SB-04: dependency inventory, licenses, SBOM, fork provenance, and
      offline archive are recorded.
- [ ] SB-05: private disclosure, CVE, advisory, embargo, credit, and backport
      process is documented and tabletop-tested.
- [ ] Inherited v2.x closures are audited; unsupported claims are reopened.

### v3.1.0 checklist (Event Loop and Platform)

- [ ] SB-06: completion cancel, drain, close, stale-callback, and slot-reuse
      tests pass on io_uring, epoll, kqueue, and IOCP.
- [ ] SB-07: Windows `AcceptEx` and queued-close regressions pass on the native
      `windows-2025` job.
- [ ] SB-08: UDP ancillary data and GRO segmentation pass the HTTP/3 gate.
- [ ] SB-09: signal, async-wake, double-install, and shutdown-race tests pass.
- [ ] SB-10: ASan, UBSan, LSan, and MSan boundary scope is recorded and green.
- [ ] SB-11: backend selection ADR, fallback tests, and introspection decision
      are complete.
- [ ] A 24-hour mixed connect/close/cancel soak completes without leaks or
      stranded slots.

### v3.2.0 checklist (HTTP/1.1 and HTTP/2)

- [ ] SB-12: the smuggling matrix rejects duplicate length, transfer-encoding
      conflicts, folded headers, and ambiguous framing.
- [ ] SB-13: keep-alive, pipelining, half-close, slow-client, and idle-timeout
      tests pass.
- [ ] SB-14: HTTP/2 malformed-frame, HPACK, flow-control, stream-state, and
      8-stream cap tests pass.
- [ ] SB-15: RFC 8441 tunnel and tunnel-exhaustion tests pass.
- [ ] SB-16: h1spec, HTTP/2 compliance, fuzz corpus, and sanitizer runs pass
      without exclusions.
- [ ] Every rejection has a stable reason code and a bounded work path.

### v3.3.0 checklist (WebSocket and Compression)

- [ ] SB-17: handshake, subprotocol, origin, and extension rejection matrix
      passes.
- [ ] SB-18: UTF-8, fragmentation, control-frame, close-code, and malformed
      frame tests pass.
- [ ] SB-19: RFC 7692 negotiation, window-bit, zip-bomb, and decompression
      bound tests pass.
- [ ] SB-20: slow-consumer, write-queue, fan-out, reentrant unsubscribe, and
      pub/sub cap tests pass.
- [ ] SB-21: Autobahn 517/517 and WebSocket fuzz complete with no exclusions.

### v3.4.0 checklist (QUIC and HTTP/3)

- [ ] SB-22: QUIC and HTTP/3 connection, stream, header, body, and packet
      bounds are tested.
- [ ] SB-23: QPACK decoded-header, dynamic-table, blocked-stream, and
      amplification regressions pass.
- [ ] SB-24: GSO transmit and GRO receive segmentation pass with qlog review.
- [ ] SB-25: WebTransport is live and tested, or accepted with a dated
      restoration trigger.
- [ ] SB-26: RFC 10008 QUERY content-type behavior is consistent on H1, H2,
      and H3.
- [ ] SB-27: curl/ngtcp2, aioquic, malformed HTTP/3, and fuzz gates pass.

### v3.5.0 checklist (TLS, Identity, and Secrets)

- [ ] SB-28: certificate verification, trust store, SNI, hostname, and IP
      mismatch tests pass.
- [ ] SB-29: mTLS none, optional, and required modes fail closed correctly.
- [ ] SB-30: 0-RTT replay policy, rotation procedure, and session-resumption
      decision are recorded and tested.
- [ ] SB-31: kTLS is integrated and tested, or accepted with a BoringSSL
      trigger.
- [ ] SB-32: auth, rate-limit, duplicate-header, constant-time, and
      zeroization tests pass.
- [ ] TLS 1.2, hot reload, and kTLS decisions are recorded in ADRs.

### v3.6.0 checklist (Ownership, Router, and C ABI)

- [ ] SB-33: capture, pattern, middleware, duplicate-route, and immutable
      registration tests pass.
- [ ] SB-34: async-token generation, exactly-once, stale, cross-thread,
      disconnect, and deinit tests pass.
- [ ] SB-35: borrowed-slice lifetime and stable-address misuse tests pass.
- [ ] SB-36: C ABI layout, handle, error, callback, and slice-ownership tests
      pass in C and C++.
- [ ] SB-37: fixed-slab capacity, overflow, and refusal tests pass with no hot
      path allocation.
- [ ] SB-38: ASan, LSan, fuzz, and misuse corpus pass.

### v3.7.0 checklist (Outbound Client)

- [ ] SB-39: client TLS verification, trust-store, SNI, hostname, and IP tests
      pass.
- [ ] SB-40: redirect, cookie, proxy, retry, mTLS, and protocol decisions are
      bounded and tested or accepted.
- [ ] SB-41: malformed-server, response smuggling, chunked, and length
      conflict tests pass.
- [ ] SB-42: origin, trust-rule, proxy, and credential pool isolation tests
      pass.
- [ ] SB-43: client fuzz, loopback, timeout, reset, and sanitizer runs pass.

### v3.8.0 checklist (Platform, Operations, and Supply Chain)

- [ ] SB-44: published platform matrix matches CI and support claims.
- [ ] SB-45: deployment capacities, timeouts, descriptors, memlock, seccomp,
      and refusal behavior are documented and tested.
- [ ] SB-46: signal, drain, GOAWAY, WebSocket 1001, QUIC shutdown, and socket
      takeover tests pass.
- [ ] SB-47: SBOM, licenses, dependency provenance, reproducible build, and
      fork archive are complete.
- [ ] SB-48: source-only release, tag, package paths, and consumer evidence
      are verified.
- [ ] SB-49: consumer security guidance is linked from `SECURITY.md` and
      `README.md`.

### v3.9.0 checklist (Assurance and Final Closure)

- [ ] SB-50: full fuzz, sanitizer, compliance, interop, and soak campaign is
      clean.
- [ ] SB-51: external audit or penetration test findings are closed or
      accepted.
- [ ] SB-52: private-disclosure and CVE drill is complete.
- [ ] SB-53: every boundary is Closed or Accept; no Defer lacks a trigger.
- [ ] SB-54: post-release monitoring, review date, and boundary intake are
      recorded.
- [ ] v3.9.0 source-only release tag and evidence manifest are published.
