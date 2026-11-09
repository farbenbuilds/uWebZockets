# Canonical final-collection handoff

An optional `bind_collection(context, actual_capture) -> None` callback now
hands the actual canonical collection to the provider before client close or
signaling. The native retry exposed the gap: shutdown collection returned
records and metrics, while the context published those fields only after
process/post validation.

Only `coordinator.py` and `shutdown_cases.py` change. The collector, requests,
parsers, return objects, result schema, barriers, deadlines and termination
ordering remain intact. Without the callback, existing behavior is preserved.
The callback cannot substitute a return value. The provider retains a detached
baseline for the exact bound context and refuses duplicate or missing binding.

## Mutation protection and compatibility

Initial review found that a callback could alter context counters/deadlines,
or replace integer capture values with equal booleans. Genuine regressions
reproduced both defects. The corrected boundary checks builtin context data,
container identities and scalar types before terminal effects. Opaque protocol,
hash and callback objects retain identity protection; their internals are not
deep-frozen. Original callback exceptions propagate unchanged.

Focused, legacy and inert checks pass in normal and optimized Python. All
three original test files remain byte-identical. The unchanged source full40
driver and the hooked composition produce identical complete results and
ordered wire receipts for explicit and genuinely omitted selection in both
modes. These are source/fake-peer results.

Independent review closes both findings. Root independently checked the exact
two-file revision, 44 unchanged canonical modules, three unchanged legacy tests,
5,036 unchanged C8 paths, the exercised source inventory and both accepted C8
binaries. The immutable [source revision](evidence/m2_h2_collection_handoff/manifest.json)
has SHA-256 `8fc6c797a5d481c36b25636df0e909635000e66b7baa25ef52d5ce67b7a8f9ae`.

## Repository checks and evidence

Formatting, conventions, version and dependency checks pass. The first unit
run reached 851/852 before `SIGTERM` terminated the C API ephemeral TLS test.
An unchanged replay with the exact seed `0x240412be` passes 852/852 tests and
22/22 build steps. Independent read-only triage identified no concrete source
defect or signal sender. Both outputs remain recorded; sender attribution is
unproven and should be captured if it recurs. No test or threshold changed.

The [evidence archive](evidence/m2_h2_collection_handoff/README.md) retains the
source, review/fix records and proof history using lossless content references.
Completed local snapshots were deduplicated after their proofs: all 7,583
checked files preserve bytes, modes, ownership and paths. Shared inode times
are qualified; original per-path modification times remain recorded. This
recovered 844,705,792 allocated bytes without removing evidence.

Recorded native-entry refusal shows C8's original strict source gate rejected
the revision before publication. The real provider needs a reviewed override
and four successful native runs after publication. Prior interrupted native
attempts do not establish full40 acceptance. H3, production adoption, broader
platform/release verification and M2 completion remain open.
