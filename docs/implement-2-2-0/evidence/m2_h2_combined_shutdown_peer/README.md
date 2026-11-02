# Shared shutdown peer source evidence

The [archive](combined-shutdown-peer.tar.gz) contains the reviewed independent
shutdown peer and DATA-order correction. See the
[report](../../m2_h2_combined_shutdown_peer.md) and [manifest](manifest.json).

SHA-256: `d8d2f3a5b78668539bbdc995a5d071cbe1bd9acd3f635542afe09bbc9e2c6f24`.
The deterministic archive is 1192854 bytes with 683 regular UTF-8 members,
including the inventory for the other 682. Reopened bytes match exactly.

- `source/current/`: all 39 approved modules after the metadata-order fix.
- `history/disconnect-coordinator-source/`: preceding 39-module source.
- `raw/coordinator-shutdown-peer/`: fresh 5695-file prior map, baseline,
  intermediate/final/fix snapshots, further 333-file pre-fix unit map, exact
  current commands/results, regressions, structure and identity audits.
- `reference/`: inherited immutable source/model/fixture/codecs and licenses.
- `evidence/`: contracts, reports, initial and scoped reviews/diffs, Root
  audits and builder.

Four current fix-round results are distinct from preceding final4/final3/final2/
final checks. Initial RED is missing constructor API; read-limit and premature
DATA REDs demonstrate actual behavior before their fixes. The barrier diagnostic
is posthoc. The pending seam RED identifies unavailable test access; serialized
capacity proof uses deliberately faulty early responses, with repeated boundary
proof through the shared helper. Baseline/intermediate command receipts remain
missing and are not reconstructed. Historical hashes do not imply every earlier
raw file is republished.

Supplied prior fixtures do not prove prior wire execution. This is peer
preparation; shutdown coordinator/default/all40/native/runtime/adoption and
milestone gates remain open. All lifecycle facts remain synthetic.
