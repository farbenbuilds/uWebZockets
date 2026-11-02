# Shared core peer source evidence

This [archive](combined-core-peer.tar.gz) contains the reviewed bounded
buffered/large-upload peer and its driver proofs. See the
[checkpoint report](../../m2_h2_combined_core_peer.md) and
[manifest](manifest.json) for the exact scope.

Archive SHA-256:
`dbcd7a01a56a3c80600aa39fa7b61dec00060976c14a82e2bd4a712a2520d25d`.
It contains 481 regular UTF-8 files, including an inventory for the other 480.
The deterministic gzip/tar archive is 802944 bytes; all reopened member bytes
match their inventory. It contains source and text evidence only.

- `source/current/`: all 38 current modules.
- `history/coordinator-ready-source/`: preceding 37-module source.
- `raw/core-peer/`: before/intermediate/current snapshots, exact commands,
  stdout/stderr/exits, REDs, audit helpers and preserved evidence hash map.
- `reference/`: retained immutable source, model, fixture, codec and license
  inputs inherited from the preceding checkpoint.
- `evidence/`: requirements, architecture/addendum, implementation/review
  reports, full diff, Root audits and publication builder.

Six current normal/optimized checks are separate from six earlier checks and
three baseline commands. A real forged-prior-count factory failure is separate
from the initial missing-API failure; neither is described as a serialized
stream regression. Audit-recorder corrections and a Root import-check harness
failure remain recorded. The 4170 earlier evidence hashes are preserved; this
archive does not duplicate every earlier raw artifact.

All supplied ownership, TLS and lifecycle facts are synthetic. These are
in-memory codec/driver proofs, not native execution, multi-case coordinator
acceptance, default/all40 acceptance, production adoption or milestone closure.
