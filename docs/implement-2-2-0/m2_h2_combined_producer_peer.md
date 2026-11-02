# Independent HTTP/2 producer and pressure peers

Producer and pressure tests now expose a bounded peer constructor without
dispatching a client. The standalone driver uses that same peer. Output
diagnostics and reuse binding facts come from the peer's serialized progress;
the driver compares separate client-parsed copies. Client observations no
longer establish the peer's expected truth.

The [archive](evidence/m2_h2_combined_producer_peer/README.md) preserves all
38 current modules, preceding source, failures and independent review. The
[manifest](evidence/m2_h2_combined_producer_peer/manifest.json) binds identities
and verification scope. Only `test_producer_pressure.py` changed; 37 modules are
unchanged. Coordinator support remains explicit empty or buffered-only selection.

Construction validates earned prior records, outputs, binding and request counts
without modifying application facts, invoking the clock or running a client.
Peer callbacks use decoded requests, credit updates and bounded state. Actual
client-context checks stay in the driver. Diagnostics and binding are copied
independently when serialized, with mutation controls checking that client
observations cannot rewrite peer facts.

| Concrete case | Heads | Small responses | Request DATA bytes |
| --- | ---: | ---: | ---: |
| Producer reuse | 9 | 8 | 64 |
| Pressure window | 8 | 7 | 33 |
| Pressure readiness | 6 | 5 | 33 |

Each case validates 16777313 output bytes incrementally. Existing grant, paired
completion, hash, identity, deadline, alternate binding and sibling-order controls
remain. The unchanged producer-to-file/early-final chain also passes.

Independent review found two defects, fixed with actual failing-first checks.
Auxiliary credit grants now require an already decoded eligible stream and
finite capacity before state mutation. Twenty unsolicited IDs repeatedly reject
without changing retained state. The driver's receive wrapper now snapshots
its observation, calls the original once, preserves its result or exception,
and then validates the saved observation. Tests cover a callback clearing the
invalid observation and an original error taking priority.

Six current producer/import/file checks pass in normal and optimized Python
with empty stderr; earlier reviewed and intermediate runs remain separate.
All 38 modules pass AST/main-guard and actual inert-import checks. The peer
limits parser storage to 8201 bytes, generated output spans to 8192 bytes and
pending/deferred/echo packets to 12. These Python fixture bounds establish no
native allocation or transport result.

The audit verifies 4412 earlier recorded hashes plus 308 published lifecycle
and 83 capacity raw files. No fresh exhaustive pre-edit map of later receipts
was captured; preserved published identities supply that comparison. Immutable
checks retain 118 physical rows and the ordered 42-codec aggregate.

Spec, quality and structural re-review approve this preparation. Ownership,
TLS and lifecycle facts remain synthetic. File/early peer construction,
ordinary coordinator composition, disconnect/shutdown children, actual default/
all40 aggregation, broad review, native/runtime verification, project gates and
production adoption remain required. M2 remains open.
