# Shared HTTP/2 admission peer

The standalone admission driver now uses one independent shared byte peer for
all nine admission schedules and their recovery requests. The
[archive](evidence/m2_h2_combined_admission_peer/README.md) retains all 40 current
modules, preceding source, checks and independent review. Its
[manifest](evidence/m2_h2_combined_admission_peer/manifest.json) binds the one
changed module and 39 unchanged modules. This remains in-memory codec evidence
with supplied synthetic application/transport facts; M2 remains open.

The constructor validates the canonical four-key application and earned prior
facts before mutation, returns the existing seven-key connection, and queues
startup SETTINGS/ACK for normal receive. It invokes no clock, client dispatcher
or observer, and seeds no selected completion. The driver preserves its
signature, same-object app return, exact fault diagnostics, body checks and
shared nine-case sequence.

Facts follow validated traffic. HEADERS earns metadata/admission/begin facts
with zero accepted bytes before DATA. Declared refusal follows exact HEADERS;
observed refusal follows the offending non-END DATA. The 32-byte accepted
prefix status must be delivered before byte 33, with the guard checked before
hash/count/app mutation. Empty HEADERS END and separate empty DATA END remain
distinct. Refusal final HEADERS precedes NO_ERROR reset and normally carries
neither informational response nor response DATA.

| Case | Ordinary heads | Request DATA bytes |
|---|---:|---:|
| empty_headers | 3 | 0 |
| empty_data | 3 | 0 |
| empty_declared | 3 | 0 |
| limit_declared | 3 | 32 |
| limit_undeclared | 3 | 32 |
| limit_declared_reject | 4 | 32 |
| limit_observed_reject | 5 | 65 |
| zero_declared_reject | 4 | 0 |
| zero_observed_reject | 4 | 1 |

Refusal-case DATA counts include the actual recovery upload where applicable.
The actual nine-case shared-app proof earns 32 ordinary heads plus final68,
reaching 100 heads. Final permission cannot skip ordinary/recovery completion
or delivered-response barriers. Collection preserves protocol/parser/ledgers,
debt, cumulative receive accounting and deadlines. A separate retention proof
uses copied historical producer facts explicitly; it claims no producer traffic.

The peer retains bounded cursors, at most two upload summaries and rolling
hashes. Parser capacity is 8201 bytes; send/frame payload is at most 8192.
At most two packets occupy at most 16384 bytes, each at most 8192. HPACK and
finite receive/byte caps reject invalid growth repeatedly before mutation.
Queued responses/resets have separate delivered receipts. A direct RED caught
delivered HEADERS being counted only with the later reset; the fix records
each frame at its actual return boundary.

Four covering checks pass: admission and all-module imports, each normal and
optimized. Two final strict direct proofs and two final strict audits also
pass with empty stderr. Per-command records retain exact argv/env/cwd,
source before/after, check/helper snapshots, separate stdout/stderr/exit and
same-shell pinned-input restoration. The fresh pre-edit freeze binds accepted
all 40 sources and the 119-entry authority: 118 physical rows, 113 resolved files
and 42 ordered codec files. All 10,118 prior evidence files remain unchanged.

The final proof helper preserves original-call count, exception identity and
instrumentation restoration. Its former long dispatch chain was preserved and
flattened after Root's strict-depth audit; both depth checks remain enabled.
Final strict proof/audit runs cover the corrected helpers. The four module
checks remain bound to unchanged source. One pathlib-only helper edit omitted
a PYTHONPATH component; every executable check used the exact pinned path.
All failed/intermediate attempts and qualifications remain in the archive.

Remaining Continue/credit/metadata/terminal peers, independent delivery-receipt
instrumentation, actual default/all40 coordination and broad review, runtime/
native/project/platform gates, adoption and every original milestone remain
required. No native execution or milestone completion is claimed here.

Independent specification, quality and structural review approves this scoped
peer preparation with no actionable findings. Publication accuracy is checked
separately before committing.
