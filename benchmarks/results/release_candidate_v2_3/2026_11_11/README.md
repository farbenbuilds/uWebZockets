# v2.3.0 candidate verification, 2026-11-11

The SQL implementation and reviewed ownership/GRO changes are present. This
is an implementation candidate, not a completed release. No merge, release
tag, publication, throughput waiver, or TLS allocation exception is implied.
The requirement ledger is [tasks/todo.md](../../../../tasks/todo.md).

## Retained checks

| Check | Observed result |
| --- | --- |
| Default Debug suite | 958/958 tests; 23/23 build steps |
| PostgreSQL TLS and SQLite, ReleaseSafe | 1,012/1,012 tests; 26/26 steps |
| PostgreSQL TLS and SQLite, ASan/UBSan/LSan | 1,012/1,012 tests; 26/26 steps |
| Enabled SQL/SQLite Windows GNU and macOS cross-compilation | 24/24 steps each; no foreign-runtime claim |
| Four SQL examples | 23/23 build steps |
| SQL feature exclusion | Disabled, PostgreSQL-only, SQLite-enabled, and enabled-but-unused consumers pass |
| Filtered SQL/SQLite package consumer | Clean downstream build passes |
| Required formatting | `zig fmt src builds examples tests fuzz` exits 0 |
| Conventions, release version, documentation links | Each exits 0; metadata agrees on 2.3.0 |
| Working-tree whitespace check | Exits 0 |
| Staged whitespace check | Exits 2 for one upstream SQLite trailing blank line; vendor bytes retain their recorded upstream SHA-256 |
| Dependency-fork check | Exits 1 after confirming libxev/lsquic mirrors and all four pin views; existing h1spec checkout differs from its recorded gitlink |
| Graph refresh | Initial exit 127 resolved by temporary pinned Graphify 0.9.92 install; AST-only `graphify update .` exits 0 |

The raw suite logs include deliberate failure-path diagnostics. Their final
build summaries and process exits establish the stated test results; individual
warnings are not evidence of an extra successful release gate. Debug UDP
cancellation still reaches the known pinned-libxev unexpected-errno path;
the independently reviewed XEV-008 fix remains outside the active dependency.

The enabled sanitizer and cross-target suites precede the three Linux musl
`msg_controllen` casts. Those casts preserve GNU widths. The final native
builds and focused UDP regressions passed after the casts; exact stripped GNU
protocol binaries compare byte-identical before and after them. See the
[protocol evidence](../../protocol_v2_3/2026_11_11/README.md) for the source
snapshots, commands, complete comparisons, final short rechecks, Autobahn
517/517, h1spec 33/33, and expanded HTTP/3 results. This timing is not a claim
that every broad suite was rerun after every documentation edit.

Zig 0.16.0 is `/tmp/zig-x86_64-linux-0.16.0/zig`; local commands use
`ZIG_GLOBAL_CACHE_DIR=/tmp/uwz-zig-cache` and limit build concurrency to two.
`scripts/test_sql.sh` starts an isolated PostgreSQL 17.11 container with
verified TLS and removes its own fixture. Runtime checks require working
local sockets and Docker. Sanitizers use the LLVM 21.1.8 runtime directory
`/tmp/uwz-compiler-rt/usr/lib/llvm-21/lib/clang/21/lib/linux`. The extracted
official package SHA-256 is
`1addf72593c6a53aa1ed9e373af88fb625610ffffa050d23fa871cea95f32f4a`.

## Graph refresh

The CLI version matches both vendored skill version records. It is installed
only under `/tmp/uwz-graphify-tools` and `/tmp/uwz-graphify-bin`; no production
build dependency or skill source changed. The AST-only refresh indexed 2,947
files into 46,554 nodes, 121,399 edges, and 1,212 communities, with no LLM API
calls. Generated `graphify-out/` remains ignored. A subsequent graph query
also exits 0.

The extractor reports 255 files with syntax errors/partial extraction, 261
files with no modeled symbols, and one SQL file skipped because its optional
grammar is absent. These tool limitations do not prove source correctness or
complete semantic coverage. The initial missing-tool check is retained beside
the successful refresh log and exact installed package versions.

## Open release gates

- The [TLS C-allocation audit](../../sql_tls_allocation_v1/2026_11_11/README.md)
  fails the strict allocation gate: two BoringSSL malloc calls per measured
  TLS query. SQL-ALLOC-001 approves only SQLite's upstream allocations.
  Proposed SQL-ALLOC-002 requires a separate explicit decision.
- The [local SQL cohort](../../sql_local_v1/2026_11_11/README.md) peaks at
  112,674 median RPS with 12 workers. The requirement above 300,000 RPS,
  designated quiet-host contracts, and official benchmark remain unmet.
- The [current HttpArena proposal](../../httparena_adapter_v1/2026_11_11/README.md)
  passes independent archive verification of 4,096 seed-matched responses.
  It still needs the actual release commit/hash, complete upstream validation,
  and owner submission. Current upstream removed the historical `crud` profile.
- XEV-008 needs maintained-fork review/merge and a newly reviewed exact pin.
  Current credentials are read-only. No package-cache patch or overlay is used.
- Existing h1spec checkout restoration awaits the user's decision. The
  isolated required pin passed; the user's checkout is preserved.
- WebTransport server/client prerequisites, second-machine fork resolution,
  native Windows release evidence, and the other named Section 8.2 conditions
  remain open. Cross-compilation cannot close them.

## Archive

the original archive contained the eight unedited final suite/consumer
logs, fresh local check outputs and exit codes, the base commit and h1spec
checkout identities, and SHA-256 identities for 327 source/build/test inputs.
It excludes dependency caches, credentials, fixture keys, runtime images and
generated benchmark result bodies. These hashes identify an uncommitted
candidate; the base commit alone does not reproduce it.

The outer `manifest.sha256` covers this README and archive. The archive's
`files.sha256` covers each retained file. Verify after extraction:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `7b05d3e2f37b9a3119a3af5f42ab40b587a08d7cc04ddba70d6544fa400ac450`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
