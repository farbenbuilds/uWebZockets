# M2: request streaming and incremental multipart

Status: implementation in progress. The [common contract](m2_common_contract.md),
[response guards](m2_response_guards.md), [incremental multipart utility](m2_incremental_multipart.md),
[part-sink adapter](m2_multipart_sink.md) and [head/body decoder](m2_body_decoder.md)
have verified component checkpoints. Reviewed plaintext and ordinary TLS live
matrices pass. The [H2 core live matrix](m2_h2_core_live.md) passes five cases,
including declared and undeclared 100000000-byte uploads. The
[pause/control successor](m2_h2_pause_control_live.md) proves partial/final/empty
pauses and public token validation through deinit. The
[admission successor](m2_h2_admission_live.md) passes 13 empty/limit/Continue/quota
and recovery cases. The [credit successor](m2_h2_credit_live.md) proves padded
trailers, zero-credit control progress and concurrent route isolation. The
[metadata successor](m2_h2_metadata_live.md) passes overflow metadata and helper
refusals. The [control successor](m2_h2_control_live.md) passes ready/paused
cancellation, peer reset and independent recovery. The
[application-error successor](m2_h2_application_error_live.md) passes chunk,
progress and end failures. The [lifecycle-close successor](m2_h2_lifecycle_close_live.md)
passes clean disconnect/recovery, nine-request reuse and active-upload shutdown.
The [native output successor](m2_h2_output_live.md) passes producer reuse,
held/ready output, a file range and early response ordering, bringing coverage
to 40 distinct H2 IDs across checkpoints. The
[combined acceptance contract](m2_h2_combined_contract.md) prepares all 40 IDs and
67 persistent body records with reviewed expected states and work bounds. The
[combined fixture](m2_h2_combined_fixture.md) preserves the shared slot/record
storage and canonical schemas, proves formatter bounds, and compiles in Debug
and ReleaseSafe. The [combined client core](m2_h2_combined_client_core.md)
prepares reviewed credit, stage, retirement and public-codec accounting with
actual pure startup proof. Its small-response limit fix passes scoped review.
The [public and large upload schedules](m2_h2_combined_public_cases.md) now add
four reviewed cases, caller-time checks and shared-state/final-debt proof.
The [pause/control schedules](m2_h2_combined_pause_cases.md) add four more
reviewed cases and exact pause/resume, control and retained-record checks.
The [admission schedules](m2_h2_combined_admission_cases.md) add nine empty,
limited and refusal/recovery cases with exact final/reset ordering.
The [Continue/quota schedules](m2_h2_combined_continue_quota.md) add four more
reviewed cases and nine retained records. The
[credit/trailer schedules](m2_h2_combined_credit_cases.md) add two more reviewed
cases with exact padding, trailer and independent credit accounting. The
[metadata/concurrent-route schedules](m2_h2_combined_metadata_concurrency.md)
add two more, with exact metadata/helper contracts, route isolation and retained
refusal retirement. The [cancellation/reset schedules](m2_h2_combined_cancel_reset.md)
add three more, with policy-aware terminal completion, credit reclamation and
sibling/recovery isolation. The
[application-error schedules](m2_h2_combined_application_errors.md) add three more,
with precise callback diagnostics and INTERNAL_ERROR completion. The
[producer/pressure schedules](m2_h2_combined_producer_pressure.md) add three more,
with exact hash-only output, canonical grants, paired completion and retained
binding diagnostics. The [file/early-final schedules](m2_h2_combined_file_early.md)
add two more, with exact range generation, retained file diagnostics and
END-before-reset ordering. The
[disconnect/reuse schedules](m2_h2_combined_disconnect_reuse.md) add two more,
with staged supplied-close replacement, independent connection credit and
stale-control isolation across nine uploads. The
[shutdown schedules](m2_h2_combined_shutdown.md) complete all 40 source IDs,
including held final collection, private comparison snapshots and fresh idle
state. Default/subset/aggregate orchestration, case/close/runner integration,
runtime closure and the actual two-child run remain open.
The [first coordinator lifecycle](m2_h2_combined_coordinator_ready.md) executes
explicit empty or one buffered-request child with retained observed facts and
supplied teardown validation. Other/default selections fail before effects;
full coordinator and combined acceptance remain open.
The [shared buffered/large peer](m2_h2_combined_core_peer.md) provides fresh
bounded connection factories used by both existing drivers. Both upload orders
and the undeclared large upload pass; coordinator multi-case/default acceptance
and native adoption remain required.
The [HTTP/3 source checkpoint](m2_h3_source_authentication.md)
authenticates the cached QPACK file against the retained exact-pin bundle.
The combined H2 run and full H2 gates, HTTP/3,
multipart transport composition, production adoption and final acceptance remain
open. The sections below preserve design decisions and component history.

