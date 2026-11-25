# WebTransport stream-credit prerequisite, 2026-11-13

The unpublished proposal is frozen at
`9f0088c58fe67cccf1871dc172c90c2ec6f97944`, following the
[SETTINGS prerequisite](../../lsquic_webtransport_settings_v1/2026_11_13/README.md).
The review-only Git bundle is not a production dependency or overlay. Root's
published pins and live capability bits are unchanged.

With WebTransport enabled, the HTTP client now uses its configured incoming
uni limit for both local admission and TLS advertisement. With the feature
disabled, it retains the existing three-stream limit. Bidi send limits now
follow the stream initiator: outgoing streams use the peer's remote limit;
incoming streams use its local limit. Both limits remain fixed connection data.

The actual encrypted-engine regressions establish:

- Configured eight with WebTransport enabled advertises eight, permits five
  initially held-open application streams after the three critical streams,
  and blocks the next attempt without a callback. Real delivery then checks
  client admission, with both connections and SETTINGS snapshots still live.
- Configured three with the feature enabled, and configured eight with it
  disabled, both advertise three and block application uni creation.
- Raw QUIC with distinct client/server local/remote windows selects the correct
  initial cap for all four bidi halves. Each direction exchanges exact bytes
  and FIN. The test observes native caps before application reads; it does not
  establish exact blocking at each byte-credit boundary.

The focused cases pass Debug, ReleaseSafe and ReleaseFast. All 83 upstream
Linux Debug cases pass (165/165 build steps); Windows GNU and macOS ARM64
production libraries each compile in 9/9 steps with fixture hooks disabled.
Independent review found no actionable issue. The archive distinguishes earlier
compile setup
errors, the genuine pre-fix assertion failures and final functional results.
Its final-gate manifest records upstream and cross-target results separately;
cross-compilation is not foreign runtime execution.

Actual resumed traffic with asymmetric remembered/live limits remains
unverified. Raw child creation, classification and session association,
WT-specific client bidi admission, directional prefix reset handling and Zig
session integration remain open. Smoke/security runs remain deferred to the
user. This prerequisite does not complete WebTransport or v2.3.0.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify
`files.sha256` inside. `HANDOFF.md` describes bundle recovery and the native
Zig scaffold. Caches, binaries and generated fixture private keys are excluded.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `b261a379810c7d8cd39b3ea1624f7d44ad34d285b04738a5d23e904136c42be8`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
