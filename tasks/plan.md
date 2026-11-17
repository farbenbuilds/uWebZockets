# v2.3.0 implementation plan

Source requirements: engineering roadmap Section 9 (D-0 through D-11),
Section 17.3 (FS-0), Section 17.4 (FS-1), the v2.3.0 release checklist,
and the Section 8.2 carryovers. The task list is `tasks/todo.md`.

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
