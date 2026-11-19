# Frozen v2.3.0 scope

The user froze release scope on 2026-11-18 at commit `2538055`.
The authoritative checklist is [todo.md](todo.md): 70 existing top-level
entries, 63 complete and seven open at that point. Keep that denominator fixed.
These identifiers index the existing open entries; they add no acceptance work.

On 2026-11-19 the user explicitly accepted the World `/db`, `/queries`, and
`/updates` throughput task as done after reviewing its below-target results.
That owner acceptance waives the original above-300K RPS criterion for this
World checklist item only. It supplies no measured throughput pass and does
not close the separate async-db requirement or any other release criterion.
Frozen benchmark reports retain their measurement-time status; this later
owner acceptance changes the current checklist status only.

| ID | Existing open requirement |
| --- | --- |
| R1 | D-5: official external HttpArena adapter activation. |
| R2 | D-5: retain the separately required real async-db result above 300K RPS with full provenance. World endpoint throughput is closed by the explicit owner acceptance above. |
| R3 | D-10: strict total PostgreSQL TLS allocation gate, including complete native ownership, maintained publication/pins and production integration. |
| R4 | Eliminate remaining request-path TLS control allocations and verify the maintained integrated native solution under unchanged accounting. |
| R5 | Every required release gate passes; retain the listed open acceptance evidence and explicit user-deferred campaign status. |
| R6 | Complete independent draft-16 acceptance, reviewed fork publication and the remaining full release requirements. |
| R7 | Publish reviewed native histories through maintained-fork integration PRs, update all four manifest views and verify normal-build activation. |

Preserve the full wording and conditions in the original checklist, roadmap,
release checklist and referenced evidence. A short row in this index does not
replace them. Necessary correctness fixes, capacity proofs, verification and
integration remain current work. Except for the specific World acceptance
above, close an entry only when authoritative evidence proves its original
acceptance criteria.

Record implementation checkpoints as notes under the applicable existing
requirement. Certificate/crypto ownership belongs to R3 and R4. A prerequisite,
proposal, local test or unpublished source checkpoint does not complete either.
Retain the original full worker intervals and the strict RED result until the
complete required implementation passes.

Put genuinely new features, optional refactors and additional requirements in
[next_version.md](next_version.md). Do not silently move unfinished v2.3.0 work
there. SQLite's approved SQL-ALLOC-001 exception and the user's existing test
deferrals remain unchanged.

On 2026-11-18 the user additionally deferred tasks blocked by the Daybreak
safeguard to the next version. Record the exact affected work and missing
evidence in that file; this deferral supplies no passing allocation result.
All affected allocation-ownership work and dependent probes are for the user
to handle later. Do not retry them or open another dependent task as a substitute;
resume only on the user's explicit request.

## Current delivery status, 2026-11-19

The user closed the D-5 World throughput task by owner acceptance on
2026-11-19. Other implementation stays paused, and the Daybreak-dependent
work stays deferred for the user.
The earlier plaintext receive candidate has no isolated retention result.
The user separately authorized permitted allocation verification. Its
current-source supplied-Zig-allocator proof passes, with no production or
native source change and no resumption of Daybreak-dependent work.

| ID | Evidence and remaining action |
| --- | --- |
| R1 | The retained HttpArena adapter matches the local helper. Official activation still needs the reviewed release commit/package hash and the external owner's build, validation and run. |
| R2 | World throughput is owner-accepted at best observed medians of 174,419/49,899/12,905 RPS for `/db`/`/queries?count=20`/`/updates?count=20`; its original measured target remains unmet. The separate async-db comparison reaches 51,741 with default `auto` and 60,779 with `force_generic_plan`. R2 remains open for that separate async-db requirement. |
| R3, R4 | Current-source plaintext tests verify startup-owned buffers and zero calls through the supplied Zig allocator in the exercised paths. The complete native/C/TLS allocation requirement remains unresolved/RED; Daybreak-dependent work stays deferred for the user. No PostgreSQL exception is approved. |
| R5 | Local ordinary verification is retained. User-deferred campaigns, native platform and second-machine checks, quiet-host evidence and the listed release-owner decisions remain unresolved. |
| R6 | Independent public-App candidate acceptance is retained. Published fork integration, normal-build activation and the remaining release evidence are still required. |
| R7 | Reviewed publication histories and compatible fixes are retained locally. Maintainer integration, all four manifest updates and normal-build verification remain pending. GitHub connection/API checks are stopped at the user's request. |

The [permitted allocation ownership proof](../benchmarks/results/sql_zig_allocation_ownership_v1/2026_11_19/README.md)
retains four focused groups and 1,202 ordinary passes with seven explicit
skips. Each tested `Db` has three startup allocations and three matching frees after
drain; the armed plaintext query/row/queue/cancel/reconnect/recovery and World
handler cases make zero allocation, resize, remap or free calls to the supplied
Zig allocator. Fixed buffer and pool geometry is preserved. The World response
target and outer Context ownership are explicitly scoped; no end-to-end socket
HTTP, native/C/TLS, alternate-allocator, kernel/server or process-wide allocation
pass is claimed. The master checkbox and R3/R4 stay open.

