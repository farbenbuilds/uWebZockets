# v2.3.0 implementation plan

Source requirements: engineering roadmap Section 9 (D-0 through D-11),
Section 17.3 (FS-0), Section 17.4 (FS-1), the v2.3.0 release checklist,
and the Section 8.2 carryovers. The task list is `tasks/todo.md`.

## Frozen release scope, 2026-11-18

The user directed completion of the seven currently open requirements without
opening new work. Preserve the existing 70-entry checklist denominator and the
original acceptance criteria indexed in `tasks/v2_3_scope.md`. Implementation
checkpoints belong beneath those existing requirements. New features, optional
refactors and broader requirements belong in `tasks/next_version.md`.

Necessary fixes, verification, publication and integration stay in v2.3.0.
Do not mark an unfinished requirement complete or move it to the next version.
The certificate ownership work is a dependency of the existing PostgreSQL TLS
allocation gate; it is not a separate release goal. Keep the supported SQL
configuration intact, and avoid broadening the native capability into a general
allocator or new native configuration framework.

## Architecture

SQL owns wire protocol, authentication, connection state, prepared statements,
bounded row storage, transactions, and reconnects behind `uz.sql`. The core
owns only explicit per-worker service hooks. Each worker starts its services
after listener bind, rolls back startup failures, and drains services before
destroying its loop. SQL and SQLite are independently build-gated; the C ABI
remains core-only. SQLite is included in this implementation.

The runtime developer owns SQL. Protocol and authentication, worker lifecycle,
and SQLite/build integration have independent implementation owners. Shared
exports, centralized test imports, migrations, documentation, and release
metadata are serialized through the root integrator. An independent review
follows implementation and required verification.

## Ordered slices

1. Pure bounded PostgreSQL codecs, authentication, and binary rows.
2. Per-worker service lifecycle with startup rollback and reverse shutdown.
3. Real nonblocking PostgreSQL transport, pool, prepared execution, transactions.
4. Feature gates and optional native SQLite amalgamation/backend.
5. Embedded checksum migrations with locking and rollback.
6. Metrics, statement-only tracing, runnable examples, database benchmark routes.
7. PostgreSQL/SQLite integration, allocation coverage, fuzz and CI gates.
8. SQL/module documentation, ADRs, synchronized release metadata.
9. Independent review, fixes, and full release gate audit.

Each slice has focused failure-path tests before implementation, then runs
the applicable build/tests. Final checks include formatting, conventions,
release metadata, documentation, the full suite, sanitizers, cross-target
compilation, downstream consumers, and relevant protocol gates.

Verification amendment, 2026-11-12: the user deferred remaining smoke and
security test runs to their own follow-up. Preserve the tests and thresholds,
retain prior evidence, and label newly deferred runs as deferred. Continue
implementation, functional regressions, build checks, conventions and release
metadata checks. This instruction does not turn a deferred check into a pass.

## Evidence requirements

Local tests establish correctness, bounds, ownership, and allocation behavior.
They cannot establish the required 300K RPS database result, quiet-host
measurements, second-machine dependency resolution, or native Windows/macOS
runtime evidence. Keep each requirement open until an authoritative artifact
proves it. Existing vendor changes belong to the user and are preserved.

Section 8.2 carryovers include ownership extraction, WebTransport activation,
UDP GRO, external HttpArena integration, fork/platform closure, and measured
kTLS/splice integration. Conditional prerequisites remain explicit; no
release is declared complete by deleting or weakening these requirements.

## Section 8.2 ownership closure

The scoped architecture audit adopted these concrete seams instead of using
the 1000-line review flag as a mechanical split target:

1. App worker construction, supervision, failure capture, and shutdown live in
   `cluster_runtime.zig`; retain the existing public cluster interface.
2. Connection parking owns fixed slots, replacement, cancellation, counts, and
   exactly-once expiry. TCP retains timers, stream lookup, and transport effects.
   Clear parking state and re-arm activity before invoking application code.
3. HTTP/2 storage owns checked layout, alignment, carving, and inline bundles.
   Preserve the Session capacity/storage aliases and caller-owned lifetimes.
4. Response async state owns generation checks, completion, cancellation, and
   wake ordering. Shared pure field validation has a neutral module owner.
5. QUIC header sets own bounded decode, validation, finalization, and one-shot
   release. Stream and engine retain their current type identities via aliases.

The implementation owners work on disjoint source modules. Root serializes
test imports and documentation. Independent structural review and combined
protocol, sanitizer, package, and cross-target checks gate closure. This work
does not satisfy WebTransport, GRO, platform, or performance requirements.

## Next WebTransport backend slice: reliable reset

The uni-stream prerequisite is frozen at local candidate
`0f7382b17b38d7fb0496a0b75b3c66ace79e49e8`; its reviewed source and evidence
must remain unchanged. Start the next scratch clone from that candidate.
Root pins, App interfaces and live capability records stay unchanged.

The accepted draft-16 design cites reliable-stream-reset **draft 09**, not the
latest draft: empty transport parameter `0x1d` and frame `0x24` containing
stream ID, application error, final size and reliable size. The receive-support
option defaults off. Only peer willingness permits sending the extension.

The implementation must preserve and retransmit the required prefix, retain
input until that prefix reaches the application, and report reset afterward.
Reliable size may decrease; final size and error remain fixed. Final size is
still flow-controlled. Keep independent send/receive state, with no per-reset
allocation, payload copy, global registry or extra reset queue.

Ordered work:

1. Capture a real encrypted-engine RED: lose the prefix packet, deliver reset
   first, recover and consume the prefix, then report the exact error while a
   healthy sibling completes. Add bounded codec/parameter vectors and parser
   fuzz coverage.
2. Implement codec, frame classification and parameter plumbing without
   advertising incomplete receive behavior.
3. Implement receive state and delayed callback/error delivery, preserving
   classifiers, reassembly and flow-control accounting. An HTTP parser's wire
   offset alone does not prove application delivery: queued header sets and
   blocked QPACK ownership must remain retrievable before reset visibility.
4. Implement send state, buffered/packetized prefix retention, loss, packet
   resizing and true ACK accounting. Existing frame reference release also
   occurs during elision; it cannot prove a reset generation was acknowledged.
   Freeze and retain the entire final-size connection debit across suffix
   trimming, STOP_SENDING, boundary reduction and destruction, including paid
   or unpaid HTTP frame bytes. Never refund discarded frozen-final bytes.
5. Independently review remembered transport parameters and early-data
   compatibility. Root's live 0-RTT policy remains disabled.
6. Test both directions and initiators, reordered/repeated/smaller resets,
   delayed reads, obsolete ACKs, ordinary FIN/reset/STOP_SENDING, invalid fields,
   closed streams and teardown. Include queued HTTP headers and a healthy
   sibling that must not reuse frozen-final flow credit. Record stream/packet
   structure-size changes.
7. Verify with a pinned external compatible client, then repeat native unit,
   sanitizer, cross-compilation and independent review gates before freezing
   another proposal. This does not close the later WebTransport session work.

