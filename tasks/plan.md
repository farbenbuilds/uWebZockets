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
