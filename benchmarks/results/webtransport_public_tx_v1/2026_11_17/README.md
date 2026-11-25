# Public WebTransport peer-BIDI transmission checkpoint

Source: `78fc2d62300c4fdf5cccf57efc3acdb798a1be97`.
Date: 2026-11-17, Asia/Bangkok. Production backend pins and activation are unchanged.
This checkpoint does not complete v2.3.0.

Public writes transfer only the returned prefix. A tracked synchronous native
reader preserves that ownership even if writing or flushing fails afterward.
The caller retains its suffix; Root adds no payload queue. Sending requires
accepted ownership and actual typed publication. Peer STOP disables sending,
while receive EOF/reset remains independent. Writable delivery is explicitly
requested, one-shot and disarmed before callbacks.

A named wake preflight reserves future service before native mutation. External
requests coalesce through the existing UDP timer/cancellation pair; processing
never runs inline. Both completions retire before timer reuse, and requests
inside current engine processing cannot create a zero-delay wake loop.

The actual TLS/App/native cohort passes **37/37** in Debug, ReleaseSafe and
ReleaseFast, 16/16 steps each. Its original RX26 sources are unchanged. The
eleven TX cases include binary echo, stream credit 4096 with payload 8192,
connection credit 16384 with stream credit 65536 and payload 32768, real native
read-driven credit recovery, suffix-only retries, accepted-buffer overwriting,
one-shot rearming/no-spin, TX after RX EOF/reset, RX after STOP, public callback
shutdown and an explicitly injected Root wake-callback failure.

The loop-only case stages an actual UDP timer at least 500 ms away before
separate outside-callback write, writable-interest and later finish operations.
Each progresses before 250 ms without manual Root processing or new client
sends; Root decrypted-input statistics remain unchanged during observation.
The fixture preserves its 512-byte request bound and uses a separate fixed
65536-byte receive capture. It never uses private flow-credit grants.

The UDP seam passes 8/8 real-loop/fake-engine tests in all three modes on
io_uring, including actual timer expiry with cancellation outstanding. The
published-XEV epoll run passes seven tests and skips the io_uring-specific one.
Writer fault tests exercise actual Root reader callbacks under injected
consume-then-error, flush failure and stale errno; the selected native unit
cohort passes 11/11 in all modes. These are boundary fault tests, not a claim
that an actual native allocation/flush failure or OS submission failure ran.

Root passes 1063/1063 functional tests, ReleaseSafe test compilation, ReleaseFast
library, downstream consumer, all ReleaseSafe installed examples and Windows/
macOS library cross-compilation. Formatting, conventions, version and diff
checks pass. The first macOS archive check used system-ar fallback metadata;
the unchanged checker passes with its preferred Zig ar. Cross-compilation is
not kqueue/IOCP runtime proof. Independent changed-work reviews are clear.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
internal `files.sha256`. `fixture/replay.sh` uses script-relative `project_v2`
and explicit Zig, package cache, native005 and XEV5b2c inputs. The archive
retains 33 native run inputs, 257 Root inputs, isolated wake/fault proof,
original failures, commands, source hashes and the typed ownership contract.
An independently extracted copy verifies every run/project input and passes
all 37 Debug cases through that replay. Its log and source-equivalence record
are retained in the final envelope.

Native `005ab244169f269689e511d6b77dd2187e318df1` and XEV
`5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5` remain local proposals. Their
source/history and hpack input distinction are in the
[lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).
Native scheduling is synthetic; App expiry uses real awake time. No upstream
native allocation-free claim is made.

Local half-stop/reset commands, outgoing streams, positive/multi-session flow,
independent draft-16 acceptance, publication and all remaining release gates
stay open. Dedicated smoke/security campaigns remain user-deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `b8d47dd46f565a820aefd5abc81416ed34e58019cb9d5fd0928f75783afe9d64`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
