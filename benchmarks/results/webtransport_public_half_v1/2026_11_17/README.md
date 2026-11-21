# Public WebTransport STOP/RESET checkpoint

Source: `3b4a98dfb60667b1dd431e02d4cffb9a4a19764a`.
Date: 2026-11-17, Asia/Bangkok. Production dependency pins are unchanged.
This checkpoint does not complete v2.3.0.

Local STOP abandons receiving while sending remains open. It suppresses further
payload, EOF and receive-reset callbacks while retaining final-size accounting
and independent peer STOP notification. Local RESET ends only sending. Each half
retains its first accepted application error; later whole cancellation fills
only missing intents. Repeated identical requests require no new wake.

The actual App/TLS/native cohort passes **51/51** in Debug, ReleaseSafe and
ReleaseFast, 16/16 steps each: 37 unchanged receive/transmit cases and 14 new
half-control cases. These prove exact peer-visible mapped codes, opposite-half
progress, callback reentry, both whole-cancel fill orders, wake rollback, and
handle/direction/FIN guards. The buffered STOP case proves a 3072-byte prebuffer
delivers only its first 2048-byte chunk while preserving complete final accounting.
No C fixture source or existing assertion changed.

Root passes 1063/1063 ordinary functional tests, ReleaseSafe test compilation,
ReleaseFast library and downstream package-consumer checks. Formatting,
conventions, version, diff and graph-update checks pass. Independent source and
test reviews found no actionable issues.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, and verify the
internal `files.sha256`. The archive contains 36 hashed fixture inputs, 257
hashed Root source/build inputs, RED and intermediate logs, the final matrix,
Root verification and a script-relative replay. Final native logs are
`evidence/Debug.log`, `evidence/ReleaseSafe.log` and `evidence/ReleaseFast.log`.
The fixture README gives explicit compiler, native, XEV and package-cache paths.
A separately relocated delivery copy also passes all 51 Debug cases through
that replay; its log is retained under `root/relocated-replay.log`.

Native `005ab244169f269689e511d6b77dd2187e318df1` and XEV
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5` remain unpublished proposals.
Their source/history and the actual hpack input distinction are retained in the
[lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).
No upstream native allocation-free claim is made.

New half-control cases manually service the engine; loop-only wake progress is
covered by the retained transmit regression. Native half-control BLOCKED,
INVALID and UNSUPPORTED returns and actual OS submission failures were not
forced. Outgoing children, positive/multi-session flow, independent draft-16
acceptance, dependency publication and remaining release gates stay open.
Dedicated smoke/security/sanitizer/fuzz campaigns remain user-deferred.
