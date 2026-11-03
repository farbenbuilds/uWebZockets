# Shared HTTP/2 Continue/quota peer

The standalone Continue/quota driver now uses one independent shared byte peer
for Continue-ready, Continue-paused, quota refusal and failed-begin rollback.
The [archive](evidence/m2_h2_combined_continue_peer/README.md) retains current
source, preceding source, checks and independent review. Its
[manifest](evidence/m2_h2_combined_continue_peer/manifest.json) binds all 40
modules: one changed and 39 unchanged. These are in-memory codec observations
with supplied synthetic application/transport facts; M2 remains open.

The constructor validates the canonical four-key app and earned prior state,
returns the existing seven-key connection, and queues startup SETTINGS/ACK.
It calls no clock, dispatcher or observer, mutates no app facts and seeds no
completion. The driver keeps its signature and same-app return. The original
`before_continue()` direct client-boundary proof remains byte-for-byte intact.

Validated HEADERS earns metadata/admission/begin facts. Continue DATA requires
the informational frame to have been returned by receive; queueing it is
insufficient. A retained behavioral RED demonstrates the frozen original
peer accepting DATA before delivery. Current proofs reject that transition
before body or app mutation.

The paused case keeps accepted bytes/chunks/ends zero through its 32-byte END,
then completes after delivered paused-status and actual resume. Quota uses two
real slot cells and enforces delivered metric barriers `2,0,2,0` around holders,
refusal and recovery. Refusal 503 has no begin/body/100; final HEADERS precedes
NO_ERROR reset. Failed begin records one attempt/failure and no begin, releases
its slot, and permits actual recovery reuse.

| Case | Ordinary heads | Request DATA bytes |
|---|---:|---:|
| continue_ready | 3 | 32 |
| continue_paused | 5 | 32 |
| quota_refuse | 11 | 128 |
| begin_failure_rollback | 4 | 32 |

The actual four-case shared-app chain earns 23 ordinary heads plus final68,
reaching 91. Final collection preserves protocol/parser/ledgers, debt,
cumulative receive accounting and original deadlines. A separate copied
producer-history fixture proves retained output/binding references only;
it claims no earlier producer traffic.

Bounded cursors, upload summaries and rolling hashes replace path/frame/read/
metric histories. Parser capacity is 8201 bytes; send/frame payload 8192;
pending packets 2/16384 bytes, each 8192; HPACK table/list 4096. Upload count and
receive/byte caps follow the finite schedules. Repeated malformed input is
rejected before earned facts or retained growth. The peer reads no client
capture/context to establish truth.

Four final covering checks pass: driver and all-module imports, each normal
and optimized. Two final direct proofs and two final strict audits also pass
with empty stderr. All retain exact argv/env/cwd, source before/after, helper/
check snapshots, separate stdout/stderr/exit and same-shell restoration of
pinned source inputs. The fresh pre-edit freeze binds 40 accepted sources and
119 authority entries: 118 physical rows, 113 resolved files and 42 ordered codec
files. All 10,486 prior evidence hashes remain unchanged. All three current unit
helpers pass accepted and strict depth/guard/inert-import/empty/foreign checks.

All nine fault diagnostics remain exact. An intermediate early-final fault was
initially caught by the new peer's delivery barrier; the preserved correction
reaches the original client `invalid terminal` diagnostic. A proof's wrong
primary setup and its later correction are separately retained. The unused
proof import was removed, then affected direct/helper audits rerun; source
module checks remain bound to unchanged source. No check or bound was weakened.

Remaining credit/metadata/terminal peer extractions, independent delivery
receipts, actual default/all40 coordination and broad review, runtime/native/
project/platform gates, production adoption and every original milestone
remain required. No native execution or milestone completion is claimed.

Independent specification, quality and structural review approves this scoped
peer preparation with no actionable findings. Publication accuracy is checked
separately before committing.
