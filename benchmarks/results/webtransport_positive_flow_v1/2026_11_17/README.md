# WebTransport negotiated session-flow checkpoint

Root implementation: `cc5013eb937bbf4066b153fe18c29bb999f68b85`.
Native candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`.
XEV candidate: `5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`.
Production dependency pins are unchanged.

Startup limits default to zero. Bilateral nonzero intent enables cumulative
session budgets with retained early receive debt checked before CONNECT
authorization. Successful native child creation and accepted body bytes spend
peer credit. Reads and final-known closure replenish receive credit through
bounded CONNECT capsules, preserving partial output until full acceptance.
DATA zero suppresses app writable callbacks while retaining requested interest
for MAX_DATA recovery; FIN, RESET and STOP continue independently.

| Ordinary native driver | Debug | ReleaseSafe | ReleaseFast |
| --- | --- | --- | --- |
| New flow baseline | 17/17 | 17/17 | 17/17 |
| Retained combined stream/debt | 77/77 | 77/77 | 77/77 |
| Retained datagrams | 33/33 | 33/33 | 33/33 |
| Added DATA-zero FIN/RESET/STOP | 1/1 | 1/1 | 1/1 |

All twelve invocations exited zero. The added case ran separately after
extending the flow source to 18 cases; exact prior 17-case source is retained.
Drivers share helpers; these counts do not describe disjoint protocol cases.
Two inherited datagram cases retain labeled private receive-window staging;
the inherited callback-order injection is also labeled. New flow cases use
actual TLS/UDP and do not mutate private native settings/receive windows.

The actual RED source authorized excessive early debt and opened the session
and child. Corrected source rejects it with WT_FLOW_CONTROL_ERROR before
authorization. Other cases cover bilateral/legacy policy, prefix exclusion,
RESET final gaps, successful-only creation, partial write debit, serialized and
blocked credit output, grant recovery, semantic/malformed capsule errors and
healthy ordinary HTTP. The original archive preserved setup and v1 compile failures
separately from regression proof, plus unmodified passing logs and warnings.

Root passes 1124/1124 ordinary tests, ReleaseSafe test compilation, ReleaseFast
library and downstream-consumer checks. Formatting leaves 314 source/build
inputs unchanged; conventions, version, docs, diff and graph updates pass.
Independent final source/evidence review has no actionable findings.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
top-level `files.sha256`. The original archive retained exact fixtures, RED/v1/v2 source,
raw logs, source manifests, pure-state prerequisites, commands and reviews.
All 266 v2 snapshot inputs match the Root implementation commit. The relocated
final 18-case Debug flow driver also passes; its raw output is retained under
`root_verification/`. The fixture README documents replay and external compiler,
package and dependency source overrides. Native/XEV source remains in the
referenced existing committed artifacts.

One session per connection remains enforced. Multiple-session isolation,
independent-client acceptance and fork publication remain open. Dedicated
smoke/security/sanitizer/fuzz campaigns remain user-deferred. This checkpoint
does not activate the published backend or complete v2.3.0.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `711b30326fdb72e6b04ea1e2510876b20f8033b72d8b49d7a5605995aa5c735b`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
