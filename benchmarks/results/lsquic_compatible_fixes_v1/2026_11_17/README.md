# Compatible lsquic fixes and client regression evidence

Root source: `77318a4ef6ae6dc74cfd156ad5a2b4f4bca414fb`.
Original native tip: `ed8f8f7642fbf4fc9399a0a6bb8f90b281e1f300`.
Prepared publication tip: `3d775d801ccf7c9f04e0cc6d33952d81c66dae1f`.
Both final trees: `26b4ecc1d026c2aa21a852c20a3f6d9e0ea7cbeb`.
Production pins and capability flags are unchanged.

LSQ-021 adapts the official [QPACK fix](https://github.com/litespeedtech/lsquic/commit/acd2bb73f681efeb28a7e32e4df1f8af61efbe1e),
preserving WT classification and reliable-prefix ownership. It also prevents
the candidate-only reset-header path from resuming a terminal decoder error.
LSQ-022 follows the official [validated-path fix](https://github.com/litespeedtech/lsquic/commit/c638b57096d6a5bd0d6064382267c261bc7f9de4):
when no eligible unvalidated slot exists, an unknown tuple leaves every stored
validated path intact. The production selection function matches upstream.
No unrelated newer congestion-control code or source-list change is imported.

| Ordinary functional verification | Result |
| --- | --- |
| Final Native Debug assertions | 85 cases; 168/168 steps |
| Retained receive/stream/reset cohorts | Five executables in three modes; 15 successful runs |
| Independent public-App client matrix | Nine cases in three modes; all 27 pass |
| Public server build and route/generation fixture | 20/20 steps and 1/1 tests per mode |
| Root ordinary unit suite on unchanged production source | 1128/1128 tests |
| Independent source, history and runtime reviews | No actionable findings |

Genuine REDs reproduce buffered reads beyond a blocked prefix, terminal QPACK
context replacement during reliable-reset completion, and validated-path
snapshot corruption. Final GREENs preserve exact header ownership, a healthy
same-connection sibling, path identity/metadata, slot masks, IPv4/IPv6 and
client/server HTTP/non-HTTP combinations. Two quota failures are explicitly
classified as infrastructure trials; completed retries supply the evidence.

The public application and official client are unchanged. Only server binary
hashes and source identity fields change in the matrix driver. Independent
review reconciles all 27 rows and 81 raw-log hashes, 39 child identities and
156 callback/ring datagrams, clean zero-error shutdown and TLS/CA/protocol
negotiation. RESET_STREAM_AT wire sizes 3/27 match application code 4660 and
final payload 24. DATA recovery accepts exactly 32 of 4096 bytes before reads,
then delivers the remaining suffix. Credit, isolation and duplicate SID-zero
connection/source namespaces remain covered.

All eighteen historical source mappings remain unchanged. Two complete
source-identical publication equivalents append the fixes with mapped parents
and original-commit metadata. Exact-base incremental imports, strict Git object
validation and two identical twenty-row conversion replays pass. Full follow-on
histories were separately validated; small deltas and the preceding complete
archive reconstruct them without duplicating those large histories here.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
top-level `files.sha256`. The original archive contained source/test snapshots, native
scaffolds, three final Linux server binaries, raw logs, reviews and replay tools.
It requires two already committed artifacts, pinned by exact hashes in
`external_inputs.json`: the prior publication archive supplies full Git bases;
the prior independent-client archive supplies the unchanged client executables.
From the extraction directory, replay with Git and Python 3:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Choose an absent history destination. The relocated Debug replay passes all
nine cases with restored immutable client binaries and fresh private PKI,
which is removed afterward. The wrapper defaults to an unused `replay_v1`;
choose a new `UWZ_RUN_ID` for subsequent runs. Its collision regression and
exact-command GREEN are retained separately from application output logs.
Native source rebuild dependencies and commands
are in `native/HANDOFF.md`; prebuilt replay requires the recorded compatible
Linux host/CPU/ABI. No generated PKI, credentials or build cache is included.
Git/Python remain external verification tools, not library build requirements.

The candidates remain unpublished. Fork permissions, mirror synchronization,
branch protection, assigned/labeled PR review, integration merge, full-commit
pinning and normal-build activation stay open. Dedicated smoke/security/
sanitizer/fuzz/scan campaigns remain user-deferred. Other v2.3.0 requirements
remain open; this checkpoint is not a release.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `2cc14433110726b7d112bee4ad52215f4adfce89f9fbd380dd2822caa20df46d`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
