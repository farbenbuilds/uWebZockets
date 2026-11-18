# Frozen v2.3.0 scope

The user froze release scope on 2026-11-18 at commit `2538055`.
The authoritative checklist is [todo.md](todo.md): 70 existing top-level
entries, 63 complete and seven open at that point. Keep that denominator fixed.
These identifiers index the existing open entries; they add no acceptance work.

| ID | Existing open requirement |
| --- | --- |
| R1 | D-5: official external HttpArena adapter activation. |
| R2 | D-5: retained real async-db result above 300K RPS with full provenance. |
| R3 | D-10: strict total PostgreSQL TLS allocation gate, including complete native ownership, maintained publication/pins and production integration. |
| R4 | Eliminate remaining request-path TLS control allocations and verify the maintained integrated native solution under unchanged accounting. |
| R5 | Every required release gate passes; retain the listed open acceptance evidence and explicit user-deferred campaign status. |
| R6 | Complete independent draft-16 acceptance, reviewed fork publication and the remaining full release requirements. |
| R7 | Publish reviewed native histories through maintained-fork integration PRs, update all four manifest views and verify normal-build activation. |

Preserve the full wording and conditions in the original checklist, roadmap,
release checklist and referenced evidence. A short row in this index does not
replace them. Necessary correctness fixes, capacity proofs, verification and
integration remain current work. Close an entry only when authoritative
evidence proves its original acceptance criteria.

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

## Current delivery status, 2026-11-18

| ID | Evidence and remaining action |
| --- | --- |
| R1 | The retained HttpArena adapter matches the local helper. Official activation still needs the reviewed release commit/package hash and the external owner's build, validation and run. |
| R2 | The retained local `/db` cohort reaches 112,674 median RPS. This is not an `async-db` acceptance result; the required real result above 300K RPS remains absent. |
| R3, R4 | The Daybreak-dependent allocation work is deferred for the user in the next-version TODO. The strict PostgreSQL allocation result remains RED; no PostgreSQL exception is approved. |
| R5 | Local ordinary verification is retained. User-deferred campaigns, native platform and second-machine checks, quiet-host evidence and the listed release-owner decisions remain unresolved. |
| R6 | Independent public-App candidate acceptance is retained. Published fork integration, normal-build activation and the remaining release evidence are still required. |
| R7 | Reviewed publication histories and compatible fixes are retained locally. Maintainer integration, all four manifest updates and normal-build verification remain pending. GitHub connection/API checks are stopped at the user's request. |

The [HttpArena handoff](../benchmarks/results/httparena_adapter_v1/2026_11_11/README.md),
[SQL measurements](../benchmarks/results/sql_local_v1/2026_11_11/README.md),
[public-client acceptance](../benchmarks/results/webtransport_independent_client_v1/2026_11_17/README.md),
[publication preparation](../benchmarks/results/dependency_publication_v2_3/2026_11_17/README.md)
and subsequent
[compatible fixes](../benchmarks/results/lsquic_compatible_fixes_v1/2026_11_17/README.md)
retain their exact scopes and source identities. Historical preparation notes
do not supersede later fixes or establish publication. No remaining requirement
is marked complete by this status index.
