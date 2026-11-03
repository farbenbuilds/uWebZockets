# Shared HTTP/2 delayed peer and standalone driver

The bounded core peer now supports delayed responses alongside buffered and
both large-upload cases. The standalone driver uses that same implementation:
`test_ready.py` shrinks from 127 to 37 lines, while the shared peer grows by
seven lines. `frame` is a direct re-export of the same function object.

The [archive](evidence/m2_h2_combined_core_async_peer/README.md) retains all 40
current modules, previous source, current checks and independent review. Its
[manifest](evidence/m2_h2_combined_core_async_peer/manifest.json) binds the two
changed modules and 38 unchanged modules.

Delayed requests follow actual health, delayed response, then health traffic.
The peer validates decoded metadata before earning each head, accepts the
canonical GET/empty-body/HEADERS END contract, and emits the exact ten-byte text
response. There is no selected delayed body record; the client emits no request
DATA or DATA END. Final permission does not complete the ordinary schedule.

Actual delayed execution observes three heads and zero request DATA. Its final
68 observations yield 71 buffered-middleware observations, derived from actual
application heads minus body middleware. The constructor preserves the existing
application shape and validates prior state without seeding results or invoking
the clock/client dispatcher. The driver keeps its signature, implicit `None`
return, supplied adapter clock, constant peer receive timestamp, callback
position and final option.

Actual serialized health/delayed traffic is followed by rejection of premature
final collection and encoded status traffic: heads remain two, DATA/END remain
zero, records remain unchanged and completion is not earned. A separate actual
producer-to-delayed chain preserves independently parsed output and binding
through a fresh context and final68; application heads reach 80. Neither proof
calls family test drivers or manufactures prior success.

Fourteen current focused checks pass in normal and optimized Python with empty
stderr. Each retains exact command/environment, source before/after, stdout,
stderr, exit and input-restoration receipts. The seven modules cover ready,
delayed, both large uploads, time/callback behavior, final capture, shared
late-credit/storage rules and inert imports. Existing upload hashing, exact
frame/byte counts, split refunds and pre-growth parser bounds remain intact.

The strict audit covers all 40 source modules and 13 current guarded/inert
helpers, each within nesting depth three. The current recorder auditor was
flattened after its depth-four violation was found; original bytes remain in
an explicit frozen mapping. Root verifies 9277 prior evidence files and the
167/191/273-file unit maps using that mapping. The 119-entry identity authority
contains 118 physical rows resolving to 113 files and one aggregate for 42
ordered codec files.

Temporary inputs reset across continuations. Each dependent command now first
restores and verifies exact source bytes from committed, pinned archives in
the same shell. This installs no dependencies and restores no compiled binary.

Historical limitations remain explicit: no fresh pre-edit identity capture,
the first source freeze followed its initial GREEN, one source edit used system
Python, and full context review occurred after the original edits. Earlier 14
stdout-only logs lack separate command/exit/stderr capture; the complete current
14-check set replaces them as verification evidence. Failed audits, missing
temporary-input runs and incomplete console-only captures remain qualified.

Independent spec, quality and structural review approves this standalone
pure-codec unit with no findings. Remaining peer extractions, actual coordinator
default/all40 aggregation, broad review, runtime/native gates, adoption and
milestone completion remain required. M2 remains open.
