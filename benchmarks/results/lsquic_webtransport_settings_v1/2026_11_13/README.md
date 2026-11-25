# WebTransport SETTINGS prerequisite, 2026-11-13

The unpublished lsquic proposal is frozen at
`8b0ef12414cdcf7b8c20e0b9f4fceb321358c2d0`, following the
[reliable-reset prerequisite](../../lsquic_reliable_reset_prerequisite_v1/2026_11_13/README.md).
It contains separate SETTINGS-generation and peer-publication commits. The
Git bundle is review and reproduction material, never a production dependency
or overlay. Root's published dependency pins and live capabilities are unchanged.

The opt-in writer emits draft-16 SETTINGS with bounded fixed storage. The
peer query publishes an immutable snapshot only after complete SETTINGS and
actual handshake transport parameters. Its optional notification runs outside
stream iterators; error and pending results preserve the caller's output.
The snapshot describes peer advertisements, not session admission.

| Functional check | Observed result |
| --- | --- |
| Configuration and real encrypted SETTINGS generation | Both roles; disabled, zero-flow, nonzero-flow and exact maximum limits; Debug, ReleaseSafe and ReleaseFast |
| Peer query and notification lifecycle | Both roles, asymmetric settings, absent callback, raw QUIC rejection and close inside notification; all three modes |
| Real control-stream delivery | Bytewise SETTINGS, invalid values, duplicates, truncated first frame and fragmented second frame; all three modes |
| Second-frame snapshot regression | First frame explicitly omits flow IDs; unseen DATA in an incomplete second frame cannot change READY bytes; all three modes |
| Pure setting state | Inclusive bounds, duplicate zero values, unknown IDs and replacement of remembered transport support |
| Final upstream Linux Debug assertions | 83 cases; 165/165 build steps |
| Final production library compilation | Windows GNU and macOS ARM64; 9/9 steps each, fixture hooks disabled; no foreign runtime claim |
| Independent review | No remaining actionable findings; second-frame masking gap corrected and re-reviewed |

`HANDOFF.md` and the raw command manifests distinguish generation-only gates
from final peer-publication gates. Public C layout probes record appended
settings/callback fields and unchanged existing offsets; they are compiler
results, not foreign runtime results. Consumers of the proposed C structs
must rebuild when the fork changes.

Smoke and security runs remain deferred to the user. Long-lived CONNECT,
raw child association, directional credit and reset-prefix handling, bounded
Zig session integration, compatible-client acceptance and reviewed fork
publication remain open. This checkpoint does not complete WebTransport or
v2.3.0.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify
`files.sha256` inside the extracted directory. The original archive contained the bundle,
native Zig scaffold, source hashes, reviews and functional logs. Dependency
caches, binaries and generated fixture private keys are excluded.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `72c4d3b07b7002e699a90b3537d0ed8232066ed6b458c4e9ba309c7e94d1deb2`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
