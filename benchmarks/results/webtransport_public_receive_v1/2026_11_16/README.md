# Public WebTransport receive checkpoint

Source commit: `7ecfc6b9285779e89b99a95dc910efa8f8403c46`.
Execution date: 2026-11-16 UTC (local runs continued on 2026-11-17).
This checkpoint does not complete v2.3.0 or activate the published backend.

Applications can register child receive callbacks without a private consumer
injection or dummy datagram handler. One immutable sixteen-path endpoint table
combines independent stream/datagram capabilities. Stream-only startup owns
terminal identities without datagram queue/payload allocations. Explicit
CONNECT authorization and Origin policy remain required.

Public stream/session handles retain App and owner generations. Operations
reject foreign, stale and not-yet-accepted handles; stream admission never
wraps its generation. Cancellation retains its code. BIDI receive EOF/reset
leaves sending independent until explicit finish. Session notifications use
captured route identity after parent invalidation and preserve CLOSE_SESSION
application codes. Accepted children receive one eventual close notification.

The actual public App cohort passes **26/26** cases in each of Debug,
ReleaseSafe and ReleaseFast (16/16 build steps per mode). Its 29 source/build
inputs and 255 frozen project inputs match after all modes. Coverage includes
the prior seventeen receive/lifecycle cases, child-only startup, exact handle
error tags and slot reuse, cancellation code 373, two-route isolation,
generation-exhaustion refusal with an existing handle remaining usable,
independent EOF/reset followed by actual peer FIN, Close code 37 before FIN,
admission-callback cooldown and an already-owned sibling at callback shutdown.

Root passes 1049/1049 functional tests, ReleaseSafe test compilation and the
ReleaseFast library on the final source, plus formatting, conventions, release
metadata and diff checks. The public API also compiles through the downstream
consumer and all ReleaseSafe installed examples; those compile records precede
the final internal cause-classification changes. Independent source reviews
and changed-work re-reviews report no required findings.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
internal `files.sha256`. The original archive retained source variants, exact commands,
fixtures, original failures, diagnostic-only compile errors and disk-quota
failure provenance. `fixture/replay.sh` replays the final cohort using explicit
native, XEV, package-cache and compiler inputs. The final source is
`fixture/project_v4`; earlier variants are historical evidence.
An independently extracted copy verifies all 255 project inputs and passes
all 26 Debug cases through that replay script. Its log and archive/source
equivalence record are retained in the final envelope.

Native `005ab244169f269689e511d6b77dd2187e318df1` and XEV
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5` remain unpublished local proposals.
Their complete source/history is retained in the
[prior lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).
That archive also records the actual hpack input versus the native gitlink
distinction. Production dependency pins and live capability policy are unchanged.

The native scheduling clock is synthetic; App expiry uses real awake time.
Root callback dispatch allocates no memory; upstream native buffering has no
allocation-free claim. A deferred-cooldown accepting-phase test did not reach
its intended staging point and is not claimed as proof. Several sibling
attempts failed fixture prerequisites/accounting assumptions, not product
behavior; the archive distinguishes them from actual reset-cause failures.

Public payload writes, writable notifications, outgoing creation, multi-session
flow accounting, independent draft-16 acceptance, publication and the remaining
v2.3.0 release gates stay open. Dedicated smoke/security campaigns remain
deferred by the user.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `40b629cc3e81f39a29d0627eead126a417c2a2f22cd76f7d52defbdcd4b06fac`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
