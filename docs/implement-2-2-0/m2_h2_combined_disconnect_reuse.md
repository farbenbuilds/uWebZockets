# Combined HTTP/2 disconnect and body-slot reuse schedules

The combined client source now implements `disconnect` and `reuse`, reaching
38 reviewed source cases. Both shutdown selections still fail before actions;
full40/default/aggregate and native combined acceptance remain open.

The [evidence archive](evidence/m2_h2_combined_disconnect_reuse/README.md)
preserves all 33 current modules, the preceding 31-module source, failures,
raw results and independent review. Its
[manifest](evidence/m2_h2_combined_disconnect_reuse/manifest.json) binds source
identities and verification scope.

| Case | Heads | Small responses | Request DATA flow | Connections |
| --- | ---: | ---: | ---: | ---: |
| disconnect | 25 | 24 | 64 | 2 |
| reuse | 389 | 389 | 288 | 1 |

Disconnect sends 32 bytes without END on original stream 3 and observes the
supplied accepted-seven-byte paused record. Canonical staged termination
requires strictly typed supplied successful TLS unwrap and plain TCP EOF
facts before replacement. The replacement shares both case objects and exact
deadlines, while its protocol, parser, request/response ledgers and records
are fresh. Old-context observations are rejected after close.

On replacement, health and old-record status/control observations precede
recovery stream 17. Expired resume/cancel controls are checked before and
during recovery, with old/current status comparisons around every action.
Recovery sends seven bytes without END, then the remaining 25 with END.
The original and replacement retain independent 32-byte request debts; the
case sends 64 bytes regardless of the supplied 39-byte accepted total.

Reuse completes nine 32-byte uploads. Before each completion, every earlier
tag receives expired resume and cancel controls surrounded by old/current
status checks. There are 36 operations of each kind; final stale counters
are `8-i`. Rolling hashes and counters keep evidence bounded. Canonical
connection-only grants replenish response DATA credit earned on that same
connection, allowing the 389 replies without borrowing another ledger's credit.

All 40 current normal/optimized Python checks pass with empty stderr.
Each new-suite mode has four positive case executions, 41 named synthetic
rejections and focused replacement/deadline/credit controls. The shared
disconnect-then-reuse sequence and both standalone cases validate all 67
persistent records plus metrics in their final collections. AST and actual
empty/foreign-argv inert-import checks cover all 33 modules.

Initial RED proves unsupported selection only. Historical close-expectation,
debt, response-window and negative-expectation corrections remain preserved.
The first three historical command receipts were not saved; their raw results
and source snapshots are retained without inventing missing commands. Earlier
passing checks remain distinct from the final matrix after added assertions.

Independent source/spec/quality and structural review finds no actionable
findings. The identity audit checks 119 retained rows, 114 unique entries and
all 42 pinned codec files. Supplied app/TLS/EOF facts establish source ordering;
they do not establish native close, ownership, callback or body-slot reuse.
Both shutdown schedules, combined integration, runtime closure, native
acceptance, full project/platform/protocol gates and production source adoption
remain required. M2 remains open.
