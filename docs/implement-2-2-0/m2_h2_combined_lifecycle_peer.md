# Shared HTTP/2 disconnect and reuse peers

Disconnect and reuse tests now expose connection constructors without running
the client. The standalone driver uses the same serialization implementation;
replacement ordering remains in the driver and concrete handler. This prepares
later coordinator composition. Coordinator support remains explicit empty or
buffered-only selection.

The [archive](evidence/m2_h2_combined_lifecycle_peer/README.md) preserves the
38-module source, earlier source, failures and review-driven fixes. Its
[manifest](evidence/m2_h2_combined_lifecycle_peer/manifest.json) binds exact
identities and verification scope. Only `test_lifecycle.py` changed from the
preceding checkpoint; 37 modules remain byte-identical.

Each constructor returns an initiated protocol, bounded send/receive operations
and supplied synthetic connection facts. Construction queues startup frames
without invoking the client, clock or application transitions. Connections own
independent parser, HPACK, queue and credit state. They share explicit rolling
case evidence and application records. Prior state is validated without seeding
undispatched work.

The replacement boundary validates the actual terminal disconnect record before
later control requests earn stale-control counters. The driver retains strict
close ordering, the replacement receiver, original deadlines and separate debt.
Existing final-collection and malformed-input controls remain intact.

| Concrete case | Heads | Small responses | Request DATA bytes |
| --- | ---: | ---: | ---: |
| Disconnect | 25 | 24 | 64 |
| Reuse | 389 | 389 | 288 |

Independent review found two defects, both fixed with actual failing-first
regressions. Canonical record validation now rejects integer `0` in a boolean
field. A capacity check now runs before buffer mutation: two rejected 8192-byte
sends leave an existing 8200-byte partial frame unchanged. Before the fix those
rejections grew retained storage to 16392 and then 24584 bytes. The 8201-byte
parser limit and two-response queue preserve earlier negative controls.

Four current lifecycle/import checks pass in normal and optimized Python with
empty stderr. Earlier reviewed results remain distinct. All 38 modules pass
AST/main-guard and actual inert-import checks. The audit verifies 4412 prior
evidence hashes, 118 physical identity rows and 42 ordered codec files.

The evidence records setup-copy errors honestly: the original copy failure was
not captured; a repeated failure is retained separately. Reused frozen source
and recopied authority files match their published identities. Missing-API RED,
intermediate validation errors and current behavioral regressions remain distinct.

Spec, quality and structural re-review approve this lifecycle preparation. The
[shared-core capacity successor](m2_h2_combined_core_capacity.md) closes the
separately recorded parser finding before producer work. Ownership, TLS, close
and process facts remain synthetic. Native/build/compliance verification, producer/file peers,
arbitrary coordinator subsets, disconnect/shutdown composition, actual default/
all40 aggregation and production adoption remain required. M2 remains open.
