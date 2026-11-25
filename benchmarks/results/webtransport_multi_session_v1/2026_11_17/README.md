# WebTransport same-connection session isolation

Root implementation: `a6c744fc44a24c5b3b65558d15c20dfebf690afd`.
Ring prerequisite: `64ccd279922bf1a762799560d04e5dba39a467ab`.
Native candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`.
XEV candidate: `5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`.
Production dependency pins remain unchanged.

Simultaneous sessions require bilateral positive flow. Each CONNECT keeps its
own route, handles, budgets and credit output. Typed cleanup selects one SID
or the entire connection; stable in-place datagram compaction preserves sibling
FIFO payloads, connection-wide ordinals and drop accounting without allocation.

| Ordinary Linux native driver | Debug | ReleaseSafe | ReleaseFast |
| --- | --- | --- | --- |
| New multi-session baseline | 11/11 | 11/11 | 11/11 |
| Separate authorization refusal | 1/1 | 1/1 | 1/1 |
| Retained positive flow | 18/18 | 18/18 | 18/18 |
| Retained combined stream/debt | 77/77 | 77/77 | 77/77 |
| Retained datagrams | 33/33 | 33/33 | 33/33 |

All 15 final invocations exited zero. Drivers share helpers and do not describe
disjoint protocol cases. The exact 11-case sources remain immutable; refusal
uses separate copied support. Two inherited datagram cases retain labeled
private receive-window staging, and the inherited callback-order injection
keeps its original scope. New cases do not mutate private native windows/settings.

The genuine RED rejects the second positive CONNECT with H3_REQUEST_REJECTED
before authorization. Corrected source establishes two SIDs on one connection
with distinct routes. Cases cover peer/local children and datagrams, independent
data/BIDI/UNI grants and writable recovery, early debt, stream-slot generation
reuse, legacy/unilateral rejection and subsequent admission, and scoped
Close/RESET/EOF/STOP/semantic/malformed termination. Refusing B preserves A's
handle, child, budget and FIFO before admitting a later fresh SID.

Partial native credit output is also isolated: A remains at advertised limit
462 with only 2/7 pending capsule bytes accepted, while B accepts its own data,
BIDI and UNI grants on CONNECT 4. Resuming A completes recovery without changing B.

Cooldown tests first require logical session/child/index/queue retirement, then
send actual peer FIN before requiring all transport leases to release. Connection
abort drains without peer FIN. This preserves the existing graceful policy;
cooldown does not independently complete every CONNECT handshake. Native accept
API failure is source-reviewed without new fault-injection hooks.

Root passes 1128/1128 ordinary tests, ReleaseSafe test compilation, ReleaseFast
library/default builds including HTTP/3 examples, and downstream-consumer checks.
Formatting preserves all 314 source/build inputs. Conventions, version, docs,
diff and graph checks pass. Independent source/evidence review has no findings.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
top-level `files.sha256`. All 266 frozen native source/build/include inputs
match the Root implementation. Independently relocated Debug replays pass both
the 11-case baseline and separate refusal case. Exact fixtures, source snapshots,
raw logs, statuses, pure-ring prerequisites, commands and reviews are retained.
The report labels fixture corrections and repaired historical status references;
original failed logs and TSVs remain unchanged. Replay instructions and external
compiler/package/Native/XEV artifact references are inside the archive.

Independent-client acceptance and maintained-fork publication remain open.
Dedicated smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.
This checkpoint does not activate the published backend or complete v2.3.0.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `a172f18c8cb22cb4ecbdacd2c8438cac84bcf62a063c7e3278733dd801eb25f6`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
