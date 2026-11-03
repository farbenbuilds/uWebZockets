# Immutable wire checkpoint before native shutdown

The private passive observer can now freeze an immutable prefix before shutdown
without sealing the connection. Source and structural review approve this
checkpoint. Native closing observation, provider integration and M2 acceptance
remain open.

`checkpoint(state)` returns `(ConnectionReceipt, operation)`. It requires the
actual `shutdown_active` connection1 descriptor, 67 final tags, all 68 final
response terminals, the sole held stream3, clean known parser tails and bounded
consistent debt. It accepts an unpoisoned, nonbusy, unsealed observer once and
changes only its checkpoint marker. It performs no I/O or counter reset and
does not manufacture a transport terminal.

The frozen receipt remains unchanged after subsequent valid refunds or failure.
An actual `SSLEOFError` still propagates by identity, records the original
receive poison and prevents ordinary sealing. No TLS EOF exception bypass or
accepted native terminal outcome was added. Application records, JSON, PID,
signal and canonical lifecycle authorization remain external prerequisites.

## Verification

Serialized tests establish a 141-operation prefix with 72 sends, 69 receives,
67 status responses plus metrics and retained 32/32 debt. They verify detached
receipts, fragmented refunds and ordinary reseal. A later raised SSL EOF is
operation142 and keeps sticky poison. Negative checks cover duplicate, busy,
sealed, wrong-phase, incomplete-final and prior-poison cases, plus all 24
partial WINDOW_UPDATE header/payload splits in both directions.

Normal and optimized runs pass the new tests, existing oracle checks, 46-module
inert imports, strict checks and a canonical `shutdown_active` composition with
71 requests, 68 final responses and retained 32/32 debt. The full all40 suite was
not repeated; the focused composition covers the shared receipt extraction.

Only the oracle and import inventory change; one 196-line test module is added.
The other 43 modules remain byte-identical. The touched sources and new
metadata helpers satisfy the depth and inertness checks. Independent audits
preserve 19,806 previous entries alongside the two authorized source changes,
all 809 c2 packet files and the 119/118/113/42 input closure.

The [evidence record](evidence/m2_h2_wire_checkpoint/README.md) retains the API
absence RED, seal-scaffold behavioral RED, rejected compound main guard and
passing corrections. It also preserves the two initial Root draft checks that
incorrectly imposed extra scope on untouched baseline modules, their correction
and the actual baseline depth facts. No existing gate was weakened and no
all-46-modules depth-three claim is made.

Initial context-only console retention is incomplete; substantive test,
failure, source and preservation records are retained. Independent review
reports no actionable findings. These are source tests with scripted transport
and application facts, not real TLS/process or production evidence.

Next work is a separately reviewed native receive-provenance and closing
receipt helper, followed by provider/runtime closure, builds, native all40,
full project/platform gates, production adoption and all remaining milestones.
