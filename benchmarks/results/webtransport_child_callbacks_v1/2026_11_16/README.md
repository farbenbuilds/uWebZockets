# Incoming child callback and reset safety, 2026-11-16

All 17 actual App/TLS/UDP child cases pass in Debug, ReleaseSafe and ReleaseFast,
17/17 tests and 16/16 steps each. The existing App cohort passes 33/33 in
Debug. Root passes all 1035 functional tests, ReleaseSafe test compilation and
the ReleaseFast library, formatting, conventions and version checks.
Independent changed-work reviews have no required findings.

Three genuine failures drove the fixes:

- A data callback aborted its native connection after receiving 2048 bytes,
  but received the remaining buffered bytes afterward. The guard now checks
  native connection status as well as retained lease identity.
- Visible RESET delivered its event but left the native application receive
  half open, so owned close never arrived. A terminal STOP result now shuts
  that half down while preserving the original peer error.
- A waiting child could acquire a consumer after its reset was already visible.
  Association now rechecks cancellation on every attempt. Mere reset knowledge
  remains eligible while reliable bytes still precede reset visibility.

The callback tests stage all 3072 payload bytes and FIN before CONNECT. A native
readability query verifies actual buffered bytes without consuming them; its
hash implementation may refresh derived query cursors. Receive snapshots and
ledger read counts remain unchanged. Open-triggered cooldown delivers zero
bytes; data-triggered cooldown/abort delivers exactly one 2048-byte chunk.
Every owned close accounts the full final payload of 3072. Deferred cooldown,
immediate native abort status, no later data/terminal notifications and drained
leases/counters are checked before cleanup. Declined open owns no close;
declined data cancels only its owned child and preserves ordinary HTTP.

A Close capsule now proves child cancellation before the parent sends FIN,
with actual client send-shutdown state zero before and after child close.
The sibling connection and pending future SID4 survive. Full-width BIDI STOP
still permits incoming data, then a different RESET closes once. A hidden
reliable reset delivers four payload bytes before its reset callback and
accounts the complete twelve-byte final payload once. An already-visible
pending reset never opens a consumer; future SID4 is admitted afterward.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
internal `files.sha256`. An extracted source snapshot also replays all 17 Debug
cases successfully. The archive retains exact program/dependency source,
the original failures and diagnostics, commands, results and reviews. Native
lsquic `005ab244169f269689e511d6b77dd2187e318df1` and libxev
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5` are unchanged. Complete native history
is retained in the preceding
[lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).

Native fixture scheduling uses synthetic time; App expiry uses real awake
time. Production pins and activation remain unchanged. Public child I/O/TX,
multi-session flow accounting, independent-client acceptance and publication
remain open, along with the other v2.3.0 gates. Dedicated smoke, security,
sanitizer and fuzz campaigns remain user-deferred.