Official wire contract:
[reliable-stream-reset-09](https://datatracker.ietf.org/doc/html/draft-ietf-quic-reliable-stream-reset-09),
[WebTransport draft 16](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-16.html).

The external reset oracle uses quic-go commit
`8d34dbcccc219375fa9fbaa9b7b22caeebd7d49d`. Its Go-to-Go control test
verifies explicit CA trust, directional negotiation, a 33-byte required prefix,
optional suffix, reset error `0x175`, and a healthy sibling in both directions.
Native lsquic interoperability remains a separate acceptance check. The oracle
and Go toolchain are verification tools outside the library build.

## Following WebTransport slice: live sessions

SETTINGS checkpoint, 2026-11-13: local proposal
`8b0ef12414cdcf7b8c20e0b9f4fceb321358c2d0` adds opt-in bounded generation,
an immutable peer snapshot and quiescent notification. Its
[source and functional evidence](../benchmarks/results/lsquic_webtransport_settings_v1/2026_11_13/README.md)
are retained separately from root dependency integration. Smoke/security
runs remain deferred. CONNECT and child-stream work is still required.

Stream-credit checkpoint: local proposal
`9f0088c58fe67cccf1871dc172c90c2ec6f97944` aligns WT client uni admission
and advertisement and selects bidi send credit by initiator. The
[functional evidence](../benchmarks/results/lsquic_webtransport_credit_v1/2026_11_13/README.md)
retains actual peer transport parameters, exact uni exhaustion and four bidi
halves. WT client bidi admission still needs to match its advertised limit
when server child-stream classification is added. Ordinary HTTP defaults stay
unchanged; root dependency integration remains separate.

Child-stream checkpoint, 2026-11-16: unpublished proposal
`a1947ce3a4ceeb98413e53014cc87f72b6d89869` retains raw child creation,
incremental classification, directional metadata and reset-prefix handling.
Its [source and results](../benchmarks/results/lsquic_webtransport_children_checkpoint_v1/2026_11_16/README.md)
record 41 passing focused Debug scenarios and one unresolved `pending-reset`
failure: reset notification can precede typed publication while SETTINGS are
pending. Complete callback ordering and remaining lifetime/recovery cases before
final review, full functional gates or runtime integration. This is a saved
work-in-progress checkpoint, not a completed prerequisite.

Reviewed native follow-up: local proposal
`2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c` resolves the checkpoint's
reset-publication failure and adds STOP final-size preservation, immediate
lengthless-type placement errors and GOAWAY isolation. Its
[source and functional evidence](../benchmarks/results/lsquic_webtransport_children_v1/2026_11_16/README.md)
retain 65 scenarios in all three modes, all 83 native Debug cases, cross-target
production compilation and compiler-derived ABI constants. The proposal remains
unpublished; child loss campaigns, independent client acceptance and the Zig
runtime below remain required.

After the reset candidate is reviewed, extend the fork's draft-16 SETTINGS,
negotiation snapshot/notification, long-lived CONNECT and raw child-stream
classification. Keep parsing and packet ownership in the fork; session
admission, bounded capsules and application routing belong in Zig.

The exact draft-16 client is webtransport-go commit
`2a2b547d91a8a70e313e7ce61538b066554021b5`. Its quic-go v0.62.0 dependency
resolves to commit `793f74d8e03368c5aded128af6f48d21dbb47f73`; the annotated
tag object is not an implementation pin. This client is another external
verification tool, separate from the reliable-reset oracle above.

Ordered integration:

1. Add negotiation, CONNECT-before-SETTINGS and header-only admission tests.
2. Add fork SETTINGS/query/notification and child classification on top of the
   reviewed reset candidate. Retain ordinary HTTP classifiers and siblings.
3. Give the engine fixed generation-checked connection slots and a typed
   internal binding to existing App datagram routes and rings.
4. Admit CONNECT at completed headers after prerequisite, authentication and
   explicit Origin approval. Keep both body directions available for capsules;
   retain the admitted route without borrowing released header storage.
5. Key sessions by connection generation and CONNECT stream ID. Bound early
   associations; drain them by session. Charge final child payload size once,
   excluding its actual association-prefix length, for FIN and pending reset.
6. Route datagrams through `App.dispatch_datagram`; clear rings before slot
   reuse. Track independent transmit/receive data and stream consumption.
   Parse fragmented capsules with bounded carry, skip unknown payloads without
   retaining their declared size, and reject HTTP/2-only flow capsules.
7. Verify the pinned client's single-session and multi-session modes, two
   connections both using session ID zero, fragmented prefixes/capsules,
   reset-before-association, exhaustion, session teardown and healthy siblings.
   Its lack of optimistic session traffic requires separate early-traffic tests.

The accepted `App.datagram`, `datagram_context` and `next_datagram` public
surface remains the application interface. Publish reviewed maintained-fork
commits before synchronizing root dependency views or activating capabilities.
These remaining steps are planned work, not completed release evidence.

### Bounded Zig runtime implementation

Step 1 checkpoint, 2026-11-16: the private native-contract adapter now compiles
against the published pin and the real local candidate. All 964 centralized
published-pin tests pass. The candidate's ten-test TLS and component cohort
passes Debug, ReleaseSafe and ReleaseFast, including positive 64-bit peer
limits, long-lived CONNECT and both initiators/directions of raw children.
The [source, scaffold and results](../benchmarks/results/webtransport_zig_backend_v1/2026_11_16/README.md)
retain exact inputs. Step 2 and subsequent runtime integration remain open.

Step 2 ownership checkpoint: connection slots and stream sidecars now back
the actual engine callbacks. Closed slots retain their generation until every
stream releases its lease; exhausted generations never wrap. Candidate HTTP
headers establish HTTP classification before body reads, and completed peer
facts are cached once. All 971 centralized tests pass. A real TLS client drives
partial/completed POST bodies, native contexts, abort cleanup and slot reuse
through production engine processing and UDP transmission. The
[scaffold and results](../benchmarks/results/webtransport_zig_engine_v1/2026_11_16/README.md)
retain that functional scope. Positive typed-child engine integration awaits
the session binding/admission slices; WT negotiation remains disabled.

Steps 3–4 checkpoint, 2026-11-16: App supplies stable named admission,
datagram-delivery and clear callbacks after storing its transport. The
capability-gated candidate admits explicit synchronous CONNECT routes at
completed headers, requires application authentication and Origin approval,
retains registered route identity after header release, and establishes a
nonterminal response. A configured builder can enable HTTP/3 without losing
its capacities. The initial profile permits one session per connection with
session flow control off; it does not satisfy the multi-session requirement.

All 991 centralized published-pin tests pass. Eight actual App/TLS cases pass
in Debug, ReleaseSafe and ReleaseFast: header-time success, Origin/auth
refusals, explicit-method and middleware policy, independent session zero on
two connections, excess-session and incompatible-peer resets, cooldown
reentry, credit-blocked reset recovery and delayed FIN. The pure capsule
decoder's 16 cases also pass in all three modes. The
[App admission checkpoint](../benchmarks/results/webtransport_app_admission_v1/2026_11_16/README.md)
retains exact sources, candidate identities, original failures,
commands and limits. Independent review has no remaining required findings.

At that checkpoint, native datagram delivery/ring-clear verification,
pending-SETTINGS cancellation execution, early association buffering, typed
children, multi-session flow accounting and the independent draft-16 client
remained open. The published
dependency views are unchanged and do not activate WT. These checkpoints do
not complete the runtime slice or v2.3.0; smoke/security runs remain deferred.

Routing and deferred-admission evidence checkpoint, 2026-11-16: all 18 Zig
tests (17 functional cases and one import-discovery anchor) pass in Debug,
ReleaseSafe and ReleaseFast, 16/16 build steps per mode. The unchanged
production source also passes all 991 centralized tests. The real native/UDP
cohort proves header-slot reuse, two connection rings with session zero,
callback payloads, overflow/recovery, ordinal continuity, Close/abort clearing
and generation reuse. Native packet/decryption counters pair negative
delivery checks with isolated actual datagram packet arrival.

Original client SETTINGS are held and resumed through the existing native
test observer. Positive admission resumes once; RESET is observed known but
not yet visible before SETTINGS resumes, while STOP takes the synchronous
pending-cancellation path. Fragmented invalid flow-control input is ignored in
flow-off mode, DRAIN still permits datagrams, and Close clears the session and
ring before client FIN. Datagram-triggered cooldown reaches native GOING_AWAY
after the engine callback unwinds. Source, native effect and causal-order
review findings are resolved. Exact fixtures, profiles, original limited-proof
rows, commands and manifests are retained in the
[routing checkpoint](../benchmarks/results/webtransport_app_routing_v1/2026_11_16/README.md).

This evidence changes no production source, dependency pin or activation
policy. Early associations, typed children, multi-session accounting,
independent-client acceptance and fork publication/pins remain open.

Early-datagram implementation checkpoint, 2026-11-16: the candidate now copies
unassociated datagrams into startup-owned global storage, bounded to four
entries per engine connection and four per connection generation. FIFO replay
begins after authorization, establishment and request-header release. Expiry
uses supplied real monotonic awake time with a one-second lifetime; direct
established dispatch adds no clock read. Local ordinals are assigned at
dispatch attempts, including ring-full drops.

HTTP, refused, cancelled and closed identities purge their exact pending key.
Terminal identities never evict while their connection generation lives;
terminal-budget exhaustion disables further unknown buffering only for that
generation, while preserving previously queued future-session entries.
Connection closure clears both tables before reuse. Cooldown cancels pending
traffic, and replay revalidates connection/session state after every callback.
The [early-datagram checkpoint](../benchmarks/results/webtransport_early_datagrams_v1/2026_11_16/README.md)
retains reproduction inputs and validation: 1009 centralized tests, 16 pure
queue cases in all three modes, and 33 native Zig tests (32 functional plus
one import anchor) in Debug, ReleaseSafe and ReleaseFast. Independent reviews
have no required findings. This implements datagram early
association only; child-stream association and multi-session accounting remain
open, together with independent-client and publication gates.

Child receive-accounting foundation, 2026-11-16: a pure per-child ledger now
accounts payload reads and native final size without charging the association
prefix or the same final gap twice. Typed receive snapshots preserve unknown
sizes and separate RESET knowledge/visibility, STOP, FIN and read cancellation.
EOF requires an actual read returning zero; only native close or connection
destruction ends observation. Invalid transitions preserve state.

The [child-ledger checkpoint](../benchmarks/results/webtransport_child_ledger_v1/2026_11_16/README.md)
retains twelve pure cases in all three modes, real native TLS snapshot proofs,
1022 centralized functional tests, release builds and independent reviews.
Engine/App child behavior and production pins are unchanged. Attaching ledgers
to generation-checked child sidecars, bounded early-child association, an
explicit byte consumer, public child I/O and session flow accounting remain
required; this foundation does not complete step 6 or v2.3.0.

Coded receive-cancellation prerequisite, 2026-11-16: bounded early-child
rejection requires an exact STOP_SENDING error on incoming UNI, which the
earlier native API could not express. The new unpublished proposal adds that
operation, retains queued-STOP/final-size ownership, preserves local writes
and legacy shutdown, and carries full-width errors through wire and logging.
The [coded-STOP checkpoint](../benchmarks/results/webtransport_coded_stop_v1/2026_11_16/README.md)
retains the native commit, strong-wrapper 15-case three-mode proof, native C
regressions, event-log RED/GREEN, Root 1023-test verification and reviews.
Root pins and child callbacks remain unchanged. The refreshed CLI viewer
permission on the maintained fork is READ; publication/pin integration and the child runtime
work in step 6 remain required.

Private incoming-child checkpoint, 2026-11-16: the candidate now associates
peer UNI/BIDI children with a generation-checked authorized parent and an
optional private receive consumer. An inline pure lifecycle retains consumer
ownership through native close; the native I/O boundary delivers borrowed
payload chunks and keeps RESET, STOP, final size and actual read EOF separate.
The shared stream pool bounds classified waiting children globally, with four
per connection and a real one-second expiry. Session retirement, shutdown and
callback reentry cancel exact identities while retaining native close leases.
Typed capacity rejection uses the new coded STOP operation; refusal before
positive classification retains the existing generic stream-pool behavior.

The first actual App/TLS/UDP case proves authorized CONNECT0, incoming UNI
binary bytes with its association prefix excluded, full owner identities,
one EOF/close notification, guarded process reentry and healthy ordinary HTTP
on the same connection in Debug, ReleaseSafe and ReleaseFast. The unchanged
33-case App admission/datagram cohort also passes Debug. All 1035 centralized
functional tests pass; eleven
pure child-lifecycle cases pass in all three optimization modes. The
[incoming-child checkpoint](../benchmarks/results/webtransport_app_children_v1/2026_11_16/README.md)
retains exact sources, original failures, commands, results and independent
source/structural reviews. Actual-App BIDI, queue expiry/exhaustion, reset/STOP
ordering, parent teardown and shutdown coverage remain required before this
runtime slice is accepted. Public child I/O, application TX, multi-session
flow accounting, independent-client acceptance and fork publication/pins
remain open. Production activation is unchanged; v2.3.0 remains incomplete.

Incoming-child lifecycle checkpoint, 2026-11-16: nine real App/TLS/UDP cases
now pass in Debug, ReleaseSafe and ReleaseFast, with all 33 existing App cases
also green in each mode. Actual preauthorization byte previews and waiting
reservations/deadlines strengthen the early-arrival and expiry proofs. Capacity
tests exposed the native constructor's metadata publication gap; Root defers
full-pool peer UNI refusal to the typed callback without taking a slot. A
prefix-only FIN regression now proves terminal orphan cleanup on the live
connection. Parent Close0 plus FIN preserves a sibling connection and pending
SID4; subsequent CONNECT4 admits the retained bytes. Abort/reuse preserves an
unknown final size and records connection closure before session teardown.

The same unchanged initial-credit test exposed a native half-window deadlock
with persistent streams. Local proposal
`005ab244169f269689e511d6b77dd2187e318df1` schedules WT-enabled HTTP UNI credit
on close through the existing coalesced flag and bounded generator. All 65
native WT scenarios and 83 upstream Debug cases pass; the Root 1035-test suite
and release builds pass. The
[lifecycle evidence](../benchmarks/results/webtransport_child_lifecycle_v1/2026_11_16/README.md)
retains complete proposal source/history, causal RED/GREEN results and clear
changed-work reviews. Callback shutdown, broader child RESET/STOP ordering,
public I/O/TX, flow accounting, independent-client and publication gates remain
required. Close-before-parent-FIN child cancellation is not established by
this new teardown case. Pins and activation remain unchanged.

Incoming-child callback/reset checkpoint, 2026-11-16: all 17 actual App cases
now pass in Debug, ReleaseSafe and ReleaseFast. Fully buffered multi-chunk
tests exposed reads after a callback aborted its native connection; the
existing guard now checks native status. Visible resets exposed an unfinished
application receive half; terminal STOP cleanup now completes it. A waiting
child also rechecks cancellation before association, suppressing a late open
after visible reset while preserving hidden reliable-reset admission.

The cohort proves open/data cooldown ownership, post-abort suppression,
declined-open/data semantics, and full final accounting despite partial
delivery. Parent Close cancellation is now observed before client FIN.
Independent full-width BIDI STOP/RESET, reliable-data-before-reset ordering,
final-gap charging and visible-reset/future-session isolation pass against
unchanged native proposals. The
[callback/reset evidence](../benchmarks/results/webtransport_child_callbacks_v1/2026_11_16/README.md)
retains original failures, exact sources, commands and clear reviews. Root
1035 functional tests and release builds pass; the existing 33-case App cohort
passes Debug. Public child I/O/TX, multi-session flow accounting,
independent-client acceptance and publication remain full-goal requirements.
Production pins and activation are unchanged; v2.3.0 remains incomplete.

Develop the runtime against the real native proposal in an isolated Zig
verification scaffold while production continues to reject unsupported CONNECT
on its published pin. Compile the same project sources against both backends;
do not replace native callbacks with a simulated backend, change production
dependency views, or introduce a vendor overlay for local verification.

1. Add a private native-contract check in `src/quic/webtransport/backend.zig`.
   Name the required optional entry points and statuses; retain unsupported
   behavior when any required contract is absent.
2. Give `engine.zig` bounded generation-checked connection slots and explicit
   stream contexts for unresolved, HTTP, CONNECT and child roles. A native
   `PENDING` result does not guarantee a later child notification. Keep runtime
   ownership in `webtransport/runtime.zig`, with native I/O in engine callbacks.
   Retain closed connection storage until its stream callbacks release it.
3. Bind named admission, datagram-delivery and connection-clear callbacks from
   App after transport storage reaches its stable address. Store registered
   route identity instead of borrowing released request-header path bytes.
4. Admit CONNECT at completed headers through explicit application authorization
   and Origin policy, before ordinary EOF dispatch. Generic CORS continuation
   is not authorization. Reserve a session, mark the native CONNECT, send a
   nonterminal 2xx and establish it; unwind failed admission. Decode capsules
   incrementally with bounded carry and incremental unknown-payload skipping.
5. Resolve native datagrams within a live connection/session generation and
   dispatch through the existing App ring. Define a local receive ordinal;
   HTTP Datagram input contains no application sequence field. Drain or expire
   pending associations by session using supplied time, with bounded storage.
6. Associate typed children using full-width IDs and directional prefix sizes.
   Propagate reset, STOP and final-size closure once, retaining their contexts
   through delayed final-size callbacks. Closing CONNECT terminates only its
   session's children and pending traffic. Keep unsupported public child I/O
   explicit; this work adds no public stream API.

Keep storage linear in the configured connection/stream budgets. Do not embed
a full-capacity session or pending slab in every connection. A first live
single-session slice can advertise zero session-flow-control intent; complete
bilateral reservation and data accounting before advertising positive limits
or accepting multiple sessions. The multi-session requirement remains open.

Verify repeated session ID zero on two connections, slot reuse, stable startup
bindings, denied Origin/authentication, fragmented capsules, pending expiry,
ring exhaustion, child reset/STOP ordering and healthy HTTP siblings. Retain
exact project/proposal inputs and original commands for the real native
Debug/ReleaseSafe/ReleaseFast cohort. Independent draft-16 client acceptance
and publication remain separate activation gates. Smoke/security verification
remains deferred by the user.

## Paused checkpoint, 2026-11-12

The user paused implementation and requested a commit. The unpublished
reliable-reset proposal, native scaffold, external client sources and
functional evidence are preserved in the
[checkpoint artifact](../benchmarks/results/lsquic_reliable_reset_checkpoint_v1/2026_11_12/README.md).
Its handoff records pending functional checks and receive advertisement.
The full v2.3.0 objective remains unfinished and paused.

## Resumed functional prerequisites, 2026-11-13

Implementation resumed after the checkpoint. The reliable-reset proposal is
frozen at `3640992bb231d3f0f2647e03fda6a2776fcc23ca`; its
[functional evidence](../benchmarks/results/lsquic_reliable_reset_prerequisite_v1/2026_11_13/README.md)
records all 83 upstream Debug cases, ten ReleaseSafe regressions, both-role
ACK batching and shrink recovery, native pinned quic-go interoperability and
Windows/macOS production-library compilation. The final commit changes only
tests. Native stream storage grows by 40 bytes; packet/frame storage and the
settings layout remain unchanged. Independent review found no actionable
issues. Remaining smoke/security runs are deferred by the user.

The next isolated fork starts from that exact proposal. Add a named default-off
draft-16 configuration and SETTINGS-completion callback, then generation,
validated peer snapshots and quiescent notification. The legacy macro path
emits obsolete settings and must remain disabled. Start with a compile RED
for the missing public declarations, add declaration/default plumbing only,
then require a real encrypted-engine wire RED before implementing generation.
Verify disabled, enabled flow-off and enabled flow-on wire settings.

Keep CONNECT admission and session policy in Zig. Classify children only at
their initial association prefix, retain full 62-bit session IDs and actual
encoded prefix lengths, and preserve that prefix floor across WT child resets
and STOP_SENDING. Generic QUIC reset behavior stays independent of WT policy.
Root pins and capability bits remain unchanged until maintained-fork review
and publication. The full v2.3.0 objective remains active and incomplete.

## Public WebTransport child streams, 2026-11-16

The verified private receive consumer is the foundation for three increments:

1. Add `webtransport_streams[_context]` registration, receive callbacks,
   App-affine stream/session handles, cancellation, explicit send finish,
   session notifications, and startup without datagram buffers.
2. Add peer-BIDI writes, accepted-prefix ownership, independent receive/send
   halves, one-shot writable notifications, and transport wake scheduling.
3. Add immediate outgoing UNI/BIDI creation, constructor reservation rollback,
   prefix exclusion, and explicit retry after stream-credit exhaustion.

One immutable sixteen-path endpoint registry combines independent datagram and
stream capabilities. An existing path can gain the other capability even when
the table is full; duplicate capability registration is failure-atomic. Keep
the standalone exported datagram router compatible. CONNECT authorization and
the Origin decision remain explicit synchronous application handlers.

Stream handles carry the stable App address, global stream slot, and a
never-wrapping generation. Session handles also carry the connection and
session generations. Resolution is constant-time and revalidates native and
parent ownership. Handles belong to their originating App lifetime and worker.
Callbacks borrow payload bytes for one call; contexts outlive native closure.

`open` only decides admission. Operations return `NotReady` until acceptance;
accepted children own one eventual `closed` callback, including callback-time
shutdown. Rejected children own no close callback. Public receive EOF/reset
does not finish BIDI sending. Applications explicitly finish or cancel; the
private receive-only consumer retains its established automatic empty FIN.
Closed dispatch uses captured endpoint identity after parent invalidation.

Child-only startup allocates bounded retired-session identities but no pending
datagram entries or payloads. Published backend pins and capability limits stay
unchanged. Public operations return `Unsupported` with the published backend.
No allocation claim covers upstream native stream buffering without evidence.

Acceptance crosses public App methods: child-only startup, endpoint isolation,
wrong-App and stale handles, generation reuse/exhaustion, independent halves,
session/child close exactly once, and callback-time cancellation/shutdown. The
existing seventeen native receive cases remain regression coverage. Later
increments additionally prove BIDI echo/backpressure and outgoing credit
recovery. Multi-session flow control, independent draft-16 client acceptance,
maintained-fork publication and the remaining release gates stay open.

## Public WebTransport peer-BIDI transmission, 2026-11-17

Add `webtransport_stream_write(handle, bytes)` and
`webtransport_stream_want_writable(handle, enabled)`, plus an optional named
one-shot writable callback. Keep caller payload storage borrowed only during
the write call. A positive count transfers exactly that prefix; the caller
retains its suffix. A nonempty zero-progress call returns `WouldBlock`.
Partial/blocked writes arm one opportunity when a callback is configured;
otherwise the caller retries explicitly. Enabling interest without a handler
returns `NoWritableCallback`. Empty valid writes return zero without waking.

An inline `TransmitState` records typed native publication, FIN intent,
writable interest and total accepted payload bytes. Native metadata alone is
insufficient for raw sending: activate I/O only at the typed callback. Interest
may be recorded during admission, but notification waits for acceptance and
publication. Peer STOP disables TX; receive EOF/reset leaves TX usable. Finish
retains accepted native bytes and FIN without claiming peer delivery.

Use synchronous native `writef` with a bounded stack reader. Native buffering
can consume input and then fail, so track reader consumption independently of
the native return value. Positive consumption must still return its count;
queue a terminal internal stream failure separately. The pure ownership oracle
must cover failure after consumption, alongside real native partial writes.
Bound accepted bytes by the QUIC offset limit and add no Root payload queue.

Reserve deferred service after complete handle/readiness/STOP validation and
before native mutation. A named binding wake callback can return `WakeFailed`
without consuming input. During an active native callback, the current pass
owns service. The UDP transport coalesces external requests through its existing
deadline timer: flush queued timer submission, cancel, wait for target and
cancel acknowledgment to retire, then rearm at zero. Keep processing guarded
across both packet and timer entry points; never process the engine inline or
create a zero-delay self-wake loop. Shutdown drains the same completion pair.

Verify binary echo, real stream and connection credit exhaustion/recovery,
accepted-prefix copying and suffix-only retry, one-shot rearm/no-spin, TX after
RX EOF/reset, RX after STOP, handle rejection, callback reentry and a loop-only
wake test without manually calling the engine. Retain the RX26 regression.
Local stop/reset commands and outgoing construction are subsequent increments;
multi-session flow and publication remain required for full activation.

## WebTransport session ownership and flow control, 2026-11-17

The complete target remains positive session flow control and multiple sessions
on one connection, followed by independent-client acceptance and publication.
Keep flow advertisement disabled until receive high-water, early associations,
stream/data accounting and credit output are all enforced.

1. Replace connection-owned session scalars with CONNECT-owned records and one
   startup-sized worker index from connection generation/full session ID to
   global stream slot/generation. Retain the flow-off one-session gate. Child
   parent validation uses direct slot/generation checks; association and datagram
   lookup use the index. Close invalidates records and mappings before callbacks.
2. Extend a separate append-only native candidate with receive high-water and
   quiescent, deduplicated prefix-excluded deltas, independent of readability.
   Charge before typed/read application callbacks, including NULL Root contexts,
   out-of-order data, hidden resets and canceled reads. Preserve Native005.
3. Add per-session monotonic stream/data budgets and bounded capsule output.
   Resolve accounting for early and globally rejected children before enabling
   positive limits. Enforce limits before payload delivery and preserve final
   reset gaps; never wait for blocked capsules to replenish consumed credit.
   Gate peer admission until stream/debit accounting is established, including
   metadata available before typed publication. Oversized stream grants and
   non-increasing limits are session flow errors, distinct from malformed
   capsule framing.
4. Enable multiple sessions only with negotiated positive flow, retaining O(N)
   storage, distinct routes, independent lifecycle callbacks and scoped cleanup.
5. Verify the combined native/client path, publish reviewed fork changes and
   run the remaining release gates. User-deferred smoke/security campaigns stay
   separate from ordinary functional verification.

The ownership increment must preserve all existing 67 native cases while
adapting private observation helpers to the new records. Add index failure,
namespace, generation and allocation-bound tests, plus actual lifecycle
regressions. Run formatting, conventions, version, functional unit, ReleaseSafe
compile, ReleaseFast library and downstream-consumer checks, then commit/push.

The pure flow prerequisite keeps cumulative usage separate from advertised and
desired limits. Native's deduplicated body delta is the only receive debit;
reads and final gaps must not charge it again. Consumption and peer-child
closure replenish desired credit without reducing lifetime usage or waiting for
BLOCKED capsules. One 13-byte output buffer retains an immutable partial capsule
and commits advertised credit only after full native acceptance. Round-robin
selection prevents repeated DATA grants from starving BIDI/UNI grants. This
module remains independent of I/O until early-debt retention and callback
admission gates are wired into Root.

The early-debt increment retains both used and reclaimed totals in fixed
per-connection SID buckets, independent of child and pending-datagram lifetime.
Native supplies body deltas before typed callbacks; typed publication charges
peer-created stream counts once. App child admission waits for publication.
Reads reclaim delivered bytes, and native final-known close reclaims the
remaining body and closed peer-child count, including NULL Root contexts.
The append-only publication snapshot bit is queried at close, when ordinary
typed notification has completed; connection teardown is abandonment instead.
Full-pool BIDI classification uses a zero-consumption probe rather than erasing
an unknown SID. CONNECT refuses retired identities before application admission.
The positive-flow increment imports and enforces retained debt before CONNECT
authorization, clamps sends to the peer's budget and charges only accepted
bytes/successful native child creation. DATA0 masks user writable interest while
retaining it for MAX_DATA recovery; native control progress is independent.
Receive reclamation queues bounded, fair CONNECT credit output, retaining partial
capsules until full native acceptance. Startup config defaults to zero and
requires the complete receive observer for positive advertisement. Bilateral
intent enables flow; unilateral intent preserves legacy ignore behavior.
The multiplexing increment below adds scoped cleanup and verifies isolation.

## WebTransport multiplexed-session isolation, 2026-11-17

Use the existing CONNECT-owned record and worker index; no additional session
manager or native API is required. Enable a simultaneous second session only
when both endpoints negotiate positive flow. Preserve the connection-wide
datagram FIFO, local delivery ordinal, drop counter and application metrics;
session flow budgets, credit output, routes and lifecycle remain independent.

1. Add stable in-place `DatagramRing.clear_session(id)` with caller storage,
   FIFO preservation and unchanged drop accounting. Verify mixed sessions,
   binary/empty payloads, capacity recovery, non-power-of-two rebasing and
   power-of-two cursor rollover independently in all optimization modes.
2. Give the existing required Binding cleanup callback a named `ClearScope`
   union for a whole connection or exact session ID. Session retirement selects
   one SID; connection destruction retains full cleanup. Wire App cleanup before
   relaxing Root admission. The ring worker owns ring/tests; Root serializes
   binding, App and engine edits.
3. Compute bilateral flow negotiation before the existing second-session guard.
   Preserve early-debt validation before application authorization, bounded
   stream/index reservation, generation checks and rollback. No allocation is
   added to admission, delivery or cleanup. No published dependency pin changes.
4. Verify multiple distinct SIDs/routes on the same actual native connection,
   interleaved peer/local children and datagrams, independent data/stream grants,
   early-child debt and partial credit output, scoped Close/reset/EOF/error,
   drain, callback cooldown, full connection destruction and generation reuse.
   Legacy and unilateral offers must still reject the second CONNECT before
   application admission. Retain the prior flow18, stream/debt77 and datagram33
   regressions; these drivers share helpers and are not disjoint case counts.

Existing drain policy stays explicit: children and datagrams continue, while
new local child creation on that draining session returns `SessionClosed`.
The worker stream capacity and ordinary QUIC stream limits bound CONNECT count;
draft-16 introduces no MAX_SESSIONS setting. Final acceptance requires ordinary
Root gates, native evidence and independent review before commit/push. Dedicated
smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.

The cooldown test has two ownership checkpoints: application session notices,
index entries, children and queues retire first; a fully flushed native CONNECT
can retain its transport lease until real peer FIN. Existing tests previously
used connection abort for that final teardown. Preserve this graceful policy,
prove protocol-driven release after FIN, and separately require connection abort
to drain all ownership without peer cooperation.

## Independent public-App WebTransport acceptance, 2026-11-17

Reuse the unchanged official webtransport-go oracle already pinned above, with
quic-go v0.62.0 and renewed explicitly trusted localhost PKI. The earlier oracle
proved independent transport controls but labeled native mode as admission and
enqueue only. New product claims require exact reconciliation with server-side
public callbacks and datagram-ring observations.

1. Freeze original oracle/provenance, verify dependency source manifests and
   module checksums, parameterize relocation and renew expired fixture PKI.
2. Build a standalone application importing `src/root.zig`, using normal
   `App.run`/shutdown and public routes, child operations and `next_datagram`.
   Reuse candidate source-list overrides only; omit the C client, test-support
   module, SETTINGS observer, manual engine pumping and private window changes.
3. Extend the official client's public APIs for binary peer/local UNI/BIDI,
   FIN/reset payload accounting, actual datagram delivery, finite DATA/stream
   credit recovery, independent sessions and duplicate SID-zero namespaces.
   Use bounded control/report barriers, exact payloads and finite deadlines.
4. Reconcile both sides, retain original failed trials and raw results, run the
   three candidate server optimization profiles, and independently review and
   replay the resulting evidence before commit/push.

The server/client workers own separate scratch directories and agree the
bounded HTTP control/report contract before implementation. Session route
contexts identify fixed source/ordinal labels. Same-connection HTTP health and
reports use the official client's existing owned `ClientConn.RoundTrip`.
Datagram callback success alone is insufficient: compare exact callback/ring
sets without assuming network order. Outbound datagram echo is not claimed.

For positive-credit tests, hold independent-client reads of server output,
observe partial acceptance/`WouldBlock`, then read and require real credit-driven
writable recovery and suffix-only completion. With stream credit one, reject
the next create without queuing it and explicitly retry after actual closure.
The official client marks association headers reliable but exposes no arbitrary
application-prefix boundary; preserve the separate raw-reset oracle and native
early/fragmented association evidence instead of overstating those guarantees.

Candidate source and published-pin evidence stay separate. No production pin,
capability flag or maintained fork changes in this increment. Independent
acceptance precedes reviewed publication and capability activation; dedicated
smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.

## Maintained-fork publication preparation, 2026-11-17

The independent-client checkpoint is pushed at `50a70a9`. Fresh authenticated
checks still report no push access to either maintained fork. Prepare a durable
maintainer handoff while preserving the tested source and production pins.

1. Record current permissions, mirror/integration refs and the exact evidence
   identities. The lsquic mirror has advanced neither with upstream nor with
   the local proposals; distinguish these two pending ranges explicitly.
2. Preserve the original eighteen-commit lsquic proposal history. Its first
   five commits already contain the required ledger fields. Create a separate
   deterministic publication branch for the following thirteen commits, with
   complete ledger metadata, mapped parents and unchanged source trees/diffs.
   Keep intermediate failing checkpoints labeled historical. Allocate the new
   LSQ-008 through LSQ-020 rows in chronological order.
3. Retain complete original/publication bundles, the unchanged XEV-008 history,
   conversion input and script, all commit mappings and exact tree proofs.
   Import and validate the bundles offline in fresh repositories, reproduce the
   conversion twice, and verify negative base/tree/order cases fail safely.
4. Independently review metadata and source identity, record the newly observed
   upstream range without silently merging it, then commit/push the root
   evidence and durable ledger/handoff references.

Root owns the contract, live provenance, documentation and integration. Build
and vendor owns the scratch conversion/package; QUIC reviews source identity
and the new upstream range. No runtime module boundary changes in this slice.

Acceptance requires exact source identity for all eighteen original/publication
commit pairs, preserved published-base ancestry, complete commit metadata,
identical deterministic replay outputs, valid self-contained bundles and no
changes to dependency pins, capability flags or the user's vendor work.
An authorized maintainer must still synchronize/review the mirror, confirm
branch protection, open an assigned/labeled integration PR and merge it. Pin
updates and normal-build activation require that published result and their
own empty-cache, consumer and independent-client gates.

## Compatible lsquic fixes found during publication review, 2026-11-17

The current upstream range contains two required fixes absent from the frozen
candidate. Preserve that candidate and its metadata conversion; append adapted
fixes in a new scratch history instead of importing unrelated newer sources.

1. LSQ-021 adapts upstream QPACK terminal-state handling. Stop buffered reads
   after BLOCKED/ERROR, reject exhausted blocked prefixes, give terminal errors
   precedence and guard filtering plus the candidate-only reliable-reset header
   completion path. Preserve WT classification and reset-prefix ownership.
   Retain failing-before/passing-after regressions for frame boundaries,
   blocked/error precedence and terminal failure during reset completion.
2. LSQ-022 adapts upstream validated-path preservation. Reuse only eligible
   unvalidated slots; preserve every stored validated path when no victim is
   available. Regressions assert full identity/metadata for occupied slots,
   repeated alternatives and no-victim cases across address/connection modes.
3. Independently review both adapted source/test diffs. Verify the complete
   native assertion suite, retained WT/reset/receive cohorts and the public
   independent-client matrix in all three optimization modes. Record exact
   source identities and proof limits before adding publication equivalents.

The implementation owner edits only the new native/proof scratch directories.
Root owns the public-client rerun and retained artifact; the independent QUIC
reviewer owns source comparison and changed-work review. Each fix has its own
policy-compliant commit and regression evidence. Mirror synchronization and
maintained-fork publication remain separate, and no dedicated campaign is
resumed by these functional regressions.

## PostgreSQL TLS reservation prerequisites, 2026-11-17

Continue the isolated fixed-record-buffer experiment against exact BoringSSL
`d3bf4795ad5b79d646cddf2fec687da5b9b502db`. Preserve its original four-file
candidate, query probe, interposer and retained evidence. This slice does not
change production source, dependency pins or the failed strict allocation gate.

1. Rebuild the complete native SSL library in a new scratch directory. Add a
   separate deterministic fault observer for the first and second reservation
   mallocs after verified idle TLS 1.3 setup. The documented failure contract
   permits a partial receive reservation and requires `SSL_free`; verify actual
   cleansing and one real free for each successfully owned allocation. Keep
   injection accounting distinct from ordinary allocation measurement.
2. Produce pending plaintext, partial encrypted input and a BIO-backpressured
   write through actual TLS operations. Read-only snapshots must show rejection
   before reservation without changing bytes, cursors or ownership. Use valid
   traffic controls; do not stage those states by mutating private SSL fields.
3. Reject null, unfinished TLS, an isolated completed TLS 1.2 negative fixture,
   and publicly configured DTLS/QUIC objects. Do not claim completed DTLS/QUIC
   interoperability or relax production's TLS 1.3 policy.
4. Reserve both peers, clear both SSL objects, verify old reservations are
   cleansed/freed, then complete a fresh verified handshake with fresh BIOs.
   Reserve again and exchange bounded records under short reads/backpressure.
   Repeat the inherited capacity/alignment/compaction and maximum-record proofs.

Root owns the contract, immutable provenance and final integration. The crypto
implementer owns only new scratch native/test copies and a new build cache. An
independent crypto reviewer checks failure ownership, retry-state preservation,
cleansing and claims. A separate source explorer maps other post-handshake
allocation paths without changing or testing them in this prerequisite slice.

Acceptance requires explicit terminal statuses, unchanged original accounting
and self-test, no outstanding tracked reservation ownership after cleanup, real
pending-state rejection and successful verified reuse after `SSL_clear`.
Tickets, KeyUpdate, pending-flight/error/reconnect processing, native maintenance
and production adoption remain separate requirements. SQLite's SQL-ALLOC-001
does not authorize PostgreSQL's proposed SQL-ALLOC-002. Dedicated campaigns
remain user-deferred.

## Quantitative TLS control-traffic witness, 2026-11-17

The exact-pin source map finds allocations beyond the retained record buffers.
Measure those paths in a separate public-API-only fixture without changing the
native candidate, production policy or original all-C allocator interposer.

Use four independently initialized verified TLS 1.3 pairs: ticket-free payload
control, two initially queued tickets with client caching off, peer KeyUpdate
without a response request, and requested KeyUpdate followed by client response
and application data. Repeat the rows independently and retain variation.
Initial queued tickets are not arbitrary later tickets or warmed PostgreSQL
queries; the evidence must preserve that distinction.

Verification owns a new scratch fixture, provenance, operation-level counts and
raw results. Meter each client SSL read/write and immediate error mapping,
including retries, with peer preparation/flush and payload validation outside
the interval. Fixed allocation-free message observations must establish actual
ticket/update delivery and the requested peer response. Crypto review checks
these accounting boundaries independently.

Acceptance requires exact unchanged candidate/archive hashes, the original
63-byte allocator self-test, explicit CA/hostname validation, exact payloads,
terminal statuses and reconciled per-operation/aggregate allocator counters.
This witnesses reachable client-control allocations; it neither supplies
PostgreSQL per-query counts nor closes the production strict-allocation gate.

## Fixed-storage TLS 1.3 HKDF labels, 2026-11-17

Remove the measured label-serialization allocation in a separate native
candidate. The TLS encoding bounds its label and context to 255 bytes each;
the complete encoding therefore fits 514 stack bytes. Keep the existing CBB
serialization and HKDF implementation, using fixed CBB storage and an explicit
flush before borrowing its data. Preserve error, output, length-narrowing and
service-indicator behavior. The original record-retention source stays intact.

1. Verification first records the unchanged baseline's successful-call heap
   allocation. A deterministic differential fixture covers supported digests,
   binary/empty inputs, vector limits, output bounds and rejected-input output
   sentinels. Compare error library/reason codes and independently serialized
   valid labels without changing the original all-C counter or its self-test.
2. Crypto owns the single-function change in a new scratch source copy and a
   complete native archive rebuild. Retain the exact one-file source delta,
   full source inventory, commands and baseline/candidate identities.
3. Verification repeats the identical fixture and all twelve public TLS
   control rows against the changed library. Record actual allocation counts
   and verified payloads; retain replayable evidence with safe output paths.
4. Independent crypto review checks bounds, flushing, compatibility and
   service-indicator control flow. Root checks final evidence and ordinary
   project gates, then commits and pushes the increment.

This addresses one allocation site. Ticket/session, AEAD, response-flight and
error storage remain separate work. SQL-ALLOC-002 stays open; no production
pin, maintained fork or FIPS validation claim changes. Dedicated smoke and
security campaigns remain user-deferred.

## Bounded client post-handshake storage, 2026-11-17

Continue from the reviewed HKDF candidate. Add an explicit native
`SSL_reserve_client_post_handshake_buffer` opt-in without changing record-buffer
reservation. Only completed, idle, ordinary TLS 1.3 clients are eligible.
Allocate temporary descriptor/data storage and commit only after success;
failure preserves prior ownership and configuration.

Capture `M = max(16384, max_cert_list)` and reserve `M + 3 + 16384` logical
bytes. Before an accepted record the current head is incomplete, occupying at
most `M + 3` bytes; a whole record can add 16384 bytes before consumption.
The default logical bound is 118787 bytes; BUF_MEM rounds data capacity to
158384 bytes. Descriptor, allocator and state overhead are measured separately.
While opted in, `SSL_set_max_cert_list` clamps increases to the captured ceiling;
lowering and re-raising within it work, and the getter exposes the setting.
Context setters and unreserved connections retain their existing behavior.

1. Verification first records genuine unchanged-candidate allocation RED for
   repeated fragmented/coalesced handshake input, with the original all-C
   counter and self-test. Keep direct helper and encrypted peer proofs distinct.
2. Crypto owns four native files in a new scratch copy: the public header,
   internal state, SSL lifecycle/setter and handshake buffering. Preserve
   parsing, callbacks and ordering; retain empty storage, cleanse vacated tails
   and reject capacity overflow before mutation or allocation. SSL_clear frees
   the reservation and removes its configuration restriction.
3. Separate verification owners cover buffer/lifecycle/fault behavior and real
   encrypted fragmentation/coalescing, then compare baseline and candidate
   protocol outcomes and all twelve control rows. Include startup memory,
   pending-state rejection, first/second allocation failure, actual cleansing
   and free, setter/context independence and verified clear/re-handshake reuse.
4. Rebuild complete native libraries, retain exact source inventories and
   replayable proofs, and obtain independent crypto review of bounds, every
   append/reset site and the explicit setter contract. Root integrates the
   evidence, runs ordinary project checks, commits and pushes the checkpoint.

AEAD, ticket/session, outgoing-flight and error/reconnect allocations remain
separate work. Production pins, PostgreSQL's strict allocation requirement and
the user's campaign deferrals remain unchanged.

## Recycled client KeyUpdate contexts, 2026-11-17

Remove the remaining AEAD-object allocation from established client KeyUpdate.
Add an explicit experimental startup reservation for one inactive spare; keep
the bounded set at active RX, active TX and one spare. Allocation failure leaves
the mode disabled and existing ownership intact. Repeated idle reservation
allocates nothing; SSL_clear frees the spare and resets the mode.

Prepare the inactive object with existing cipher/HKDF/AEAD primitives. Cleanup
alone does not erase inline state: explicitly cleanse old key/IV storage and
reset nonce/AAD/direction flags, including the AES nonce tracker. Preserve the
existing read excess-data guard and write old-key plaintext sealing before any
swap. Commit traffic secrets only after installation succeeds. Recycle and
cleanse the replaced active object on success; recover and cleanse the candidate
on failure without freeing its reserved allocation. No heap fallback is allowed.

Callbacks can observe the borrowed spare during installation. The opt-in requires
serialized, non-reentrant mutating SSL I/O; observation callbacks remain usable.
An unavailable or inconsistent spare fails closed. Keep generic/unsupported
paths unchanged and cleanse touched local key/IV/derived-secret copies on every
success and error return.

1. Wire verification records genuine baseline allocation RED before native
   changes. Negotiate each of AES-128-GCM, AES-256-GCM and ChaCha20-Poly1305
   through this pin's public TLS 1.3 cipher API, asserting the actual suite.
2. Crypto owns six native files in a fresh source copy: public/internal headers,
   SSL startup, AEAD preparation and TLS 1.3 traffic-key/install hooks. Rebuild
   complete native archives and retain exact source/build provenance.
3. Separate verification covers reused/fresh crypto equivalence, invalid and
   populated-candidate failure paths, read/write hook failure ownership, nonce
   reset, startup/final ownership and verified clear/re-handshake reuse. Actual
   peer tests cover repeated/alternating updates, old-key response ordering,
   backpressure/retries and observation callbacks. Keep fault injection distinct
   from unchanged ordinary allocation accounting.
4. Repeat inherited record, incoming-handshake-buffer, HKDF and public control
   checks against the final archives. Independently review return-path ownership,
   ordering, compatibility and final evidence; Root validates restoration/replay,
   runs ordinary project checks, commits and pushes.

Ticket/session, response-flight and error/reconnect storage remain separate work.
Production pins and PostgreSQL's strict allocation requirement remain unchanged;
dedicated smoke/security/sanitizer/fuzz/scan campaigns stay user-deferred.

## Bounded outgoing KeyUpdate storage, 2026-11-17

Remove requested-response construction/flight allocations with a separate
`SSL_reserve_key_update_output_buffers` experiment. Require a completed, idle,
ordinary TLS 1.3 client and the existing serialized, non-reentrant I/O contract.
Allocate two temporary BUF_MEM objects/data completely before committing either;
failure preserves prior owners/configuration. Repeated idle calls allocate
nothing, and SSL_clear destroys storage and disables the mode.

The exact pin has five-byte KeyUpdate plaintext and 22-byte seal overhead,
giving a 27-byte ciphertext bound for the three supported suites. There is no
dynamic client padding path; server padding affects initial handshake data.
Legal max_send_fragment values remain at least 512, so later changes still fit.
Validate the seal bound at startup/use. Keep logical capacities 5/27 distinct
from rounded BUF_MEM data allocations 8/40; measure total startup/state costs.

1. Wire verification retains actual requested-update allocation RED before
   native edits, using public three-suite negotiation, exact payload/response
   checks and the unchanged all-C counter/self-test. The same complete-call
   zero assertion must become GREEN for reads and following writes.
2. Crypto owns six files in a new native copy: public/internal headers, SSL
   startup, KeyUpdate construction and the two TLS buffer implementations.
   Encode into fixed five-byte CBB storage and synchronously copy borrowed data
   before its message callback. Preserve the owned generic entry and all other
   profiles; no stack buffer becomes Array-owned storage.
3. Retain plaintext storage after temporarily borrowing its owner for sealing;
   cleanse/reset/restore it on success and failure, preserving consumed-plaintext
   failure effects. Retain ciphertext storage after staging/direct flushing,
   reset length and offset together and cleanse only transferred bytes. Guard
   bounds/arithmetic before mutation/sealing, and reject partial-flight append.
4. Verify empty-versus-absent handling at every check. Preserve old write-buffer
   priority, old-key sealing before AEAD installation, pending-write retry
   ownership, coalescing and uncork-on-staging. The single-flight bound follows
   from pending-update coalescing until ciphertext moves to the bounded writer.
5. Separate direct/fault/lifecycle and encrypted-peer owners verify exact bounds,
   four startup failure points, real cleanup/free, repeated reservations, clear/
   re-handshake, requested/local/coalesced/alternating updates, zero-length
   flushes, backpressure, older partial app records and accepted/rejected retries.
   Repeat inherited record/HS/HKDF/AEAD and public controls on final archives.
6. Independent review checks every reset/offset, borrowed lifetime and failure
   return. Root validates source restoration and complete delivery replays,
   packages debug-stripped copies with preserved measured identities/ELF proof,
   runs ordinary project gates, commits and pushes.

The [retained result](../benchmarks/results/sql_tls_ku_output_v1/2026_11_17/README.md)
now records zero heap operations across 24 requested updates/600 client calls
and fifteen healthy protocol rows. The full 24-row protocol matrix preserves
ordering, retry and raw error semantics. Four startup allocations total 128
requested bytes; SSL3_STATE grows 632 to 640 bytes. All 23 lifecycle cases,
inherited record/HS/HKDF/AEAD proofs and full native rebuild pass. Both source
restore modes reproduce all 8709 entries, and the final delivery replays pass
78 helper and 15 wire commands with original measured identities preserved.

Ticket/session and error/reconnect allocations, native maintenance and production
adoption remain open. No PostgreSQL exception or strict-gate closure is implied;
dedicated smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.

## Validated client ticket discard, 2026-11-17

Remove unused TLS 1.3 ticket-session construction from PostgreSQL's future
bounded client profile. Current SQL contexts create fresh verified sessions,
install no new-session callback and never save or reuse a TLS session. Their
native default cache mode is SERVER (2), which disables client caching. Cache
OFF alone does not authorize changing ordinary BoringSSL behavior.

The proposed independent per-SSL API is
`SSL_discard_client_session_tickets`. It enables a one-way ordinary-receiver
policy for the connection state: validate each complete NewSessionTicket,
preserve message observation, then discard its resumption material without
constructing a session. Successful SSL_clear resets it. A failed clear preserves
the flag when it retains the old state; baseline replacement-state allocation
failure destroys that state and its flag. This is not atomic clear rollback.
Require a completed idle ordinary TLS 1.3 client. Initial enable also requires
no CLIENT cache bit and a null new-session callback. The per-SSL policy remains
authoritative if shared context settings later change. It skips ticket-session callbacks, time
rebasing, PSK derivation and synthetic IDs; it does not revoke earlier exported
sessions, change an already resumed handshake or alter established-session
getter ownership. Existing generic callback/resumption behavior remains intact.
Explicit external-record-layer ticket-session construction remains generic and
may allocate; the opt-in governs tickets received through the ordinary reader.

RFC 8446 section 4.6.1 permits earlier deletion under local policy. A reusable
session pool cannot preserve callbacks that retain arbitrarily many sessions;
an explicit discard policy removes work SQL does not use. This is a native
proposal; production activation and the complete PostgreSQL allocation proof
remain separate work.

1. Preserve the current eleven-file candidate and all measurements. Crypto owns
   only ssl.h, internal.h, ssl_lib.cc and tls13_client.cc in a fresh exact source
   copy. Record all 8709 baseline entries and genuine cache-disabled ticket RED
   before native edits. Expected cumulative change count is twelve; inventory
   comparison is authoritative.
2. Share pure borrowed validation stages for prefix, extensions vector/body
   framing and extension semantics. Return named errors and preserve existing
   reason/alert ordering at each effects boundary. Keep generic ordering:
   session duplicate, time rebase, prefix, ticket copy, vector framing,
   timeout/PSK, extension semantics and finalization. The discard branch calls
   the same stages consecutively without session construction or retained spans.
3. Verify valid initial and post-startup tickets across all three actually
   negotiated suites, repeated/fragmented/coalesced delivery and exact payloads.
   The unchanged all-C counter/self-test must show baseline/unreserved RED and
   opt-in zero heap operations over complete client calls. Preserve malformed
   rejection, recognized-duplicate scope and unknown-extension/flag behavior.
4. Verify cache modes OFF/SERVER versus CLIENT/BOTH, callback-present rejection,
   later shared-context changes and sibling isolation, ordinary callback
   retention/ownership, message versus time observation, established-session
   getters, idempotence and the documented preserving/destructive clear paths.
   Invalid-wire tests establish protocol parity rather than a zero-allocation
   fatal-path claim.
5. Rebuild all native SSL/crypto translation units with Zig. Repeat inherited
   buffer/HKDF/AEAD/output controls, obtain independent source/evidence review,
   validate source restoration and final prebuilt replays, retain one evidence
   archive, run ordinary project gates, commit and push verified progress.

Pre-edit RED records three verified pairs, six real initial tickets and 75
complete client calls: each ticket-bearing read counts twelve mallocs/twelve
frees/1600 requested bytes, while following writes count zero. Observe and
strict data match exactly; strict exits one after valid traffic. The four-file
candidate has passed its complete native rebuild and functional verification.

The [retained result](../benchmarks/results/sql_tls_ticket_discard_v1/2026_11_17/README.md)
records 37 direct syntax vectors, six generic callback rows plus twelve policy
rows, three exact OOM-order rows, twenty lifecycle and two watched-clear cases.
All 51 inherited inputs remain unchanged and their final-library checks pass.
Wire proof covers 27 rows/1320 calls, three real-session chains/228 calls and
twelve controls/255 calls across the stated suites and phases. Both source
restore modes reproduce all 8709 entries. Final delivery replays pass 107 helper
and 24 wire commands. Enable/idle repeat allocate nothing and S3 stays 640 bytes.

Fatal-error/reconnect allocation, maintained publication, production adoption
and PostgreSQL's full request-path gate remain open. No PostgreSQL allocation
exception is approved. Dedicated smoke/security/sanitizer/fuzz/scan campaigns
remain user-deferred.

## Reusable TLS fatal-error snapshots, 2026-11-17

The ticket candidate's eighteen fatal protocol rows still allocate: decode
paths count two mallocs and 40 requested bytes; duplicate/flags paths count
four mallocs, two frees and 80 bytes. Source inspection identifies a persistent
read-error snapshot and a separate temporary snapshot around alert output.
Those counts alone do not prove call-site attribution or repeated-error behavior.

Phase A preserves generic diagnostics and reserves only snapshot record storage.
Keep the existing sixteen-byte `ERR_SAVE_STATE` layout and generic allocation
path unchanged. Add an internal, opaque `ERR_RESERVED_STATE` with fifteen error
records, matching the queue's existing maximum, and a used count. Its factory
warms the calling thread's error queue without changing queued errors. Typed
capture and restore operations reuse the fixed record capacity while retaining
the existing arbitrary-length string copy and allocation-failure semantics.
An idempotent repeat adds no thread-warming guarantee: a destination worker
must initialize its own error queue before counted work after serial migration.

The proposed `SSL_reserve_error_state` requires an idle, completed ordinary
TLS 1.3 client and serialized, non-reentrant mutating I/O. Prepare independent
read and alert snapshots before publishing either owner. Reject incompatible
pending/error/shutdown states and make an eligible repeat idempotent. Successful
SSL_clear releases the owners; preflight failure retaining the old S3 preserves
them, while replacement-state allocation failure destroys the old S3 and its
owners. Error-queue data remains independently owned and may outlive SSL_free.

1. Preserve all 8709 entries of the twelve-file ticket candidate. Before native
   edits, retain authentic first-failure and repeated-read/write RED for empty
   and duplicate tickets, bad MAC, invalid record framing and a public peer fatal
   alert. Preserve immediate SSL_get_error, full reason/file/line/data/flag
   results, alert observation, cross-SSL restoration and popped-string lifetime.
2. Change only crypto/err/{err.cc,internal.h}, ssl/{internal.h,ssl_lib.cc,s3_pkt.cc}
   and include/openssl/ssl.h in a fresh candidate. Verify fifteen-entry capture,
   wrap/mark/clear behavior, long diagnostic copying and string-allocation
   failure, two-owner startup rollback, eligibility, sibling isolation and the
   preserving/destructive clear boundaries.
3. Prove metadata-only fatal calls and repeated I/O allocate nothing with the
   earlier reservations. Peer-alert formatting and string copies remain an
   explicit Phase B RED; Phase A does not claim all fatal errors are allocation
   free. Rebuild matching SSL/crypto, verify inherited controls and obtain an
   independent source/evidence review before retaining or activating a candidate.
4. Validate source restoration and delivered replays, record actual startup and
   S3 sizes, run ordinary project gates, then commit and push to
   impl/implement-2.3.0. Dedicated deferred campaigns remain deferred.

Production attribution also remains open. Connection.finish_close destroys the
TLS session before Db.on_closed delivers the failed query's callback. Reconnect
creation and handshake can run while other worker-local requests remain active;
the auxiliary cancellation handshake can overlap its main query. These paths
therefore have no blanket allocation exemption. Native publication, production
adoption and the complete PostgreSQL allocation proof remain separate gates.

The [retained Phase A candidate](../benchmarks/results/sql_tls_error_snapshot_v1/2026_11_17/README.md)
changes six native paths, fourteen cumulatively. Its matching Zig Debug build
passes all six steps. Two 368-byte startup owners eliminate heap operations for
all 29 metadata-only fatal/replay calls in the five-fault witness. The peer-data
and complete fatal gates remain RED; the unreserved per-call counts are exact.
Inherited protocol checks cover 27 rows/1320 calls across three negotiated
suites, all reserved counts zero. Twelve public control rows/255 calls also
count zero with their retained 0x1301 scope.

Seven direct ownership/thread cases, three copy-OOM cases per library, public
startup/guard/clear controls, a real nested other-SSL BIO callback and two cold
thread-initialization failure rows pass. All 51 inherited inputs remain unchanged.
The producer replay passes 86 recorded commands across 21 selected programs.
Root independently restores all 8709 entries from both supported source modes,
including types, permissions, links and hashes; four refusal controls pass.
Independent source/evidence review has no unresolved finding. Final delivered
program replays and archive validation are recorded with the retained result;
this component does not close PostgreSQL's production allocation gate.

## Owned short TLS error data, 2026-11-17

Phase B removes the remaining native peer-alert diagnostic allocations without
limiting diagnostic text. Preserve each error's existing data pointer and add
a 32-byte owned inline buffer; give the thread's popped-data holder independent
inline storage too. Null remains absent, an owning-buffer pointer is inline,
and every other non-null pointer owns a raw-malloc block. Payloads through
31 bytes plus NUL fit; longer data retains complete heap spill.

Centralize inline identity, release, empty-destination copy and popped ownership.
Never shallow-copy a self-pointer. The public setter stages aliases before
replacement and consumes valid input MALLOCED buffers with OPENSSL_free after
the copy attempt. Output STRING|MALLOCED still means queue-owned, non-static
storage, including an empty string. A popped pointer remains independent of SSL
and snapshots until the thread's next queue modification. Data-only replacement
preserves metadata and marks; snapshot copy retains baseline mark/OOM behavior.

Keep generic printf/concatenation generation and raw-buffer adoption unchanged,
including short buffers. Replace only the bounded peer-fatal formatter with a
21-byte stack buffer, checked snprintf and the copy-taking setter. Preserve
reason, text, flags, callback order, no response alert and existing read/write
results. A fatal-level description zero is a labeled native-sealed invalid-input
case; warning-level close-notify zero remains a separate public control.

1. Preserve the exact 8709-entry, fourteen-path snapshot candidate. Before edits,
   retain the twelve-row direct ownership/boundary RED and five-row/164-call
   alert RED with the unchanged all-C counter and 63-byte self-test. Actual
   first fatal0/99/255 reads count two mallocs and 83/84/85 requested bytes.
2. Change crypto/err/err.cc and ssl/tls_record.cc only, plus narrowly necessary
   comment corrections in crypto/err/internal.h and include/openssl/ssl.h.
   Rebuild all native SSL/crypto translation units through Zig. No public
   signature, reservation eligibility or production dependency pin changes.
3. Verify absence/empty, lengths1/30/31/32, nonuniform long text and aliased
   whole/suffix replacement, peek/pop variants, full FIFO/wrap/marks, mixed
   captures and shrink cleanup. Exercise long-copy OOM, input allocator
   provenance, armed-fault short operations and thread destruction. Clearing
   old heap data or consuming MALLOCED input can legitimately free it.
4. Run the alert witness across three actually negotiated suites and inherited
   five-fault/protocol/healthy controls. Reserved native complete calls must be
   zero. Generic formatting, long spill, unreserved snapshots and cold-thread
   initialization remain honest allocating controls. Record new sizes/counts:
   private record growth makes old generic array-byte equality invalid.
5. Independently review ownership and maintainability, restore both source modes
   including permissions, replay final delivered programs and retain one bound
   archive. Run ordinary project gates, commit and push impl/implement-2.3.0.

The new data representation does not exempt teardown, cancellation or reconnect
from PostgreSQL's request-path allocation rule. Production integration, native
publication and the full PostgreSQL gate remain open; dedicated smoke/security/
sanitizer/fuzz/scan campaigns remain user-deferred.

The [retained short-error-data result](../benchmarks/results/sql_tls_error_data_v1/2026_11_17/README.md)
passes the matching six-step native build and all 38 SSL translation units.
The unchanged twelve-row direct fixture becomes GREEN for short copies while
long spill, generic formatters and required input frees remain positive controls.
Twenty-one expanded ownership/OOM/destructor cases pass. Actual host sizes are
56 bytes per entry, 944 per thread state and 848 per snapshot; SSL state stays
656 bytes. Three inherited fixture files change only four proven size values;
all 51 older inputs plus their driver remain unchanged.

All 164 alert-witness calls count zero for each of three negotiated suites;
unreserved controls remain RED with their actual new byte counts. Inherited
163-call faults, 27-row/1320-call protocol checks and 12-row/255-call public
controls also count zero. Independent ownership and strict maintainability
review reports no unresolved finding. Root restores all 8709 files exactly from
both source modes and verifies four refusal controls. Final staged programs
match every expected status in 91 native and 22 wire replay commands, including
eighteen wire program runs. Whole-query lifecycle, publication and production
integration remain separate obligations.

## PostgreSQL lifecycle ownership, 2026-11-18

The [prepared SQL SDK](../benchmarks/results/sql_tls_preparation_v1/2026_11_17/README.md)
waits for verified, drained TLS before reserving storage and sending startup or
cancellation traffic. All 1189 ordinary live tests pass. The unchanged all-C
counter measures zero operations across 256 warmed queries, while six complete
worker-wide failure/reconnect/cancel intervals remain strictly RED. Other active
queries and queued waiters retain their original behavior and deadlines.

The [paired lifecycle inventory](../benchmarks/results/sql_tls_lifecycle_inventory_v1/2026_11_18/README.md)
records raw stacks and pointer lifetimes without replacing allocator bodies or
changing intervals. Fresh control/trace vectors match: each failure round counts
268 mallocs, two callocs and 270 frees; each cancellation round counts twice that.
The trace covers the installed worker, not every native thread or unexecuted
path, and its application-inclusive live-byte peak is not a domain size bound.

The [explicit native memory/CBB leaf](../benchmarks/results/sql_tls_domain_v1/2026_11_18/README.md)
adds borrowed immutable domain descriptors, private block provenance and complete
owned-CBB scratch handling. Thirteen measured owned/negative/fixed cases count
zero C heap calls after explicit ERR initialization. The complete prepared SDK
retains 1189 passing live tests and both release-mode builds. All 8709 source
entries/modes and the exact five changed paths are retained with successful
restoration, rebuilt proof and independent review. This prerequisite supplies no
total TLS allocator policy or proven capacity.

Next implement explicit ownership through actual SSL construction, BIO and
handshake state using the recorded allocation sites. Keep destination ownership
explicit, preserve ordinary native behavior, and verify OOM/cleanup/reuse through
the same public interfaces before comparing the original lifecycle counter.
Certificate parsing/verification, algorithm workspaces, shared trust caches,
ERR/thread facilities and final-reference lifetimes require separate explicit
ownership accounting. Do not hide them behind a current-owner switch, a finite
spare-SSL stock, admission pauses, delayed callbacks or maintenance intervals.
No PostgreSQL allocation exception, new publication destination or production
pin adoption is approved. The full gate and the other roadmap requirements stay
open; user-deferred campaigns retain their existing configuration and thresholds.

## Complete owned BIO pairs, 2026-11-18

The next allocation closure is implemented and verified in the isolated native
and prepared SDK: two Bio objects, two pair states and two rings share an
explicit domain. A pure checked native requirements query supplies bytes and
alignment; no private header or object size is copied into Zig. Four native
paths change against the complete memory/CBB parent, with no file/mode drift.
All 8709 source entries and matching headers/library provenance are retained.

Each of the N normal and N cancellation connection objects gets startup-owned
storage and a stable descriptor outside Session. Cursor reuse waits for final
raw release, including extra references and dormant preconstructed cancellation
sessions. Shutdown releases both Session arrays before backing/context storage.
The structural bound is 2N queried pair slabs plus metadata, independent of
reconnect count; this is not a total TLS capacity proof.

Native ReleaseSafe proof passes 38/38 steps. Nine new public-interface rows count
zero C heap operations, including cold sizing, all six OOM sites, interleaved
owners, recycling, I/O and refcounts; a whole-SSL control remains explicitly
allocating. Full/partial hooks preserve query ERR state and reject the new owned
factory before callbacks. The inherited memory/CBB matrix remains unchanged.

The exact original SQL lifecycle source and counter preserve every interval.
All six same-fixture functional cases and callback/pool/preparation invariants
match. Each failure round falls from 268 mallocs/270 frees/412766 bytes to
262/264/346910; each cancellation round falls from 536/540/825532 to
524/528/693820. Calloc and realloc counts are unchanged. All six intervals remain
nonzero and the original strict gate remains RED; the reduction is 54 mallocs,
54 frees and 592704 requested bytes, without exempting reconnect or cancellation.

The ordinary live SDK passes 1197/1197 tests and the production-pinned root
passes 1182/1182. Both release-mode builds pass 24/24 steps. An initial full
SDK run failed the unchanged plaintext deadline case before applying the named
migration. Exact bounded replays reproduce that failure on the immutable parent
(4/5 pass) while the candidate passes 5/5; the final unfiltered SDK run alone
passes all 1197. Preserve the failed run and diagnosis: the exact delayed setup
phase and cause remain unproven; no source, test, deadline or threshold changed
to obtain a pass.

Source, raw comparisons, identities and replay tools are retained in the
[owned-pair result](../benchmarks/results/sql_tls_owned_bio_pair_v1/2026_11_18/README.md).
Complete SSL construction, transcript, certificate/verification/crypto workspaces
and ERR/thread lifetimes remain subsequent ownership work. Publication/pins,
production adoption, total TLS capacity and all other open roadmap requirements
remain required. Deferred smoke/security/sanitizer/fuzz campaigns are unchanged.

## Owned client SSL construction and identity setup, 2026-11-18

The isolated native/SDK closes admitted client construction, SNI, DNS/IP
verification setup and repeated clear through explicit borrowed ownership.
Sixteen native paths change against the exact 8709-file owned-BIO parent;
ordinary successful construction preserves its 20 mallocs/20 frees/5983 bytes.
An inherited hostname-copy OOM defect now makes construction fail closed.

Native sizing derives raw extents and a reusable fixed-slot bound. The standard
image reports 46400 bytes, alignment 16, stride 2320 and 20 slots per physical
connection. Separate stable normal/cancellation descriptors survive Session
reset; checked 2N startup regions and metadata are released after both session
arrays. Clear preserves destructive failure semantics and partial cleanup.
This is a construction/setup budget, not a total TLS capacity proof.

The 57-step native proof/build and fifteen verified TLS compatibility cases
pass. Twenty-four of 26 construction rows count zero C heap calls and bytes;
shared-context/copy and cold RNG/ERR controls remain explicitly allocating.
Full live SDK/root suites pass 1205/1205 and 1182/1182, with both SDK release-mode
builds passing 24/24. Two initial focused test assumptions were corrected using
actual pool bounds and native member-initialization order; failed logs remain.

The original lifecycle probe/counter and all callback/pool/preparation invariants
remain unchanged. Each failure round falls from 262 mallocs/264 frees/346909
bytes to 242/244/340926; cancellation falls from 524/528/693818 to
484/488/681852. Calloc/realloc counts match. The fresh same-fixture reduction is
180 mallocs, 180 frees and 53847 bytes in total; every strict interval stays RED.

Exact sources, identities and replay evidence are retained in the
[SSL construction result](../benchmarks/results/sql_tls_owned_ssl_construction_v1/2026_11_18/README.md).
Transcript payload, certificate/verification/crypto workspaces and ERR/RNG/thread
ownership, publication/pins, production adoption, total capacity, D-5 throughput
and all other open release requirements remain required. User-deferred campaigns
and every configured gate remain unchanged.

## Owned client handshake wire storage, 2026-11-18

The isolated native/SDK now owns handshake input, transcript, ClientHello/CBB,
pending plaintext/flight and record byte storage. A pure native query defines
twelve roles in exact reusable size classes; nine bind transactionally and
three allocate on use. The standard profile reports 771936 bytes in seven
classes. Each of N normal and N cancellation connections owns separate stable
startup backing and metadata. BIO and constructor storage remain separate;
the constructor budget becomes 46720 bytes after explicit wire metadata.
These structural budgets do not establish total TLS capacity.

The final native image retains 8710 files with sixteen approved changed paths
against its complete 8709-file parent. Review and actual public-operation REDs
found two fatal-alert defects: forwarding a partial ClientHello released its
owned flight, and an alert attempt did not latch lifetime I/O admission. Both
are fixed and independently reviewed without changing ordinary ownership or
the reserved KeyUpdate guards. Size, failure, cleanup, reuse and first-I/O
checks remain enforced.

The combined native proof/build passes 67/67 steps, including separate handshake
compilation. Thirty-six compatibility cases cover all three cipher suites,
verified DNS/IPv4/IPv6 identities, rejection cases, HRR, fragmentation and BIO
backpressure. Thirty-three retain normal preparation checks; three immutable
ticket-capture contexts prove clear/resumption while explicitly reporting
unsupported readiness. Nine framed cookie/fault cases remain separate from
verified handshakes. Initial witness mistakes and both product REDs are retained.

All 26 historical Debug executables and their original verifiers pass unchanged.
ReleaseSafe folds two ERR startup mallocs into callocs: original fault/vector
failures are retained, with a separately labeled calloc-aware observer and an
exact 9-malloc/2-calloc verifier preserving the total eleven calls, requested
bytes and all other assertions. No original source or threshold is weakened.

Live SDK/root suites pass 1214/1214 and 1182/1182; both SDK release builds pass.
The unchanged full worker lifecycle probe preserves every callback, pool,
preparation and interval invariant. Each failure round changes from
242 mallocs/2 callocs/244 frees/340927 bytes to 199/2/201/34665; cancellation
changes from 484/4/488/681854 to 398/4/402/69330. Across all six rounds this
removes 387 mallocs, 387 frees and 2756358 requested bytes. Realloc remains zero;
every strict interval remains RED.

Exact source, inventory, failures, reviews and replay tools are retained in the
[wire-storage result](../benchmarks/results/sql_tls_client_wire_storage_v1/2026_11_18/README.md).
Certificate/verification/crypto workspaces, semantic CertificateVerify inputs,
sessions and ERR/RNG/thread ownership remain required, along with publication,
pins, production adoption, total capacity, D-5 and other open release work.
User-deferred campaigns and configured gates remain unchanged.
