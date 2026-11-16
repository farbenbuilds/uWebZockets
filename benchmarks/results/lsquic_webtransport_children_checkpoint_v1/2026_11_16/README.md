# WebTransport child-stream checkpoint, 2026-11-16

The unpublished work-in-progress proposal is saved at
`a1947ce3a4ceeb98413e53014cc87f72b6d89869`, following the
[stream-credit prerequisite](../../lsquic_webtransport_credit_v1/2026_11_13/README.md).
The archive retains its incremental Git bundle, changed source, fixtures,
native Zig scaffold, commands, input hashes and original results.

The proposal adds immediate raw child creation, full-width session metadata,
incremental uni/bidi prefix classification and directional prefix protection
for reliable reset. Native encrypted-engine fixtures exercise real extended
CONNECT, a non-FIN successful response, parent capsules, raw child bytes,
empty FIN, reset/STOP lifetime and fragmented/nonminimal prefixes.

Fresh Debug checks against this exact checkpoint pass 41 focused scenarios:
six normal-child cases, ten reset cases and 25 prefix-classification cases.
One additional `pending-reset` case fails: a reset callback can precede typed
notification while peer SETTINGS remain pending. The failure and assertion
are preserved. This is an incomplete checkpoint, not an accepted prerequisite.
Earlier build-mode and focused upstream results are recorded with their own
source hashes; final full-suite, cross-target and independent review gates
remain open.

Smoke/security runs remain deferred to the user. Native callback ordering,
remaining lifetime/recovery cases, external interoperability, fork publication
and bounded Zig runtime integration still need completion. Root production
sources, dependency pins and capability bits are unchanged. This checkpoint
does not complete WebTransport or v2.3.0.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` gives recovery instructions and evidence
limits. Offline bundle import, source-hash comparison and Git fsck passed.
Some intermediate uncommitted versions are unavailable and explicitly listed;
the exact checkpoint source is retained. Caches, compiled binaries and generated
fixture private keys are excluded.
