# Independent HTTP/2 file and early-final peers

File and early-final tests now expose connection constructors without running
the client. The standalone driver uses the same bounded serialization peer.
File diagnostics are earned when serialized and retained separately from the
client's parsed observations. Earlier producer diagnostics and binding survive
the producer-to-file-to-early sequence.

The [archive](evidence/m2_h2_combined_file_peer/README.md) preserves all 38
current modules, preceding source, results and independent review. Its
[manifest](evidence/m2_h2_combined_file_peer/manifest.json) binds exact identities
and scope. Only `test_file_early.py` changed; 37 modules remain byte-identical.
Coordinator support still covers explicit empty or buffered-only selection.

Construction validates actual prior records, outputs, binding and head counts,
preserving absent observed binding as `None`. It queues initial SETTINGS/ACK
without dispatch, clock calls or application transitions. Peer callbacks use
serialized progress, with finite parser, packet, upload and auxiliary-grant
bounds checked before growth. File generation and hashing remain incremental.
The driver wrapper preserves pre-call observation, one original receive call,
result identity and original exceptions.

| Concrete case | Heads | Small responses | Request DATA bytes | Output bytes |
| --- | ---: | ---: | ---: | ---: |
| Streamed file | 7 | 6 | 33 | 24593 |
| Early final order | 7 | 6 | 32 | 17 |

The existing producer/file/early chain and standalone final collections pass.
Range generation, hash, content length, ownership, close-once, credit, deadline
and END-before-reset controls remain. Mutation checks prove that changing client
observations does not rewrite the independent peer facts.

Four current file/import checks pass in normal and optimized Python with empty
stderr. All 38 modules pass AST/main-guard and actual inert-import checks.
The audit verifies 4412 earlier recorded hashes plus 308 lifecycle, 83 capacity
and 226 producer files against their published archives. No fresh exhaustive
pre-edit map of later receipts was captured.

Historical RED proves only the missing constructor API. There is no pre-fix
behavioral RED for the newly added boundary checks; current passing controls
are preserved without claiming that history. Independent spec, quality and
structural review found no actionable source defects.

These are in-memory codec and driver proofs. Supplied transport, ownership and
lifecycle facts remain synthetic. Ordinary coordinator composition, disconnect/
shutdown children, actual default/all40 aggregation, broad review, native/runtime
verification, full project gates and production adoption remain required.
M2 remains open.
