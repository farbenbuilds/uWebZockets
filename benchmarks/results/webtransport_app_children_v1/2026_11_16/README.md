# Private incoming WebTransport children, 2026-11-16

The candidate Engine now associates peer child streams with an authorized,
generation-checked parent and an optional private receive consumer. It delivers
borrowed payload chunks, tracks prefix-excluded receive accounting, and retains
consumer ownership until native close. RESET, STOP and actual read EOF remain
separate events. No public child registration or transmission API is added.

Classified children awaiting a parent retain existing global stream slots,
with at most four per connection and a real monotonic one-second deadline.
The native backend retains their payload. Session retirement and shutdown
cancel exact identities; callbacks revalidate parent and connection ownership.
Typed refusal uses the coded STOP proposal. Global pool refusal before positive
classification retains the existing generic handling for unresolved streams.
Candidate startup UNI credit covers the three HTTP critical streams plus the
bounded child budget.

The actual App test uses TLS, loopback UDP and xev. An authorized, nonterminal
CONNECT0 admits one incoming UNI carrying ten binary bytes. It verifies exact
payload, the three-byte prefix exclusion, full connection/session identities,
route, one EOF, completed close, final/accounted size, guarded process reentry
and a healthy ordinary HTTP request on the same connection. Original missing
registration, insufficient UNI credit and missing consumer-delivery failures
are retained, together with fixture corrections. This is limited positive
evidence; it does not establish the wider child lifecycle cohort. The selected
case passes in Debug, ReleaseSafe and ReleaseFast, 1/1 tests and 16/16 steps
each, on the same frozen 257 inputs. All 33 existing App admission/datagram
tests also pass in Debug against that implementation, in 16/16 steps.

All 1035 centralized functional tests pass in 20/20 steps. ReleaseSafe test
compilation and the ReleaseFast library each pass in 21/21 steps. Eleven pure
child-lifecycle cases pass in Debug, ReleaseSafe and ReleaseFast. Formatting
leaves all 300 retained source/build inputs unchanged; conventions, release
metadata and whitespace checks pass. Independent source and structural reviews
have no required findings.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
internal `files.sha256`. The retained handoff records exact native inputs,
commands, clock domains, results and remaining work. The native candidate is
lsquic `530e9e505eb04a0a4095b290f7eb052504ace94e` with libxev
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`. Their production pins and capability
activation remain unchanged.

Actual-App BIDI, early-child expiry/exhaustion, RESET/STOP ordering, parent
teardown and callback shutdown coverage remain required. Public child I/O,
application transmission, multi-session flow accounting, independent-client
acceptance, fork publication and the other v2.3.0 gates remain open. Smoke and
dedicated security campaigns are deferred by the user.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `9660478a7079937c6ec010a209a1ec2a8fc4c6574f0d8f5497fafca3b77c619d`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
