# HTTP/2 coordinator disconnect replacement

The coordinator now accepts disconnect anywhere among the 37 ordinary cases.
It dispatches the actual lifecycle handler, finishes strict termination of the
original transport, then uses the replacement context and its receiver. All
38 supported case selections retain caller order. Idle and active shutdown,
including default all40, still reject before effects in this checkpoint.

The [archive](evidence/m2_h2_combined_coordinator_disconnect/README.md) preserves
the reviewed source, preceding ordinary coordinator, raw checks and independent
review. Its [manifest](evidence/m2_h2_combined_coordinator_disconnect/manifest.json)
binds all 39 current modules: three changed and 36 unchanged.

Disconnect requires exactly one additional descriptor callback,
`disconnect_close`. The validated callback map is copied before use. Replacement
reuses `connect` with case-local index 2 and the original case/whole deadlines;
child connection ordinals advance for every actual connection. There is no new
readiness stage or case deadline on replacement.

Each transport retains independent protocol, raw parser, request and response
credit state. Existing cumulative case objects are shared and counted once.
Old connection-local accounting and strict release facts are copied before
replacement creation. Only old local SETTINGS and informational counts are
added to the final case snapshot; shared heads, flow, bytes and reads are not
added twice. The existing eleven-field summaries hold copied scalar/fact data.

The original caller clock, newest checked time and original deadlines remain
private across strict close and replacement connect. Callback changes to the
exposed context cannot widen those bounds. Actual retained producer output and
binding are restored into the replacement before capture or finalization.
There is one final collection per nonempty child.

Actual synthetic-peer coordinator schedules cover disconnect alone,
buffered/disconnect/large, disconnect/reuse, producer reuse/disconnect, and
disconnect/buffered. Producer reuse followed by disconnect observes 102 heads,
100 small responses, 128 request DATA bytes, three connections and four client
SETTINGS. Tests check distinct ledgers, the returned receiver, old observation
rejection, local summaries, strict and normal release, retained binding,
malformed facts, expiry, rollback, descriptor mutation and private time bounds.

Independent review approves spec, quality and structure with no findings.
A focused review sensitivity check additionally mutates the retained original
context and strict-close facts during connect2; returned summaries preserve
their original local values, release facts and deadline 32.

Six composition/coordinator/import checks pass in normal and optimized Python
with empty stderr. The source audit covers all 39 AST modules, main guards and
inert imports, a fresh pre-edit map of 5576 prior evidence files, 119 retained
identity entries and 42 ordered codec sources. Every supported singleton and
forward/reverse 38-case selection reaches the factory boundary; this static
acceptance does not establish actual execution of all 38 cases.

The initial failing acceptance test rejects unsupported selection before
factory or wire effects. A transient test with an incorrect replacement-deadline
expectation was corrected without retaining that failed run. An initial audit
failed before its script existed and has no receipt; the first successful
structure result and recorded final audit are separate. Root also corrected a
metadata reader's relative-path normalization before its successful audit.
These gaps do not establish a production regression RED.

Transport, TLS, EOF and process ownership facts remain supplied synthetic facts.
Shutdown composition, actual default/all40 aggregation, broad combined-client
review, runtime/native validation, full project gates and production adoption
remain required. M2 remains open.
