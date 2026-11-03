# Shared HTTP/2 terminal peer

One independent shared byte peer now drives cancellation, outgoing peer reset
and application failures through both standalone drivers. The
[archive](evidence/m2_h2_combined_terminal_peer/README.md) retains current source,
preceding source, checks and independent review. Its
[manifest](evidence/m2_h2_combined_terminal_peer/manifest.json) binds baseline 40
to current 41: one new module, three changed and 37 unchanged modules. These are
in-memory codec observations with supplied synthetic application/transport
facts; M2 remains open.

`test_terminal_peer.new_peer` supports all six cases. Both drivers import it
directly; both old nested peers and selected completion recipes are removed.
The helper imports neither driver nor adapter and reads no client context.
Construction validates the canonical app and earned prior facts, queues normal
startup traffic, and invokes no clock/dispatcher/observer or app mutation.

HEADERS earns metadata/admission/begin facts. Validated DATA earns accepted
bytes, hashes and chunks before terminal actions earn reason/cancel/END and
diagnostic facts. Malformed DATA rejects before counters/digests change.
Cancellation HEADERS no longer seeds seven accepted bytes. Sink/progress cases
transmit seven then eight bytes, accepting seven; their wire hash uses two
spans starting at offset zero, rather than a contiguous 15-byte prefix.

| Case | Heads | Small budget | Request flow bytes | Reset direction |
|---|---:|---:|---:|---|
| cancel_ready | 12 | 11 | 40 | incoming CANCEL8 |
| cancel_paused | 12 | 11 | 65 | incoming CANCEL8 |
| peer_reset | 11 | 10 | 65 | outgoing CANCEL8 |
| sink_error | 11 | 10 | 48 | incoming INTERNAL_ERROR2 |
| invalid_progress | 11 | 10 | 48 | incoming INTERNAL_ERROR2 |
| end_error | 10 | 9 | 65 | incoming INTERNAL_ERROR2 |

Queued and delivered resets remain separate. Outgoing peer reset contributes
no incoming reset. Split-reset success retains the partial frame and counts
one completed delivery. Four stale controls earn their counters separately;
the exact primary-byte connection refund follows the second stale response,
then sibling echo, recovery, remaining stale controls and final health. There
is no closed-primary stream grant.

Driver instrumentation snapshots paired retirement at the actual serialized
send inside the first stale `adapter.start`; sibling connection debt is checked
immediately after the original `adapter.send_data`. Results, original errors
and priority survive, and instrumentation restores on failure. Fourteen actual
map/flag corruptions prove both driver families' original boundary.

Both original three-case chains, all negative messages, split-reset positives
and budgets remain intact. An actual mixed six-case factory chain earns
67 ordinary heads plus final68, reaching 135. Final collection retains protocol/
parser/ledgers, debt, cumulative receive accounting and deadlines. Historical
fixture facts and supplied ownership/TLS facts do not establish native behavior.

Bounds remain parser 8201, send/frame 8192, HPACK 4096, pending packets 4/16384,
three rolling upload summaries, two delivery labels, read cap 200 and matching
byte caps. No payload/request/frame/read history is retained. A real RED caught
consumed frames missing from parser high-water accounting; the fix records
bounded storage before consumption.

Six final covering checks pass: both drivers and all-module imports, normal and
optimized. Two direct proofs and two captured strict audits also pass, with
empty stderr and complete command/source/check/raw/exit/restoration receipts.
The fresh pre-edit freeze preserves baseline 40 and 119 authority entries:
118 physical rows, 113 resolved files, 42 ordered codecs. All 11,284 prior evidence
files remain unchanged. All 41 imports/guards and all three current helpers'
accepted/strict depth and inertness checks pass.

Retained failures distinguish interface absence, premature HEADERS bytes,
malformed-DATA mutation, the first incorrect `adapter.get` instrumentation seam
and parser accounting. Constructor/buffer receipt corrections preserve original
JSON bytes and point to actual same-shell restoration; no evidence was invented.
Final v3 checks bind the final source and supersede earlier successful versions.

Independent specification, quality and structural review approves this scoped
preparation with no actionable findings. Independent aggregate receipts, actual
default/all40 coordination and broad review, runtime/native/project/platform
gates, production adoption and every original milestone remain required.
No native execution or milestone completion is claimed.
