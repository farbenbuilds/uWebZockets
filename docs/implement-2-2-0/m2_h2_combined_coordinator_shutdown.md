# HTTP/2 coordinator idle and active shutdown

The coordinator now implements idle and active shutdown children using the
canonical handlers. It accepts valid selections from all 40 catalogue cases,
including omitted/default selection. Eight actual representative schedules
pass; default/all40 acceptance currently reaches the factory boundary only.
Actual all40 execution remains required.

The [archive](evidence/m2_h2_combined_coordinator_shutdown/README.md) preserves
the reviewed source, regressions and checks. Its
[manifest](evidence/m2_h2_combined_coordinator_shutdown/manifest.json) binds 40
modules: three changed, one new shutdown composition test and 36 unchanged.
All family peers, canonical handlers, core, model and codecs remain unchanged.

The catalogue child plan creates an optional fresh idle child before the main
child. Idle teardown finishes before the main factory runs. Applications,
completed IDs, observations, counters and connection ordinals remain separate;
the main child retains caller order. Both children share the original whole-run
deadline, with their own clipped readiness interval.

Descriptors require exactly the callbacks selected cases need. Active-only has
no unused close callback; preceding ordinary work requires one. Validated maps
are copied before connect. Idle/active handlers own their final collection and
completion; the coordinator adds neither another collection nor ordinary finish.
Active keeps its 32-byte request without END or primary response through the
final observations, then uses canonical post-signal termination.

Private clock, checked time, original deadlines and one clipped grace survive
every exposed shutdown callback and the idle/main handoff. Typed callback facts
are copied before later hooks run. Actual counters and local summaries are
sealed before teardown; saved scalar observations support the canonical count
check without manufacturing completion or resetting transport state. Parsed
producer/file output and binding survive fresh and replacement contexts.

| Actual selection | Heads | Small | Request DATA bytes | Connections | Collections |
| --- | ---: | ---: | ---: | ---: | ---: |
| Idle | 69 | 69 | 0 | 1 | 1 |
| Idle, buffered | 142 | 142 | 257 | 2 | 2 |
| Active | 71 | 70 | 32 | 1 | 1 |
| Buffered, active | 76 | 75 | 289 | 2 | 1 |
| Producer reuse, active | 80 | 78 | 96 | 2 | 1 |
| Idle, producer reuse, disconnect, active | 174 | 171 | 160 | 5 | 2 |
| Idle, producer reuse, buffered | 151 | 150 | 321 | 3 | 2 |
| File, active | 78 | 76 | 65 | 2 | 1 |

Each connection retains the existing eleven-field local summary and copied
release facts. Active teardown contains signal, termination, canonical
transport result, process and post facts; ordinary/idle teardown contains
close, signal, process and post. Explicit empty remains without effects.

Independent review found two final-state validation gaps: response-ledger
residue or lost active closed flags could succeed, and ordinary final callbacks
ran after their last quiescence check. Six actual regressions retain the reviewed
coordinator before the fixes. Final validation now rejects response residue,
requires canonical active closed flags, and runs after ordinary finish. It
preserves the injected corruption on failure; it does not clear ledgers or
require request debt to be zero. Healthy controls retain debts of 0, 257 and 32.
Scoped re-review addresses both findings with no new defects.

Eight current shutdown/composition/coordinator/import checks pass in normal and
optimized Python with empty stderr. They retain the ordinary/disconnect, large,
positive-debt, output/binding, time, callback-error and strict-close controls.
The source audit covers 40 AST modules, guards/inert imports, two current guarded
helpers, 6136 prior evidence files, 1278 reviewed unit files, the preserved first
51 files/report prefix, and 119 input identities including 42 ordered codecs.

The initial idle RED rejects before factory/wire. A later intermediate parser
residue RED preceded its fix. Earlier eight-result sets remain distinct from
the current fix set. Two failed new test observer-order expectations are retained;
only that expectation changed, preserving rejection/state checks. Initial
baseline output was interactively transcribed, not redirected raw output.
Original helper bytes and report remain frozen; the current helper is guarded.

Transport, TLS, EOF and process facts remain synthetic. Remaining peer
extractions, actual default/all40 aggregation, broad combined review,
runtime/native two-child validation, full project gates and production adoption
remain required. M2 remains open.
