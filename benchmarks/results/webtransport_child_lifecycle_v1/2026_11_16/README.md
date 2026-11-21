# Incoming WebTransport child lifecycle, 2026-11-16

The real App/TLS/UDP cohort now covers nine child cases in Debug, ReleaseSafe
and ReleaseFast, 9/9 tests and 16/16 steps each. The existing App cohort also
passes 33/33 in all three modes. These are functional checks; dedicated smoke,
security, sanitizer and fuzz campaigns remain user-deferred.

Coverage includes incoming UNI and BIDI, actual empty reverse BIDI EOF,
pre-CONNECT buffered bytes, held SETTINGS, fragmented payload delivery, large
session IDs and real monotonic expiry. A non-consuming native preview proves
payload was buffered before authorization. Expiry checks prove the child was
waiting, reserved, and unreset before its recorded one-second deadline.

Capacity cases retain four children on one connection while rejecting a fifth
FIN-bearing child with the exact code and preserving a sibling connection.
Global exhaustion fills all eight Root slots across three connections while
the rejected connection remains below its own quota. The original path queried
metadata during a native constructor publication gap and sent legacy `256`.
Root now defers that peer-UNI refusal to a typed callback, validates fresh
metadata and rejects without allocating a sidecar.

A prefix-only FIN exposed an orphaned native receive half when coded STOP
returned CLOSED. Root now finishes that half. Read-only native lookup from a
fresh, live retained anchor verifies six such streams disappear without
aborting their connection. Creation beyond the original UNI credit proves
actual credit recovery. Another case proves Close0 plus FIN cancels its owned
child while another connection's SID0 and buffered future SID4 survive; real
CONNECT4 then admits those bytes under a new parent generation. Abort/reuse
retains unknown final size, drains old ownership and uses a new connection
generation. Root now distinguishes connection abort from session teardown
before recording the first immutable close cause.

Crossing initial credit exposed a separate native half-window deadlock: three
critical and three retained streams left too few transient streams to trigger
replenishment. Unpublished proposal `005ab244169f269689e511d6b77dd2187e318df1`,
based on `530e9e505eb04a0a4095b290f7eb052504ace94e`, schedules peer UNI credit
on close only in the opt-in HTTP WT profile. It retains the coalesced send flag
and `closed + configured window` bound. Initial credit is unchanged. All 65
existing native WT scenarios and 83 upstream Debug executables pass.

Root passes all 1035 functional tests, ReleaseSafe test compilation and the
ReleaseFast library, formatting, conventions and version checks. Independent
changed-work reviews are clear. Verify `manifest.sha256`, extract the archive,
then verify its internal `files.sha256`; the handoff retains complete proposal
source/history, exact fixtures, original failures, commands and source hashes.
The independently extracted source snapshot also builds and passes all nine
Debug cases through its relocatable replay script; the archive retains the log.

The native scheduling clock is synthetic; App expiry uses real awake time.
The client has 16 historical stream records; Root capacity remains eight.
The new teardown case sends Close with FIN and does not prove child cancellation
before parent FIN. Callback shutdown, broader child RESET/STOP ordering, public
child I/O/TX, multi-session flow accounting, independent-client acceptance and
publication remain open. Production dependency pins and activation are unchanged;
this checkpoint does not complete v2.3.0.
