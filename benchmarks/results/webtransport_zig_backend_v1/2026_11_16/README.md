# Private Zig WebTransport backend, 2026-11-16

The private adapter in `src/quic/webtransport/backend.zig` checks the complete
optional native contract before using it. It copies validated peer and stream
metadata, preserves caller output on failed queries, installs named callbacks,
and enables explicitly bounded native settings. Published-pin callers retain
unsupported results. Listener activation and dependency pins are unchanged.

An isolated Zig scaffold compiles the actual project backend and six actual
component tests against native proposal
`2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`. Four additional real TLS tests
exercise pending/completed negotiation, positive peer limits above 32 bits,
long-lived CONNECT and raw UNI/BIDI children initiated by both endpoints.
All ten tests pass in Debug, ReleaseSafe and ReleaseFast, 15/15 build steps
each. The fixtures use actual native pointers, translated headers and the
native Zig C/C++ build graph. Independent API and harness reviews found no
remaining required findings.

With published dependencies, all 964 centralized tests pass in 20/20 steps
through `zig build test-unit`. ReleaseSafe `test-compile` and the ReleaseFast
library build pass. Formatting, conventions and release-version checks pass.
The complete default `test` target retains its C API smoke and consumer gates;
smoke and security runs remain deferred by the user. Compile-only evidence
does not claim that a smoke executable ran.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify
`files.sha256` inside. The original archive retained the scaffold, exact project leaf
sources, input hashes, original setup failures and final command logs.
`HANDOFF.md` describes reproduction and recovery of the separately archived
[native candidate](../../lsquic_webtransport_children_v1/2026_11_16/README.md).
Fresh extraction and every payload hash were verified. Dependency caches,
binaries and generated private keys are excluded.

Fixed connection generations, session ownership, application routing,
datagrams and capsules still require runtime integration. Independent draft-16
client acceptance and maintained-fork publication remain open. This adapter
slice does not complete WebTransport or v2.3.0.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `a2a978692d20aad066c5821959ee3ea3148804e9459f9151bccecd674bea768d`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
