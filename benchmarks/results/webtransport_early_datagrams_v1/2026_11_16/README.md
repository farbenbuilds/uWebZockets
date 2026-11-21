# Bounded early WebTransport datagrams, 2026-11-16

The private candidate now buffers datagrams arriving before their CONNECT
session is admitted. Startup-owned metadata, terminal-ID and payload slabs
provide a global budget of four entries per engine connection and a quota of
four per connection generation. Replay preserves per-session FIFO after
authorization, establishment and header release. Entries expire after one
second of supplied monotonic awake time; established dispatch adds no clock
read or allocation.

Exact-key retirement purges HTTP, refused, cancelled and closed identities.
Terminal identities never evict while their generation lives; budget
exhaustion disables new unknown buffering only on the affected connection.
Earlier queued future-session data survives another session's Close and can
replay after admission. Connection reuse clears both stores, and callback
cooldown stops replay and clears pending data. Local dispatch ordinals are
assigned at eligible delivery attempts, including full-ring drops.

The fresh published-dependency suite passes 1009/1009 tests in 20/20 steps.
ReleaseSafe test compilation and the ReleaseFast library each pass 21/21.
Sixteen isolated pure queue tests pass in all three modes. The actual native
cohort passes 33 Zig tests in Debug, ReleaseSafe and ReleaseFast, 16/16 steps
per mode: 32 functional cases plus one import-discovery anchor.

Native coverage includes pre-CONNECT and held-SETTINGS replay, FIFO and quotas,
real 1201-byte arrival against a configured1200 bound, OS-awake expiry,
future-session preservation, refusal/ordinary HTTP/RESET/STOP/Close cleanup,
connection generation reuse, exhaustion isolation and callback-triggered
cooldown. RESET-known-before-notification suppresses an already established
session's datagram without consuming an ordinal and preserves the future
session's payload.

The native RED received A/B before any client-bidi stream, then authorized
CONNECT0 but replayed zero callbacks instead of two. An implementation RED
exposed a real payload-unit mistake: the entire connection ring span was used
instead of one payload's stride. The correction is independently reviewed.
The archive retains both failures and the clarified terminal-exhaustion test
expectation, with their original sources and limits.

The fixture's inherited synthetic native scheduling clock is explicitly
separate from production OS-awake expiry. One functional expiry case waits
about 1.1 real awake seconds; pure tests prove exact boundary arithmetic.
Actual native TLS/UDP and documented encrypted-packet ordering seams remain;
no production callback or peer cache was replaced. Independent pure,
integration, changed-work and native-proof reviews have no required findings.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` contains the base commit, complete source
overlay, commands, clock profiles, reviews and scope. The included scaffold
supplies exact libxev inputs; restore lsquic from the separate
[native candidate](../../lsquic_webtransport_children_v1/2026_11_16/README.md).
All tested project/build hashes remained unchanged through final formatting.

Production dependency pins and activation policy remain unchanged. Early child
association, positive App child I/O, multi-session accounting, independent
draft-16 client acceptance and fork publication/pins remain open. Smoke and
security campaigns are deferred by the user. This does not complete v2.3.0.
