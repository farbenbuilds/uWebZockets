# Public WebTransport outgoing-stream checkpoint

Source: `a775b461e8e279d1a5d2058c0a2ea06a0c3f2fa7`.
Date: 2026-11-17, Asia/Bangkok. Production dependency pins are unchanged.
This checkpoint does not complete v2.3.0.

`webtransport_stream_create` reserves a global Root stream slot and connection
lease before synchronous native construction. It returns a handle without
running App callbacks inline. The later typed publication invokes ordinary
admission with `initiator.local`; rejection owns no close notification.
Local UNI streams send only, and local BIDI streams receive with prefix zero.
Their writes, FIN, writable notifications and independent half controls use
the existing bounded path. Failed pre-callback attempts release reservations
without consuming a generation, and `WouldBlock` queues no delayed factory work.

The actual App/TLS/native cohort passes **67/67** in Debug, ReleaseSafe and
ReleaseFast, 16/16 steps each. It retains all 51 previous cases and adds sixteen
for binary UNI/BIDI traffic, callback creation, directional controls, prefix
delivery through reset, refusal, shutdown and parent retirement, handle and
reservation guards, and real transport credit recovery. Inherited Zig cases
are unchanged; C fixture changes add pre-engine profiles while preserving
earlier variants and assertions.

The BIDI count-two and UNI count-four profiles reach genuine native blocking
while Root storage remains available. Real stream completion produces wire
MAX_STREAMS credit and permits an explicit retry. The default client's zero
BIDI byte credit separately proves `WouldBlock` with no queued stream or
generation consumption; a stream-count allowance alone cannot send a prefix.

An actual peer-reply failure exposed the server's zero default receive window
for locally initiated BIDI streams. The WebTransport-only configuration now
uses its existing bounded receive capacity. Both Root snapshots, the one-line
fix, exact focused fixture inputs, and RED/GREEN logs are retained. A separate
incorrect new test expectation about pool release after I/O drain was corrected
to observe actual native destruction and retain all production drain assertions.

Root passes 1067/1067 ordinary functional tests, ReleaseSafe test compilation,
ReleaseFast library and downstream consumer checks. Formatting, conventions,
version, diff and graph-update checks pass. Pure metadata tests retain their
own RED/GREEN proof. Independent source and test reviews found no actionable
issues; conflicting fault metadata was corrected before delivery.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
internal `files.sha256`. The original archive contained 39 hashed final fixture inputs,
257 hashed final Root source/build inputs, both Root snapshots, focused
regression inputs, logs and a script-relative replay. The fixture README gives
explicit compiler, native, XEV and offline package paths. Final native logs are
`evidence/Debug.log`, `evidence/ReleaseSafe.log` and `evidence/ReleaseFast.log`.
A relocated delivery copy also passes all 67 Debug cases through the replay;
its log is retained under `root/relocated-replay.log`.

Native `005ab244169f269689e511d6b77dd2187e318df1` and XEV
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5` remain unpublished proposals.
Their source/history and actual hpack input distinction are retained in the
[lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).
No upstream native allocation-free claim is made.

New cases manually service the engine; loop-only wake coverage belongs to the
retained transmit case. Root wake failure and generation exhaustion use explicit
test seams. Native allocation/error-contract faults and actual OS submission
failures were not forced. Positive/multi-session flow, independent draft-16
acceptance, publication and remaining release gates stay open. Dedicated
smoke/security/sanitizer/fuzz campaigns remain user-deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `8bab160e149a443651934a16e01199664f956675e420e2f00254ea7b10badacc`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
