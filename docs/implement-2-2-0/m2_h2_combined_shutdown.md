# Combined HTTP/2 active and idle shutdown schedules

The combined client source implements `shutdown_active` and `shutdown_idle`,
completing all 40 concrete schedule IDs. This source coverage does not establish
default/subset/aggregate orchestration or the native two-child combined run.
M2 remains open.

The [evidence archive](evidence/m2_h2_combined_shutdown/README.md) preserves all
35 current modules, the preceding source, failures, raw results and independent
review. Its [manifest](evidence/m2_h2_combined_shutdown/manifest.json) binds
source identities and verification scope.

| Case | Heads | Small responses | Request DATA flow | Primary stream |
| --- | ---: | ---: | ---: | ---: |
| shutdown_active | 71 | 70 | 32 | 3 |
| shutdown_idle | 69 | 69 | 0 | 1 |

Active shutdown sends 32 bytes without END and observes the supplied paused
record with seven accepted bytes, then collects all 67 statuses and metrics with the
primary held. Those 68 observations are included in the table's counts. Parser,
both credit ledgers, 32-byte debt in each request scope, and original deadlines
survive the boundary. Final collection keeps its existing byte/read bounds.

Only after collection does the schedule validate supplied owned SIGTERM and
post-signal EOF/TLS-EOF facts, normal process outcome and post-deinit records.
No primary response or end callback is fabricated. The sole permitted body
transition is the active request's cancellation, inactive/unpaused state and
shutdown reason; bytes, hash, chunk diagnostics and other records remain equal.
Grace is at most 15 supplied seconds, clipped to the existing deadlines.

Idle uses fresh synthetic application state with all-zero records. Health on
stream 1 is its completed primary, followed by 67 statuses and metrics, for a
buffered count of 69. Supplied normal client close precedes signal/process/post
facts. It does not invent an active-only stage transition or require the
disconnect case's strict TLS unwrap experiment.

Every successful ordinary final collection retains its actual parsed records
and metrics at `context.final_observations`, preserving its `None` return and
request counts. Shutdown keeps the capture private through teardown hooks and
all record/metric/output/binding comparisons, then publishes that same object.
This prevents matching edits to exposed before/after facts from hiding a change.
Retained output and binding observations need no additional GETs.

The preceding 42-command normal/optimized matrix passes with empty stderr.
After two review fixes, six current covering checks pass; the six first-fix
checks remain separate historical evidence. Current shutdown checks have five
positive executions and 78 synthetic rejections per mode. All 35 modules pass
AST/main-guard and actual empty/foreign-argv inert-import checks.

Initial RED proves unsupported selection only. The ordinary-capture regression
then reaches the complete serialized collection before failing on lost facts.
Three subsequent alias REDs reach a schedule-level acceptance sentinel before
outer application assertions. The fixed schedule rejects changed record,
output and paired-binding evidence against its private snapshot. Valid observed
wildcard diagnostics remain available without another collection.

Independent source/spec/quality and structural review is approved after both
fixes. The audit checks 119 retained identity rows, 114 unique entries and all
42 ordered codec files. Seeded earlier records and supplied process/TLS/EOF
facts are synthetic inputs; they do not execute earlier cases or prove native
ownership, callbacks, close or post-deinit behavior. Combined orchestration,
runtime closure, native acceptance, HTTP/3 and multipart composition, full
project/platform/protocol gates and production adoption remain required.
