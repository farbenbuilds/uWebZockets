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
