# Independent WebTransport client acceptance

Root source: `c377d38caeb32de773c03531be11d8bda3c2d829`.
Native candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`.
XEV candidate: `5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`.
Official webtransport-go: `2a2b547d91a8a70e313e7ce61538b066554021b5`.
quic-go: `793f74d8e03368c5aded128af6f48d21dbb47f73` (`v0.62.0`).
Production dependency pins and capability flags are unchanged.

A standalone server imports `src/root.zig`, uses the public App API and normal
event loop/shutdown, and compiles native dependencies with Zig source lists.
It omits the C client, test-support module, SETTINGS observer, artificial clock,
private native-window changes and manual engine pumping. The external official
client and its frozen dependencies are independent of the server implementation.

| Final ordinary case | Debug | ReleaseSafe | ReleaseFast |
| --- | --- | --- | --- |
| Legacy single-session datagrams | pass | pass | pass |
| Positive two-session datagrams | pass | pass | pass |
| Peer/local UNI and BIDI | pass | pass | pass |
| Reliable reset metadata | pass | pass | pass |
| DATA credit recovery | pass | pass | pass |
| UNI/BIDI stream-credit recovery | pass | pass | pass |
| Blocked/closed A, healthy B | pass | pass | pass |
| Two connections both using SID zero | pass | pass | pass |
| Second source/route namespace | pass | pass | pass |

All 27 client and server processes exit zero. Each uses fresh explicitly trusted
localhost PKI, TLS 1.3, `h3`, DATAGRAM and partial-reset negotiation. HTTP health
and reports share the client's owned QUIC connection. Strict reconciliation
checks exact callback/ring sets without assuming delivery order, full route and
generation identity, contiguous connection ordinals, operation-derived child
sets, binary payloads, FIN and exact-once terminal counts. Servers report zero
errors/overflow and exit normally through App shutdown and deinit assertions.

DATA recovery first observes exactly 32 of 4096 bytes accepted and a real
`WouldBlock` before client reads; actual grants then permit suffix-only delivery.
Stream credit one rejects another create until closure and explicit retry.
Public qlog records actual `RESET_STREAM_AT` stream 6, wire final size 27 and
reliable header size 3, matching application code 4660 and final payload size 24.
This covers association-header reliability; arbitrary reliable body prefixes,
optimistic/fragmented early associations and loss recovery retain their separate
raw/native evidence scopes.

Independent review verified all 27 rows, 81 raw-log hashes, final sources/binaries,
negotiation, strict report barriers and actual reset frames. Fixture findings
were corrected before the frozen final matrix; earlier source hashes/results
remain labeled provisional. The ordinary Root suite passes 1128/1128 tests.
All 314 formatted source/build inputs match the unchanged Root commit; convention,
version, docs, diff and graph checks pass. Each server profile also passes its
pure wrong-route/stale-generation fixture regression.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
top-level `files.sha256`. The archive retains the exact Root snapshot, fixture
sources, final Linux executables, dependency metadata, commands, raw results and
reviews. `sh replay.sh Debug` runs all nine cases with fresh private PKI and
cleans it afterward. An independent relocated replay passes 9/9. Other profiles
are supported; binaries require the recorded compatible host/CPU/ABI. Rebuild
instructions and exact external Native/XEV artifact references are inside.

No generated certificates, private keys or credentials are included. The
upstream quic-go ZIP contains public test PKI, so it is omitted entirely while
its hash, immutable origin and go.sum remain recorded. Final-binary replay needs
no module download; source rebuild requires that unchanged pinned module.
Go/Python are external verification tools, not native-library build requirements.

Maintained-fork publication, production activation and other v2.3.0 requirements
remain open. Dedicated smoke/security/sanitizer/fuzz/scan campaigns remain
user-deferred. This is candidate acceptance evidence, not a production release.
