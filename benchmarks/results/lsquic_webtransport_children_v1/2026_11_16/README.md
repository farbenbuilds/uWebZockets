# Native WebTransport child streams, 2026-11-16

The reviewed local proposal is frozen at
`2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`, following the
[incomplete checkpoint](../../lsquic_webtransport_children_checkpoint_v1/2026_11_16/README.md).
Its bundle retains both subsequent fix commits. Root production sources,
dependency pins and capability declarations remain unchanged.

The slice provides native raw UNI/BIDI creation, full-width association and
directional prefix metadata, incremental classification, and reset-prefix
protection. Reset/STOP callbacks follow typed publication; rejected negotiation
finishes cancelled children. Forbidden lengthless WT_STREAM signals fail at
type completion, following [draft-16 section 4.3](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-16.html#section-4.3).
Existing children survive GOAWAY while new HTTP requests are
rejected, including a complete zero-length frame plus FIN without escalation
to a connection error. Default-off control-frame behavior is preserved.

All 65 focused encrypted-engine scenarios pass Debug, ReleaseSafe and
ReleaseFast (195 executions). All 83 upstream Linux Debug cases pass in
165/165 build steps. Windows GNU and macOS ARM64 production libraries compile
in 9/9 steps each; no foreign runtime execution is claimed. Independent
lifecycle and API reviews have no remaining required findings in the reviewed
source. Commands, original RED/GREEN logs and exact final source hashes are
retained; earlier setup failures and unavailable intermediate versions are
identified explicitly.

Compiler-derived ABI evidence records `stream_if` growing from 128 to 136 bytes
with old offsets preserved, `stream_info` occupying 24 bytes and eight additional
private stream bytes.
Consumers and library must rebuild together. The probes cover three targets;
full IETF connection size was not measured.

Child-specific loss campaigns, asymmetric resumption, independent compatible
client acceptance, bounded Zig integration and maintained-fork publication/pin
updates remain open. Smoke/security verification remains deferred by the user.
This local functional slice does not complete WebTransport or v2.3.0.

Verify manifest.sha256, extract raw_evidence_archive.tgz, then verify
files.sha256 inside. HANDOFF.md describes offline recovery, scope and evidence
limits. Bundle import, source comparison and Git fsck passed. No dependency
caches, binaries or generated fixture private keys are archived.
