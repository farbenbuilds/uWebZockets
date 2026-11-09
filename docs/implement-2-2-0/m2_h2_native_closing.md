# Native receive provenance and bounded closing receipts

The private combined HTTP/2 harness now has a source-tested closing helper.
Independent source review approves this slice. Native provider integration,
real TLS and process execution, and M2 acceptance remain open.

The receive primitive is installed before ordinary traffic, wrapped once by
the existing observer and bound to that exact observer object. Caller-owned
state counts primitive attempts, primitive returns and boundary returns
separately. Only an exception from the actual receive call supplies receive
provenance; preparation, clock, parser and passive-observer exceptions cannot
qualify. The original exception is rethrown unchanged and ordinary observer
poison remains absorbing.

At signal entry the helper freezes the immutable wire checkpoint and separate
lifetime counter baselines. Activation requires the same connection and
observer, unchanged prefix facts, supplied signal evidence and the canonical
post-signal termination state. The existing handler alone begins and finishes
termination. Accepted bytes pass once through the existing wire decoder and
credit accounting.

The terminal receipt is explicitly `local_transport_only`:
`complete_wire_proof=False`, authenticated close notification is
`not_established`, and internal or discarded plaintext is `unknown`. Known
partial tails, forbidden frames and excessive refunds fail. Unpaid debt stays
visible. A qualified primitive SSL EOF does not make ordinary sealing succeed.
Any later provider I/O invalidates the local verdict.

Closing keeps the 8,192-byte read, 65,536-byte and 4,096-frame ceilings together
with remaining case budgets and original deadlines. Child readiness is checked
once using supplied observed timestamps; later connections do not acquire a
new first-byte readiness deadline. Case, whole-run and grace deadlines never
restart.

## Verification

Focused normal and optimized runs cover primitive-only exception provenance,
ordinary EOF rejection, exact observer identity, single wrapping, immutable
prefixes, stale/reentrant/post-terminal calls, timeout and other exceptions,
deadline equality/regression, fragmented refunds, and residual budgets.
All 12 partial-frame splits reject both ordinary and actual-receive TLS EOF.

The serialized active fixture records checkpoint operation 145 and original
TLS EOF failure operation 146, with one begin/finish and retained 32/32 debt.
Serialized traffic earns 64 refunds totaling 832 bytes; refund 65 rejects.
The 4,096-frame and 65,536-byte boundary controls inject policy counters and
do not claim that traffic occurred. Native-specific inert imports also pass.
The old S46/all40 suites were not repeated.

An independent preservation audit matches all 46 accepted pure modules and
19,926 source/evidence files, all 809 native-preparation packet files, six wire
checkpoint publication files and the 119-entry source identity closure
(118 physical rows, 113 resolved files and 42 ordered codecs).

The [evidence record](evidence/m2_h2_native_closing/README.md) preserves the
exercised source versions, failures, commands, output and corrections. Its
historical limits are explicit: the initial successful preservation helper has
no separate pre-run snapshot; directory preservation starts at a later
midpoint; initial context-only console retention is incomplete. Missing history
is not reconstructed.

Formatting, conventions, release-version, documentation and online dependency
checks pass. The initial sandboxed dependency check could not resolve the pin;
the same check passed with network access enabled. Both attempts are retained.
These checks do not replace the outstanding build and platform gates.

These are scripted source tests. Actual readiness and signal ownership,
post-deinit records, exit/reaping, TLS/process cleanup, fresh runtime closure,
builds, native all40, full project/platform gates and production adoption
remain required, alongside the remaining original milestones.
