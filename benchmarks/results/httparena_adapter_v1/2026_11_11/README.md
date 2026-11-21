# Current HttpArena adapter preparation, 2026-11-11

This is a local source proposal and correctness evidence. It does not activate
an official profile, publish benchmark results, or satisfy the unchanged
throughput requirement above 300,000 RPS.

The external source is pinned to HttpArena commit
`5646c1d2a4f4656073430ce55ed39a5c9c2e6749`. Its current `async-db` contract
queries PostgreSQL `items` by price range and returns nested ratings, JSON tags,
and booleans. Its `crud` profile has been removed. The library's World-table
CRUD examples remain separate.

## Proposal

`adapter.patch` in the archive changes only `frameworks/uwebzockets` sources,
build options, and proposed `async`/`async-db` subscriptions. Existing routes
and generated benchmark data are preserved. The patch uses public APIs,
independent worker pools, parameterized SQL, fixed response/request storage,
and the connection-owned timing wheel.

The default database budget of 256 means 32 workers with eight SQL connections
each, independently of CPU count. Per-worker pending admission stays bounded;
healthy overload returns 503. A genuine unavailable database returns the
profile's empty response. Shutdown counters distinguish rendered query results,
empty fallbacks, and rejected responses.

The standalone fixture retains 1,024 connections per worker and a 64 KiB write
queue. Its Linux connection slab is exactly 219,723,392 bytes per worker,
7,031,148,544 bytes across 32 workers, before SQL and context storage. These
are planned startup bytes, not process RSS measurements.

No `DATABASE_URL` is required for the external adapter's baseline and delay
routes. Local checks use the startup-only `UWZ_HTTP_PORT` override; the default
remains 8080. URI brackets are removed from default IPv6 certificate identities,
while DNS verification names retain their spelling.

## Correctness evidence

The test database is PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2), from immutable
image `postgres@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42`.
It contains the unmodified official 100,000-row seed. The fixture permits 272
connections, while the application is configured for 256. No response cache or
synthetic database result is used.

| Check | Result |
| --- | --- |
| Standalone: 32 workers, 256 SQL sockets, 1,024 simultaneous populated requests | Every response has the exact requested item count, valid range and field types; zero empty fallbacks or non-200 responses |
| Final external adapter: native ReleaseSafe and Docker-target static musl ReleaseFast | Each passes the same 1,024 exact populated responses and all 11 current profile checks |
| Current upstream async/database validation blocks | All 11 checks pass for each server; original helpers and blocks retained |
| External adapter without `DATABASE_URL` | Baseline body is correct; all eight upstream delay checks pass; zero SQL sockets |
| Pending-work shutdown | 1,024 requests submitted with 256 PostgreSQL queries confirmed blocked by an owned table lock; application exits 0 with zero rendered/fallback/rejected results; all 32 slot-cleanup assertions pass |
| Recovery | Fresh server accepts populated queries after the prior process drains |
| Real authentication failure | All 32 contexts retain the empty database fallback and working delay route; graceful exit 0 |

The pending-work lock is released after local application drain; all remaining
PostgreSQL connections then disappear. This proves local ownership cleanup,
not immediate server-side cancellation while PostgreSQL is blocked on a lock.
The external adapter retains its existing default SIGTERM termination; graceful
module cleanup is exercised by the standalone public-cluster fixture.

Native application containers use the cached binaries unchanged and an isolated
copy of the host GNU runtime (glibc 2.43). The Musl binary runs directly. Both use
the official runner's resource policy:
`seccomp=unconfined`, unlimited per-process locked memory, and nofile 524,288.
Runtime hashes, limits and descriptors are retained. All 32 standard worker
loops use io_uring. Runtime and executable bodies, ephemeral credentials, and
generated private keys are excluded from the archive.

A first container attempt omitted the official nofile setting and exhausted its
1024-descriptor soft limit. Its raw failure is retained separately; acceptance
was rerun with the official resource setting, without changing the workload or
timeouts. The host's locked-memory limit is 8 MiB; no host-wide limit was changed.

## Remaining integration gates

The proposed exact-active-worker fix additionally covers non-power-of-two
budgets. Its 224-budget regression was reproduced with the previous binary:
16 workers and 128 connections instead of the required 28 and 224. The final
native rebuild passed 18/18 steps and starts exactly 28 workers and 224 SQL
connections, returning the correct 50-item result. The same source also compiles
for static musl ReleaseFast (18/18 steps). Results are recorded in the archive's
`proposal.json`. Do not interpret the earlier validated source snapshot as proof of that later
source change.

The external `build.zig.zon` is intentionally unchanged and still pins 1.8.0.
Before submission, the adapter owner must replace it with the actual reviewed
2.3.0 release's full commit and verified package hash, rebuild from a clean
cache, run the complete upstream validation suite and official benchmark, and
retain their generated artifacts. No release commit or package hash is invented.

These checks execute the unchanged upstream profile blocks in an isolated
harness. They are not the complete upstream Docker validation run. TLS and
HTTP/3 adapter listeners are deliberately disabled with absent certificate
paths during these HTTP-only checks. No TLS/HTTP3 adapter support or performance
claim follows from this artifact. SDK protocol verification is tracked separately.

The archive includes the source proposal, before/after adapter files, exact
validation excerpts, raw request/response records, query summaries, resource
settings, failure diagnostics, fixture seed checksum, binary/source hashes,
and reproduction scripts. `[passed]` means the stated correctness check passed;
it never means the throughput or official-publication gate passed.

## Reproduction notes

The archive's `proposed/` directory contains the adapter files; `fixture/`
contains the unchanged seed/dataset and an isolated setup/cleanup pair.
`library_candidate.tgz` captures the final SDK build inputs, excluding fetched
package caches and generated reports. All dependency URLs and hashes remain
in its manifest. The final external native/musl binaries were built after the
SDK protocol corrections. Earlier standalone lifecycle cohorts retain their
own binary hashes and precede the final HTTP/3-only changes; do not assume
those hashes identify the later final external binaries.

The scripts retain this session's `/tmp` and checkout paths for inspectability.
For replay elsewhere, point the local-build helper at the unpacked `proposed/`
adapter and SDK checkout, run `fixture/setup.sh`, copy the retained scoped
`official-profile-checks.sh` into the newly created fixture directory, and
select the newly built binary paths. `uwz-arena-final-check.py` verifies the
224/28 correction and standard native cohort; `uwz-arena-musl-check.py` runs
the static target. `uwz-arena-queued-check.py` proves blocked-query cleanup.
The setup helper expects a GNU/Linux host runtime compatible with its native
binary; the static musl check needs no GNU runtime wrapper.

After extraction, `python3 scripts/verify_evidence.py` independently checks all
4,096 retained populated responses, the 224-budget regression evidence, source
identity, and checksums. It performs no database or network operations.

The owned PostgreSQL fixture was removed after its application socket count
returned to zero. No agent-owned containers or credential files remain.
