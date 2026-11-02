# First combined HTTP/2 coordinator lifecycle

The coordinator now executes explicit empty selection or one
`('ready_buffered',)` child lifecycle through the existing concrete dispatcher.
Other valid selections and omitted/default all40 fail before clock or factory
effects at this checkpoint. All 40 case handlers remain intact; their combined
orchestration and native acceptance remain open.

The [evidence archive](evidence/m2_h2_combined_coordinator_ready/README.md)
preserves all 37 current modules, the preceding source, failures, raw checks
and independent review. Its
[manifest](evidence/m2_h2_combined_coordinator_ready/manifest.json) binds source
identities and verification scope.

| Buffered child observation | Value |
| --- | ---: |
| Heads / small responses | 73 / 73 |
| Request DATA flow | 257 |
| Connections / client SETTINGS | 1 / 1 |
| Final status/metrics requests | 68 |
| Supplied peer reads / received bytes | 74 / 29903 |

The last row records this generated peer's fragmentation, not a native packet
requirement. The test independently decodes startup and outgoing frames,
metadata, stream IDs, flags and the exact 257-byte echo/hash. Five concrete
case requests precede 67 statuses and metrics; final observations count once.
Both outstanding request scopes retain 257 bytes across final collection.

Empty selection creates no child, connection, collection or callback effects.
Static schemas reject malformed selections, identities, booleans posing as
integers and overflow. Logical child identity follows the run identity and
ordinal; it is not OS process identity. The current fixture allows 1–32 ASCII
alphanumeric/underscore run IDs. The older adapter's longer/hyphen grammar is
not imported or reused.

Whole and readiness bounds use checked caller-supplied units. Case timing starts
before connection setup and continues through startup, requests, final capture
and teardown. One clipped grace deadline follows collection. The coordinator
then validates supplied normal close, SIGTERM, process/reap and post-deinit
facts in order. This normal main teardown earns no idle-shutdown case.

Actual parsed records and metrics form a private comparison baseline. Process
and post callbacks validate and seal bounded copies before later hooks can
mutate their original dictionaries. Returned evidence owns its facts; no extra
GETs, collections, model-generated completion or active-only stage transition
is introduced.

All four current coordinator/import checks pass in normal and optimized Python
with empty stderr, including 37-module AST/main-guard and actual inert-import
checks. Earlier import and pre-self-review matrices remain separate history.
The new suite covers 67 typed descriptor/connection/lifecycle rejections plus
preflight, ordering, expiry, callback-error and alias controls.

Initial RED proves the missing module only. A later genuine regression showed
that discarding checked pre-open time let clock sequence `2,2,2,3,2` silently
accept rollback. Passing the checked time into the adapter fixes that handoff;
the failing source and result remain preserved.

Independent source/spec/quality and structural review is approved. The audit
checks 119 retained identity rows, 114 unique entries, all 42 ordered codec
files and 3962 captured prior evidence files. Readiness, ownership, TLS, signal
and process outcomes are supplied synthetic facts. This proves no native
fixture, socket, process, close or reap behavior. Multiple cases/children,
replacement receivers, selected outputs, default/aggregate acceptance, runtime
closure, native verification, project gates and production adoption remain
required. M2 remains open.