The [paired query-latency evidence](../benchmarks/results/sql_httparena_query_latency_v1/2026_11_18/README.md)
retains 975,981 successful query triples inside conservative active-load windows.
Its matched control and isolated instrumented build reach 49,276 and 49,262
median RPS. SDK admission, assigned service and total query latency are now
measured under HTTP load. Production sources are unchanged and R2 stays open.

The [World query-chunk comparison](../benchmarks/results/sql_world_queries_chunk_v1/2026_11_19/README.md)
retains at most 16 individually bound reads per submission through the existing
SDK. Median HTTP p99 improves from 27.792 to 9.225 ms, all three throughput
pairs improve, and exact responses and database counters reconcile. Ordinary
verification passes 1,191 tests with seven explicit skips. Historical host
screening used trust authentication and is not this matched SCRAM control.
Counts and measured results are unchanged. Owner acceptance changes the World
checklist status only; R2 stays open for the separate async-db requirement.

The [World update-chunk comparison](../benchmarks/results/sql_world_updates_chunk_v1/2026_11_19/README.md)
retains at most eight real SELECT/UPDATE pairs per implicit transaction, stable lock
ordering and every duplicate write. HTTP p99 improves from 69.928 to 25.855 ms.
All 600 fixed responses reconcile with writes and persisted values, and all
six timed arms have zero errors or rollbacks. Ordinary verification passes
1,198 tests with seven explicit skips; the controlled HTTP and real lock-order
tests also pass. The example documents its changed transaction boundaries and
possible committed writes after failure. Physical history and automatic
maintenance differ across arms and are recorded. The 300K target remains unmet.

The [World capacity screen](../benchmarks/results/sql_world_capacity_v1/2026_11_19/README.md)
keeps the accepted executable, SQL work, 12 workers, 96 SQL sessions, SCRAM,
default plan policy and durability settings fixed. Three repetitions per route
compare 96/192/384 HTTP connections with four load-generator threads and
192 connections with eight threads. All 39 cases pass validation and cleanup;
all 36 timed samples remain below 300K. The best observed route medians use
different profiles. At unchanged measured app/PG CPU cost, the target would
consume approximately 35/149/528 CPU-seconds per wall second respectively,
before load generation, on this 28-logical-CPU host. This projection neither
establishes an absolute ceiling nor guarantees a larger configuration will
pass. No larger-host passing result was obtained before owner acceptance.
R2 stays open for the separate async-db requirement.

A subsequent [pool-dispatch comparison](../benchmarks/results/sql_pool_dispatch_v1/2026_11_19/README.md)
measured 47,744 control and 48,072 candidate median RPS. Throughput and CPU
changes varied in direction, and p99 was worse in two pairs. The candidate was
reverted because the measurements did not establish a repeatable benefit.
This experiment leaves the required throughput result absent.

The [PostgreSQL planning diagnostics](../benchmarks/results/sql_pg_planning_v1/2026_11_19/README.md)
record one planner invocation per timed call under tracking. Their mean
planner and executor hook times are 152.748 and 279.867 microseconds per call.
These are elapsed diagnostic averages. Diagnostic throughput and CPU differed
beyond observed normal-run variation, so they do not establish untracked
planning costs. The normal control reached 48,079 median RPS; R2 remains open.

The [single-cluster plan-policy comparison](../benchmarks/results/sql_plan_policy_v1/2026_11_19/README.md)
kept the same application, bound SQL, dataset and request mix. The
`force_generic_plan` policy improved throughput in all three pairs, from
51,741 to 60,779 median RPS,
with lower PostgreSQL CPU per response and HTTP p99. This is a net local
server-policy result. The default was restored; no SDK policy changed and
the result remains below 300K RPS.

The [HttpArena handoff](../benchmarks/results/httparena_adapter_v1/2026_11_11/README.md),
[SQL measurements](../benchmarks/results/sql_local_v1/2026_11_11/README.md),
[current async-db measurements](../benchmarks/results/sql_httparena_local_v1/2026_11_18/README.md),
[public-client acceptance](../benchmarks/results/webtransport_independent_client_v1/2026_11_17/README.md),
[publication preparation](../benchmarks/results/dependency_publication_v2_3/2026_11_17/README.md)
and subsequent
[compatible fixes](../benchmarks/results/lsquic_compatible_fixes_v1/2026_11_17/README.md)
retain their exact scopes and source identities. Historical preparation notes
do not supersede later fixes or establish publication. No remaining requirement
is marked complete by this status index.
