# Shared HTTP/2 metadata/concurrency peer

The standalone metadata/concurrency driver now uses one independent shared
byte peer. The [archive](evidence/m2_h2_combined_metadata_peer/README.md) retains
current source, preceding source, checks and independent review. Its
[manifest](evidence/m2_h2_combined_metadata_peer/manifest.json) binds all 40
modules: one changed, 39 unchanged. These are in-memory codec observations
with supplied synthetic application/transport facts; M2 remains open.

The constructor validates the canonical application and earned prior state,
returns the existing seven-key connection and queues startup SETTINGS/ACK.
It invokes no clock, dispatcher or observer, mutates no app facts and seeds
no completion. The driver preserves its signature, app/output/binding identity,
local synthetic clock, primary stream 3, prints and existing diagnostics.

Metadata checks preserve 66 regular headers including regular host, exact
target/query, 17 captures, overflow storage and the existing borrowed/helper
contracts. Seven direct header variants remain oracle sensitivity controls,
separate from serialized schedules. HEADERS earns initial metadata/helper/begin
facts. Two 16-byte spans, paused statuses, exact trailers and actual resume
earn later body/hash/END/helper completion. Trailer-only fields and changed
x-h62 do not replace initial application metadata.

Concurrency keeps held, refused, upload and recovery streams independent.
Refusal final 503 HEADERS precedes NO_ERROR reset without normal 100/body;
delivery is required before the next upload. The metric barrier remains two
active, one paused and both slots. Resume accepts the held 16-byte prefix; ready
status delivery precedes its final 16-byte END. Upload and recovery preserve holder
isolation and independent hashes.

The peer no longer reads client context. Driver instrumentation captures the
original health-send boundary at heads 7/12/13: refused stream 7 remains in
records/stage.active/raw.streams at 7 and 12, and is absent at 13. The snapshot
is asserted after the original operation, preserving its result/error priority.
Both instrumentation levels restore on success/failure. Nine actual serialized
corruptions cover all three maps at all three boundaries, restoring them before
receive so a later assertion cannot substitute.

Actual two-case traffic earns prior state and reaches 87 heads including
final68. Collection preserves the same protocol/parser/ledgers, debt, receive
accounting and deadlines. The separate producer-history fixture remains
explicitly supplied synthetic state, proving retained references without
claiming producer traffic or native helper behavior.

Bounded cursors replace histories. Parser capacity is 8201 bytes, send/frame
payload 8192, HPACK 4096, pending packets 4/16384 bytes with each 8192. Four upload
summaries retain rolling hashes and at most 32 bytes/two frames; finite read/
byte caps reject repeated invalid growth before facts change.

Four final covering checks pass: driver and all-module imports, each normal
and optimized. Two direct proofs and two strict captured audits also pass,
with empty stderr and complete command/source/check/raw/exit/restoration
receipts. The fresh pre-edit freeze binds 40 accepted sources and 119 authority
entries: 118 physical rows, 113 resolved files and 42 ordered codecs. All 11,037
prior evidence files remain unchanged. All three current helpers meet both
depth counters, guards and inert import/empty/foreign argument checks.

Preserved failures distinguish constructor absence, oversized-startup behavior,
early-final diagnostic priority and two proof setup corrections. Manual handler
operations did not earn canonical driver completion; the final proof uses actual
dispatch. Retention sentinels are now confined to the send snapshot and restored
before client receive validation. No canonical check or bound was weakened.

Independent specification, quality and structural review approves this scoped
preparation with no actionable findings. Terminal peer extraction, independent
delivery receipts, actual default/all40 coordination and broad review, runtime/
native/project/platform gates, adoption and every original milestone remain
required. No native execution or milestone completion is claimed.
