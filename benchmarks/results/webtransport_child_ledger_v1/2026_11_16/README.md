# WebTransport child receive accounting, 2026-11-16

The private candidate now has a pure receive ledger and a typed native receive
snapshot reader. The ledger excludes the actual receive-prefix length,
accounts final-size gaps once, distinguishes known from visible reset errors,
keeps STOP independent of receive completion, and requires actual read EOF.
Unknown final size stays absent when native teardown abandons a stream.
Invalid transitions leave the ledger unchanged.

This is the accounting foundation for typed children. Engine callbacks, App
APIs, production dependency pins and listener activation are unchanged. Live
child association, consumer delivery, application TX and session flow control
remain subsequent work.

The full project functional suite passes 1022/1022 tests in 20/20 steps.
ReleaseSafe test compilation and the ReleaseFast library each pass 21/21.
Twelve isolated pure cases pass in Debug, ReleaseSafe and ReleaseFast, after a
genuine twelve-failure stub RED. Formatting changed none of the 297 retained
source/build inputs; conventions, version checks and source verification pass.

The standalone native cohort uses two real LSQUIC HTTP/TLS engines and
BoringSSL, with encrypted packets delivered through bounded in-memory queues.
It uses the inherited synthetic native scheduling clock and no UDP or xev.
Its six cases exercise incoming UNI/BIDI payload and FIN accounting, hidden
reliable reset with an unread final-size gap, STOP before final size, local
read cancellation retaining ownership until native close, and connection
teardown with unknown final size. This is separate from App/Engine child I/O
and independent draft-16 client acceptance.

All six native cases pass in Debug, ReleaseSafe and ReleaseFast, 13/13 build
steps in each mode, on the same frozen source inputs.

The original archive retained the intended missing-API RED, environment-only setup
failures, an initial fixture cleanup failure, and the original sources before
a pointer-lifetime proof correction. Independent architecture, code and native
proof reviews have no remaining required findings. No protocol assertion was
removed to make a case pass.

The first project unit invocation stalled in an existing loopback test inside
the network-restricted sandbox. Its backtrace and stopped-run evidence are
retained. The unchanged suite passed with loopback available. Its rejection
and io_uring diagnostics are preserved, as in the preceding checkpoint.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify
`files.sha256` inside. `HANDOFF.md` records exact inputs, commands, profiles,
reviews and limits. The native source proposal remains
`2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`; restore its complete source from the
[native candidate archive](../../lsquic_webtransport_children_v1/2026_11_16/README.md).

Public child-stream support, multi-session accounting, independent-client
acceptance, dependency publication/pins and the other v2.3.0 gates remain open.
Smoke and security campaigns remain deferred by the user.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `3dc001464216599e8284d918e45e2047c59c24acecb587fd7f41349e366632b9`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
