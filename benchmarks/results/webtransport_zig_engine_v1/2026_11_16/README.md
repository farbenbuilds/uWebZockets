# Bounded QUIC engine ownership, 2026-11-16

The actual engine now assigns generation-checked connection slots and one
native context per global stream slot. Each stream retains its connection
through a one-shot lease. Closing clears the native pointer and holds the slot
until its last stream releases it. Exhausted generations reject admission;
peer snapshots are cached once. Storage remains linear in the engine budget.

All 971 centralized tests pass in 20/20 steps with published dependencies,
including seven new ownership/classification cases. ReleaseSafe test compilation
and the ReleaseFast library each pass 21/21 steps. Formatting, conventions and
release metadata checks pass. Independent runtime and engine review has no
remaining required findings after the generation-exhaustion correction.

An isolated scaffold imports the actual engine and translated native headers
against candidate `2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`. Two real TLS
tests pass in Debug, ReleaseSafe and ReleaseFast, 16/16 steps each. They exercise
production engine startup, packet processing and UDP transmission, partial and
completed HTTP bodies, exact response bytes, native context identity, lease
release, pending-body abort cleanup and slot reuse. The native callbacks and
server transmission are unchanged. Independent scaffold review found no
remaining actionable findings.

The first complete-body run exposed a scratch-client flush after write shutdown.
The helper now returns the native shutdown result; all payload, closure and
ownership assertions are unchanged. Original inputs, failure log and correction
are retained. A disk-quota failure interrupted the first ReleaseSafe attempt;
only old generated cache was removed before the remaining modes were retried.
No pass is inferred from the interrupted attempt.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` records replay instructions, exact sources,
original commands, failures, reviews and scope. Fresh extraction and every
payload hash were verified. The separately retained
[native candidate](../../lsquic_webtransport_children_v1/2026_11_16/README.md)
supplies the required fork source.

WT negotiation remains off. Positive engine child/session integration, App
admission/routing, capsules, datagrams and compatible-client acceptance remain
open. Smoke/security runs are deferred by the user; compiled smoke targets were
not executed. This ownership slice does not complete WebTransport or v2.3.0.
