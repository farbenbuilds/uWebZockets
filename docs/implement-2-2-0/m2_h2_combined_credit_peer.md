# Shared HTTP/2 credit/trailer peer

The standalone credit driver now uses one independent shared byte peer for
queued trailers with padding and receive-credit exhaustion. The
[archive](evidence/m2_h2_combined_credit_peer/README.md) retains current source,
preceding source, checks and independent review. Its
[manifest](evidence/m2_h2_combined_credit_peer/manifest.json) binds all 40 current
modules: one changed, 39 unchanged. These are in-memory codec observations with
supplied synthetic application/transport facts; M2 remains open.

The constructor validates the canonical four-key application and earned prior
facts, returns the existing seven-key connection and queues startup SETTINGS/ACK.
It invokes no clock, dispatcher or observer, mutates no application facts and
seeds no completion. The driver preserves its positional optional arguments,
same-app return, original prints, body/hash/frame/trailer checks and both exact
negative diagnostics.

Upload HEADERS earns metadata/begin facts with no accepted DATA. The first
queued-trailer DATA earns the seven-byte prefix; the second DATA and trailers
leave that accepted checkpoint intact until actual resume. The second frame
contains 4097 logical bytes, a pad-length octet and seven zero padding bytes.
Trailer fields are validated after both DATA frames, do not create a request
head, and do not enter initial application metadata.

| Case | Logical request bytes | Flow bytes | DATA frames |
|---|---:|---:|---:|
| queued_trailers_padding | 12289 | 12297 | 2 |
| receive_credit | 65536 | 65536 | 9 |

Receive-credit accepts zero while eight frames consume 65535 wire bytes.
Resume accepts that prefix and queues separate connection and stream grants.
The final one-byte END requires both grants and the postresume status to be
delivered. A direct negative delivers the status and connection grant while
withholding stream credit; the final byte still cannot earn facts.

The actual two-case shared-app chain earns its prior state through traffic and
reaches 81 heads including final68. Collection preserves protocol/parser/ledgers,
debt, cumulative receive accounting and deadlines. Copied producer-history
output/binding preservation is separately qualified as supplied synthetic state,
with no claim to prior producer traffic.

Bounded cursors, one upload summary and rolling hashes replace histories and
whole-body retention. Parser capacity is 8201 bytes; send/frame payload 8192.
At most four pending packets occupy 16384 bytes, each at most 8192; HPACK 4096 and
finite read/byte caps reject repeated invalid growth before facts change.
Queued and delivered grant bytes remain separate. Clock failure preserves its
original exception and pending input/receipts.

Four final covering checks pass: driver and all-module imports, each normal and
optimized. Two final direct proofs and two captured strict audits also pass
with empty stderr. Every check retains exact argv/env/cwd, source before/after,
check/recorder snapshots, separate stdout/stderr/exit and same-shell input
restoration. The fresh pre-edit freeze binds 40 accepted sources and 119 authority
entries: 118 physical rows, 113 resolved files and 42 ordered codecs. All 10,800 prior
evidence hashes remain unchanged. All three current helpers meet both nesting
counters and guard/inert-import/empty/foreign-argument checks.

The constructor receipt's inferred restoration path was corrected, preserving
its original JSON bytes and an explicit mapping to the actual receipt. An
injected-header proof initially disturbed HPACK indexing; preserved failed
evidence precedes its never-indexed injection fix. The two `strict-direct-*`
receipt directories execute `audit.py --audit`; their argv and check snapshots
are the authority. Final direct proofs execute `proofs.py` in `final-direct-*`.

Remaining metadata/terminal peers, independent delivery-receipt instrumentation,
actual default/all40 coordination and broad review, runtime/native/project/
platform gates, production adoption and every original milestone remain
required. No native execution or milestone completion is claimed.

Independent specification, quality and structural review approves this scoped
peer preparation with no actionable findings. Publication accuracy is checked
separately before committing.