The architect mapped body-cap admission, borrowed headers/captures, middleware
metadata, callback ownership, informational responses, and flow control across
the existing transports. Root chose the recommended route-level sink, explicit
startup opt-in, validated/discarded trailers, and a shared bounded HTTP/2 block
pool. The [accepted ADR](../adr/0008-request-body-streaming.md) records named
types, exact terminal ownership, backpressure, helper compatibility, admission
limits, capacity arithmetic, and ordered implementation acceptance.

The selected design leaves default buffering enabled and avoids an unconditional
72 KiB receive-pool addition per connection. Streaming allocations occur only
at startup. Its body decoder emits pure events; transport drivers own sink calls
and I/O. Pauses cannot stop HTTP/2 connection control processing, and the report
does not promise inbound sibling progress after connection-window exhaustion.

Fresh-context adversarial review found two actionable omissions: control-call
cleanup timing and exact ingress/refusal bounds. The revised ADR fixes both,
including concrete control errors, callback-only metadata views, synchronous
terminal callbacks, streaming-only framing limits, and exact transport storage
requirements. Bounded re-review found no remaining actionable design findings;
root accepted the contract. External CLI review was skipped during autonomous
implementation; later maintainer review remains separate.

The common contract is verified. Implementation continues through router
admission, HTTP/1/TLS, HTTP/2, HTTP/3, a 100 MB transport matrix, and incremental
multipart.
Every behavioral slice requires failing-first regression evidence and the
original milestone gates. Architecture review alone establishes no runtime
result; the common checkpoint records its separate executed checks.


## Compatibility gate before integration

The isolated common-contract prototype passes 24 focused cases, an existing
clone case, and a public-consumer compile, but a subsequent
[compiler audit](evidence/m2_compatibility/README.md) finds a material source
break: adding BodyNotBuffered to Request.form widens its inferred closed error
set even for default buffered callers. Both an explicit narrow-return wrapper
and an exhaustive catch compile against baseline and fail against the draft.
Earlier behavioral/source review did not expose that compiler-level contract.

The draft remains isolated and unintegrated. Preserve the original plan's
buffered source-compatibility requirement; revise the new streaming-aware
request surface before landing it. Aliases, anyerror, or unrelated old parse
errors do not solve the compatibility/refusal requirements. This finding
required a fresh architecture review, completed by the accepted revision below.
Core inline-control, terminal, progress and capacity design remains useful.
The common checkpoint now supplies actual revised-source compiler proof;
no live streaming capability is advertised.

## Accepted compatibility revision

The [revised ADR](../adr/0008-request-body-streaming.md) keeps Request and
OwnedRequest unchanged. New begin/end callbacks receive a distinct const
StreamingRequest containing metadata views and no raw body. Its fallible body
helpers have the dedicated BodyNotBuffered error; explicit metadata clones
own flat storage and derive views after construction. This avoids widening
legacy inferred error sets or pointing into a moved inline request.

New BodyRoute configuration defaults to rejecting legacy global middleware.
An explicit headers_only policy runs the complete existing chain once on a
header-only legacy Request with its baseline helper semantics. Admission also
checks late middleware registration before callbacks, quota or 100 Continue.
Existing registration and event-loop APIs retain their error surfaces.

Open response starts use BodyNotComplete before mutation. Legacy send_file
retains its closed error set and uses the existing BodyNotAllowed refusal.
No fallback or descriptor ownership is accepted by that refusal.

Independent review required one lifetime clarification: a pending outgoing
producer needs independently valid context, scratch and retained metadata after
upload cleanup. Synchronous response end/reset must also leave callback source
arrays and slots pinned until that callback returns. The ADR and later adapter
acceptance now require both. Bounded re-review found no remaining findings;
root accepts the revision.

[Declaration evidence](evidence/m2_typed_design/README.md) preserves the original
proposal, corrected derivative, five source bindings and 30 checked probe
artifacts. These prove type-level feasibility only. The original runtime-mode
draft remains frozen and unintegrated; its Request/default-slab growth must
not be applied to production assertions. The [common checkpoint](m2_common_contract.md) now proves the actual new types,
unchanged buffered compiler consumers, clone failure/lifetime behavior and
measured production layouts. Transport integration remains separate.


## Incremental multipart contract

[ADR0011](../adr/0011-incremental-multipart.md) accepts a pure event parser and
a separate concrete part-sink adapter. Input data is accepted only after sink
acknowledgement; carry is bounded by boundary.len + 4, with false-prefix replay
leaving real input available for resume. EOF validates without flushing deferred
application payload. Part cleanup is once-only, including paused terminal events.

[Review evidence](evidence/m2_multipart_design/README.md) records preserved legacy
helper error sets, distinct new typed refusals and the explicit init carry
minimum. MP-L1 re-declares ordinary delimiter padding as unsupported with a
reviewed restoration criterion. No general RFC conformance or implementation
result follows from this design. The standalone parser checkpoint records its
own implementation and verification; its part-sink adapter and request transport
integration remain separate gates.

## Confirmed platform activation scope

