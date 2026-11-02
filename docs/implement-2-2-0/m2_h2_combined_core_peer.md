# Shared HTTP/2 buffered and large-upload peer

The buffered coordinator test and shared upload driver now use one bounded
serialization peer. Its constructors create fresh connection state from an
existing synthetic application store without dispatching a client or seeding
undispatched results. This prepares the peer interface needed for coordinator
composition; the coordinator still supports explicit empty or buffered-only
selection at this checkpoint.

The [source and evidence archive](evidence/m2_h2_combined_core_peer/README.md)
preserves all 38 current modules, the preceding 37-module source, raw failures,
checks and independent review. The
[manifest](evidence/m2_h2_combined_core_peer/manifest.json) binds their identities
and scope. Production adoption remains outstanding.

Both drivers share actual frame/HPACK serialization checks for metadata order,
duplicates, stream IDs, flags, startup and payloads. Client context stays in
driver-side boundary checks. Persistent records change only after concrete
serialized actions. Large bodies use incremental counts and hashes; no whole
upload or accumulated request history is retained.

The shared driver executes buffered then declared upload, the reverse order,
and an undeclared upload. Each large upload sends 100000000 bytes in 12208
bounded frames and verifies SHA-256
`190f6457d88258809df90a042b0226dab5537a1984f708cfd5bb90005835cea2`.
These are driver executions, not coordinator multi-case acceptance.

The original large final boundary retains 1781 bytes of connection debt and
1781 bytes of stream debt, its parser, counters and deadlines. A fragmented late
refund is consumed during final collection; the observed final budget is
3110658 bytes and this peer supplies 69 final reads. Buffered-only coordinator
counts remain 73 heads, 73 small responses, 257 request bytes, one SETTINGS,
68 final requests and 74 supplied reads/29903 received bytes. Read fragmentation
and ownership/TLS/process facts describe the synthetic peer, not native behavior.

Six current shared/coordinator/import checks pass in normal and optimized Python
with empty stderr. Earlier baseline and pre-self-review results remain distinct.
All 38 modules pass AST/main-guard and actual inert-import checks. The bounded
peer uses at most 8201 parser bytes, a 257-byte echo, ten pending packets and
16384 pending bytes; measured queued bytes peak at 593 in these schedules.
These Python fixture bounds are not native allocation or performance claims.

A genuine constructor regression first accepted a forged prior head count of
six after the five-request buffered case. Exact earned-count validation fixes
it; the failing source and result remain archived. The initial missing-API RED
and two audit-recorder mistakes are separately qualified in the evidence.

Independent spec, quality and structural review found no actionable issues.
The audit checks 4170 prior evidence hashes, 118 physical identity rows and all
42 ordered codec files. Formatting, conventions and release-version checks pass;
metadata remains 2.1.6. Native/build/compliance gates remain unrun for this
source-only checkpoint. Lifecycle/output peer construction, arbitrary ordinary
coordinator subsets, disconnect/shutdown composition, actual default/all40
aggregation, runtime/native verification and product adoption remain required.
M2 remains open.
