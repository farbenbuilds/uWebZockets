# Native coordinator connection construction

The private HTTP/2 harness now constructs the coordinator's seven-key
connection through bounded injected operations. Source review approves this
constructor, ordinary I/O and ordinary-close slice after correcting an
intermediate-close deadline defect. Strict disconnect, active shutdown hooks
and real provider/native acceptance remain required.

Child facts and case selection are validated before effects. Setup verifies
supplied ownership, capture and TLS inspection facts, retains exact protocol
identity, and installs observer callbacks before HTTP startup traffic. Active
descriptors use the unchanged C4 receive state and exact callback binding;
this establishes pre-signal construction only.

One integer nanosecond clock preserves the original readiness, case and whole
deadlines. Child readiness does not restart for later connections. Ordinary
I/O rejects malformed returns, premature EOF and poisoned observers. Setup and
ordinary-close errors retain primary and cleanup exception identities.

## Verification and correction

Saved normal and optimized runs pass 15 focused groups, with additive import
inertness and public-view preservation checks. They cover setup stages,
ownership/TLS/certificate/ALPN/capture errors, clock boundaries, I/O shapes,
failure identity, cleanup and close behavior.

The initial close implementation applied a 15-second grace cap to intermediate
connections. The real coordinator supplies their unchanged case/whole deadline.
A retained regression reproduces the rejection through `coordinator.run`;
the reviewed correction closes the TLS handle and reaches the expected
second-connect sentinel. That proves the repaired transition, not completion
of both cases or native execution. Shorter final-grace deadlines remain intact.

Other retained behavioral REDs cover excessive case deadlines, I/O after
observer poison and a valid context lagging transport time after send. API
absence and an initially incorrect SETTINGS fixture are separately qualified.
No unchanged C4/C5/S46/all40 suite was repeated.

The [evidence record](evidence/m2_h2_native_connection/README.md) contains the
current seven native sources, previous five-source baseline, canonical
references, new source/control snapshots, raw results and both review verdicts.
The prior 6,482-path public packet is authenticated by its parent archive.
Its 25 private environment originals are not read or republished by this delta.

Large Graphify tool snapshots remain local and have explicit size/hash
references checked against their captured manifests. They support AST-tooling
provenance only; they are not native runtime inputs or a portable reconstruction
claim. AST maintenance does not establish ignored-helper topology.

The controller snapshots dependencies before restoration. All inspected runs
restored zero files, so no current mismatch was shown. Moving snapshots after
restoration remains required before future runs that change restored bytes.
Active receive-error socket cleanup remains C6c/provider work; C4 does not own
socket closure. These are explicit downstream obligations, not completed gates.

Fresh source rehydration/runtime closure, strict disconnect, active signal and
termination receipts, real process/TLS/cleanup proof, builds, native all40,
full project/platform gates, adoption and remaining milestones stay open.
