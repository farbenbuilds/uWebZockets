# Coded WebTransport receive cancellation, 2026-11-16

The unpublished native proposal now provides receive cancellation with an
explicit QUIC error. Incoming UNI and both BIDI receive halves are supported;
local writes and their reset error remain independent. The first explicit
code is immutable. Ordinary shutdown retains `HEC_NO_ERROR` (`0x100`), while
explicit numeric zero remains a distinct request.

An unread received FIN still permits coded rejection. Pending STOP emission
and unknown final size retain native ownership; a received reset removes an
unpacketized coded STOP. Default shutdown behavior is preserved. Both the wire
generator and event logger retain full-width error values.

This closes a prerequisite for bounded early-child rejection. Root adds the
typed `stop_receiving` adapter and requires its complete native contract.
Production pins, activation and Engine/App child handling are unchanged.

The final strong-wrapper cohort passes 15/15 tests and 13/13 steps in Debug,
ReleaseSafe and ReleaseFast on identical compiled inputs. Nine STOP cases
cover exact WebTransport rejection, maximum QUIC error, explicit zero, real
reverse BIDI payload and independent RESET, no inline stream callbacks, FIN/RESET
ordering, delayed closure and legacy behavior. Six unchanged receive-ledger
cases remain in the same cohort.

The profile uses two real LSQUIC HTTP/TLS engines and encrypted packets in
bounded in-memory queues, with the inherited synthetic native clock. There is
no UDP/xev/App integration. FIN-unread observation uses the public delayed-close
setting; actual peer credits permit reverse BIDI data.

Six native C cases, 65 existing WebTransport cases and 83 upstream Debug cases
passed before the final event-logging correction. Their original revision and
logs are retained. The correction changes only the logger parameter/format
and adds a capture regression, which passes for the maximum QUIC error and
legacy `256`. The final three-mode cohort uses that corrected source.

The archive retains missing-API and real wire REDs, fixture corrections, the
queued-STOP/reset race RED, and signature/runtime event-log REDs. The initial
wire RED demonstrated a mismatch with the requested full-width error; it did
not establish numeric zero as the legacy error. Independent source, changed
work and strong-proof reviews have no remaining required findings.

Root verification passes 1023/1023 functional tests in 20/20 steps,
ReleaseSafe test compilation and the ReleaseFast library each in 21/21 steps,
plus formatting, conventions and release metadata checks. All 297 retained
project source/build inputs remained unchanged through final checks.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` records exact sources, package identities,
commands and limits. The complete native proposal is commit
`530e9e505eb04a0a4095b290f7eb052504ace94e`, based on
`2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`. Its source and history are retained.
The actual compiled hpack package differs from the native repository gitlink;
the handoff records both without claiming equivalence.

The current CLI viewer has `READ` permission on the maintained fork. Publication and pin
updates remain owner actions. Live child association, byte-consumer delivery,
public child I/O, multi-session accounting, independent-client acceptance and
the other v2.3.0 gates remain open. Smoke and security campaigns are deferred.