The user confirmed setup refusal for request streaming on community BSD until
worker wakeups and native validation are available. The
[isolated platform guard](m2_upload_platform.md) is implemented and independently
reviewed. Linux, macOS and Windows are eligible; native Windows release evidence
remains mandatory. Disabled and generic pure contracts remain available.

This bounds the subsequent H1 retirement implementation plan. Its historical
unrestricted V6 liveness claim remains rejected; no physical-close algorithm
or live upload follows from a setup-policy proof. The combined baseline must
retain current Root multipart, timer, fuzz and consumer changes before actual
H1 delivery and TLS integration proceed.

## Plaintext delivery checkpoint

The [reviewed plaintext implementation](m2_h1_plaintext.md) now demonstrates
both fixed-length and chunked 100000000-byte uploads, incremental matching
hashes, real file/pipeline ordering and ordinary drained shutdown on an owned
io_uring server. Its initial live matrix passes 18/20 cases; the two error-path
client failures remain explicit. The independently reviewed corrected client
passes 21/21 against the identical server, including complete 413 responses and
failed-begin quota reuse. The producer/lifecycle extension passes 26/26, including
metadata after binding reuse, concurrent routes and active-upload shutdown.
Source overlays and raw evidence are saved
on the feature branch. Full transport, multipart and final acceptance stay open.

The [TLS capacity clarification](m2_tls_capacity.md) explicitly qualifies the
ADR's raw-socket bound for encrypted receives. Existing BIO capacity bounds
ciphertext while the HTTP window continues to bound SSL_read. Independent
source review accepts the reservation requirements; its implementation and
ordinary live verification are recorded in the follow-ups below.

The [TLS driver checkpoint](m2_tls_driver.md) now preserves implemented,
independently reviewed extraction/receive/resume code with 27 focused tests and
three-target compilation. The [shutdown successor](m1_tls_shutdown.md) corrects
the inherited retry gap. The [strict ordinary TLS matrix](m2_tls_live.md) passes
37/37 through both cluster and configured single-App paths, including both exact
100000000-byte framings, retained input and owned active-upload shutdown.
Production adoption, genuine early data and final transport gates remain open.

## HTTP/2 queue foundation

The [reviewed receive queue and credit core](m2_h2_body_queue.md) passes nine
pure tests in each build mode and three-target/32-bit semantic compilation.
It preserves the accepted 73728-byte eight-stream pool bound and independently
pending credit scopes. Actual Session output acceptance/retry, registered body
sinks, per-stream metadata, lifecycle composition and a real 100000000-byte
HTTP/2 upload are required next; the core alone is not streaming capability.

## HTTP/2 Session and registered-sink checkpoint

The [reviewed concrete driver](m2_h2_session_delivery.md) now connects encoded
HEADERS/DATA to actual registered sinks and shared router admission. It preserves
observe-once/FIFO/Continue behavior, per-stream metadata and accepted-scope credit.
Four review findings have genuine failing-first regressions and clean scoped
re-reviews. Final173 selected tests pass per Debug/ReleaseSafe mode, with three-
target semantic compilation and unchanged measured stored layouts.

Source snapshots and a verified cumulative Git patch are on the feature branch.
Native startup/cold-owner binding, whole-operation borrow/closure/reuse composition,
actual100000000-byte H2/TLS proof and the original full M2 gates remain open.

The [startup storage successor](m2_h2_native_startup.md) now carves the enabled
receive pool, concrete drivers and capture matrices and binds owners at stable
addresses. Its140 selected tests per mode pass; three-target measurements preserve
disabled totals. Native body callbacks stay
gated pending complete TCP lifetime/closure/reuse composition and live proof.

The [terminal-input successor](m2_h2_terminal_inputs.md) now retires all identities
before bulk notification, preserves callback metadata through unwind, abandons
teardown output and implements slot-only drain/reset with stable generations.
Ordinary GOAWAY retains response output and exact seven-byte connection credit.
Both reviewers pass the final nesting refactor; 190 selected results pass per
Debug/ReleaseSafe mode on the final tree. Three-target compilation, eligible
32-bit checks, measured storage and raw evidence are preserved. Native TCP
activation, release pins, live upload proof and full milestone gates remain open.

The [native admission fact](m2_h2_native_admission.md) adds the measured stack-only
policy input and its shared-admission projection. An actual encoded regression
changes100 to425 before middleware/quota/begin/Continue and admits the ordinary
sibling;47 selected results pass per mode. Native TLS derivation and TCP lifetime
composition remain the next required integration work.

The [native TCP composition candidate](m2_h2_native_tcp.md) now wires body
selection/events/controls, actual policy derivation, complete Response hooks,
indexed metadata and whole-operation borrows. Existing completing state pins
enabled H2 release through the final async wake. Initial193 selected results per
mode pass; final79 covering results pass after the independently reviewed
three-callsite source-failure correction. Portability, layout and reconstruction
evidence retains exact source identities. Actual owned100000000-byte H2/TLS proof,
physical lifecycle/full gates and production adoption remain required next.
