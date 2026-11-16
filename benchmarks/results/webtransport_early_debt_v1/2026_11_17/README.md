# WebTransport early receive-debt checkpoint

Root source: `aabc85e1ff7ff0a908b8e1e0053947a2ed079c73`.
Native candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`.
XEV candidate: `5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`.
Date: 2026-11-17, Asia/Bangkok. Production dependency pins are unchanged.

Early child usage and reclaimed credit survive child destruction in four fixed
SID slots per connection until CONNECT takes ownership. Native high-water
deltas charge body bytes once; typed publication charges peer stream counts.
Reads and final-known close reclaim consumed/discarded body bytes and closed
peer children, including NULL Root contexts. Known-session receipt uses the
indexed CONNECT record before any retired-ID scan.

Full-pool BIDI classification consumes no child body. Retired identities are
checked before application CONNECT admission; lost stream debt has its own
admission latch, preserving the older datagram exhaustion policy. HTTP reads
already closed during header delivery do not falsely latch lost debt.

The final Linux Native matrix passes in Debug, ReleaseSafe and ReleaseFast:

| Driver | Cases in each mode |
| --- | --- |
| Combined stream/debt driver | 77/77 |
| Existing N4 datagram driver | 33/33 |

The combined driver includes the retained 67 stream cases, one publication
guard, eight new actual TLS debt cases and one labeled C callback-order
injection. The separate drivers share helpers; these are not 110 disjoint
tests. Two inherited N4 reset-credit cases stage private Native receive-window
growth before real wire updates. The new eight debt cases do not use that
mutation; no blanket Native-mutation-free claim is made.

The new network cases cover late CONNECT transfer, already-closed children,
hidden RESET final gaps after dropping encrypted payload packets, full-pool
NULL-context BIDI classification, SID/terminal exhaustion, ordinary HTTP
recovery, and debit asserted inside application open/data callbacks. The
ordinary HTTP/publication guards pass on earlier source and are not RED proof.
The injected header-close/read order fails the v3 admission-latch assertion and
passes after the error-path fix. A valid overlapping STREAM path is supported
by source review; encrypted overlap itself was not reproduced.

Root passes 1106/1106 ordinary unit tests, ReleaseSafe test compilation,
ReleaseFast library and downstream-consumer checks. The 16 pure debt tests pass
in all three modes, including comptime purity and bounded churn; x86 is
compile-only. Formatting, conventions, version, docs, diff and graph checks
pass. Independent final source reviews are clear.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
internal `files.sha256`. All 1500 payload hashes were independently checked.
The final 263 fixture source/build inputs match the Root commit byte for byte.
The combined 77-case Debug driver also passes after extraction at another
path; its raw output is retained as `relocated_debug.log.gz`.

The archive retains exact fixture/source snapshots, replay overrides, raw
logs, source manifests, reviews and isolated regression inputs. The fixture
README explains compiler/package/dependency/cache overrides. Native source
and its incremental bundle are in the
[publication snapshot checkpoint](../../lsquic_receive_publication_v1/2026_11_17/README.md).
Historical failed snapshots are retained: v2 exposes the shared-latch datagram
regression; new fixture FIN/32-stream setup corrections are labeled separately.
The initial matrix metadata expected nine focused cases while its unfiltered
driver successfully ran 77; the verifier was corrected without changing tests.

Positive receive-limit enforcement, sender/create budgets, live capsule output,
multiple sessions, independent-client acceptance and fork publication remain
open. Dedicated smoke/security/sanitizer/fuzz campaigns remain user-deferred.
