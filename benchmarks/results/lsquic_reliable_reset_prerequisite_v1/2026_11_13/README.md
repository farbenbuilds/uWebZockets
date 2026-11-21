# Reliable reset functional prerequisite, 2026-11-13

The unpublished proposal is frozen at
`3640992bb231d3f0f2647e03fda6a2776fcc23ca`, based on the earlier
[uni-stream prerequisite](../../lsquic_uni_prerequisite_v1/2026_11_11/README.md).
The Git bundle is review material, not a production dependency or overlay.
Root's published lsquic pin and live capability bits are unchanged.

| Functional check | Observed result |
| --- | --- |
| Existing upstream Linux Debug assertions | 83 cases; 165/165 build steps |
| Obsolete ACK/shrink and eight-stream ACK batching | Both sender roles; Debug and ReleaseSafe |
| Reset delivery, HTTP headers, STOP, metadata, API, credit, resumption, codec and parameters | Ten ReleaseSafe regression executables pass |
| Production library cross-compilation | Windows GNU and macOS ARM64 pass; no foreign-runtime claim |
| Native independent quic-go interoperability | Both directions, verified TLS 1.3, reliable prefix 33, reset error 373, healthy siblings |
| Native private layout | Stream 720 -> 760 bytes; alignment 8 unchanged; packet 144, frame record 16 and settings 352 bytes unchanged |
| Independent review | No actionable findings; original unit assertions preserved and strengthened |

The previously failing legacy unit fixtures now model quiescent reset
service. The ACK fixture validates real native ACK records and compares the
observer with actual retained packets and frame records. Its initial setup
failures are retained separately from the passing results. The final commit
changes tests only; production sources match the native interoperability run.

Remaining smoke and security runs are deferred to the user. This does not
complete live WebTransport, maintained-fork integration, or the broader
v2.3.0 release requirements. Early-disabled pre-handshake STREAM queueing
remains outside the ticket-compatibility matrix. No gate is waived by this
archive.

The archive retains the Git bundle, source hashes, native scaffold, layout
probe, review record, complete raw logs and commands. `HANDOFF.md` explains
recovery and evidence limits. Earlier dependency and uni-stream archives
provide its prerequisite history. Binaries, dependency caches and fixture
private keys are excluded.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside the extracted directory.
