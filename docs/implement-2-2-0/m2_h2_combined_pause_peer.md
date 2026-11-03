# Shared HTTP/2 pause/control peer

The standalone pause/control driver now uses one independent shared byte peer
for `partial_pause`, `final_pause`, `begin_pause_empty` and `control_rules`.
The [evidence archive](evidence/m2_h2_combined_pause_peer/README.md) retains the
40 current source modules, preceding source, checks and independent review.
The [manifest](evidence/m2_h2_combined_pause_peer/manifest.json) binds the one
changed module and 39 unchanged modules. This is standalone pure-codec evidence
with supplied synthetic application and transport facts; M2 remains open.

The constructor accepts the canonical four-key persistent application, validates
earned prior state, and returns the existing seven-key connection interface.
It queues startup SETTINGS/ACK without invoking the clock, client dispatcher or
observer, mutating application facts, or selecting completed records. The driver
keeps its signature, same-object app return, existing negative diagnostics and
bounded three-request wrong-tag diagnostic.

Facts follow validated serialized traffic. Upload metadata earns admission and
begin facts; DATA earns wire and accepted-prefix bytes, hashes and ordinals;
resume earns completion. Partial pause sends 8192 non-END bytes followed by
4097 END bytes, retaining only the seven-byte accepted prefix until actual
resume. Final pause waits for resume after its 32-byte END. Begin pause occurs
before the empty DATA END. Control rules enforce their exact 20-request active,
resume and stale-control sequence. The peer reads no client capture or context
to establish these observations and retains no request/frame/read histories.

| Case | Ordinary request heads | Request DATA bytes |
|---|---:|---:|
| partial_pause | 7 | 12289 |
| final_pause | 6 | 32 |
| begin_pause_empty | 6 | 0 |
| control_rules | 20 | 64 |

An actual four-case shared-app proof starts with unselected records, earns all
prior cases from traffic, and reaches 107 heads including final68. Final
permission alone cannot skip the ordinary sequence. Collection preserves the
same protocol, parser, ledgers, debt, receive caps and deadlines. A separate
retention check supplies copied historical producer facts explicitly; it does
not claim prior producer traffic.

Parser capacity is 8201 bytes, frame payload and each send span are at most
8192 bytes, and at most two pending packets occupy at most 16384 bytes. HPACK
table/header-list caps are 4096. Finite stream summaries, rolling hashes,
request cursors and read/byte caps reject invalid growth before mutation,
including repeated attempts. Queued responses do not establish delivery.

Four final covering checks pass: the pause driver and all-module import check,
each in normal and optimized Python. Two direct proof runs and two strict
audits also pass, with empty stderr. Every check retains exact argv/env/cwd,
source before/after, separate stdout/stderr/exit and a same-shell pinned-input
restoration receipt. All 40 source modules and three current unit helpers meet
the structure/guard checks; helpers are inert on import and empty/foreign argv.

The fresh pre-edit freeze binds all 40 accepted sources and the unchanged
119-entry identity authority: 118 physical rows, 113 resolved files and one
aggregate over 42 ordered codec files. All 9727 prior evidence files remain
unchanged. Root independently checks source ownership, preserved history,
covering receipts and current helper structure.

Intermediate corrections remain visible. The first converted-driver receipt
has an additive reference to its actual restoration receipt. A premature-fault
test initially expected the wrong diagnostic; executing the frozen original
driver established `invalid terminal`, and both failed expectations remain.
A genuine oversized-send RED precedes its guard fix. An audit cwd correction
and Root's omitted-PYTHONPATH audit invocation are retained with their later
successful checks; they do not represent native failures.

Remaining peer extractions, actual default/all40 coordinator acceptance, broad
combined review, runtime/native/project/platform gates, production adoption and
every original milestone remain required. No native execution or milestone
completion is claimed here.

Independent spec, quality and structural review approves this scoped peer
preparation with no actionable findings. Publication accuracy is checked
separately before committing the checkpoint.
