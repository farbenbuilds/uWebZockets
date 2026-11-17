# v2.3.0 execution and evidence

- [x] Architect scope, interfaces, ownership, and acceptance criteria.
- [x] D-0 / FS-0: worker service lifecycle, rollback, readiness, shutdown.
- [x] D-0: conditional SQL export/build and unchanged C ABI surface; four
      symbol-exclusion consumer cohorts passed.
- [x] D-1: bounded PostgreSQL framing, startup, MD5, SCRAM, verified TLS.
- [x] D-1: every required binary row type, malformed and truncated input.
- [x] D-2: 8–16 worker sockets, bounded waits, deadlines, reconnects, telemetry.
- [x] D-3: bound parameters and pipelined extended-query execution.
- [x] D-4: prepared cache and bounded borrowed row iteration/copy.
- [x] D-5: runnable `/db`, `/queries`, `/updates` locally verified.
- [ ] D-5: official external HttpArena adapter activation.
- [ ] D-5: retained real async-db result above 300K RPS with full provenance.
- [x] D-6: pinned SQLite, memory/file/WAL/busy/FK tests; SQL-ALLOC-001
      explicitly approved by the user for upstream C allocations only.
- [x] D-7: transactions, savepoints, deadlines, quarantine and shutdown tests.
- [x] D-8: ordered checksum migrations, locks, idempotence, rollback and
      worker-readiness integration tests.
- [x] D-9: explicit typed mapping without schema reflection.
- [x] D-9: retained direct/named mapping compile-time and binary-size
      comparison; 28 builds and 280 independently checked runtime outputs.
- [x] D-10: PostgreSQL service CI, SQLite integration, targeted fuzz and
      Zig allocation coverage.
- [ ] D-10: strict total PostgreSQL TLS allocation gate. The retained audit
      fails with two BoringSSL C malloc calls per measured query;
      proposed SQL-ALLOC-002 is pending explicit user approval. The isolated
      fixed-buffer experiment counts zero calls for 256 warmed queries, but
      native integration and other post-handshake allocation paths remain open:
      `benchmarks/results/sql_tls_retention_v1/2026_11_17/README.md`.
- [x] Verify native reservation failure ownership, real pending-state rejection,
      configured protocol exclusions and verified reuse after `SSL_clear`:
      sixteen final cases and both inherited buffer/record proofs pass on
      unchanged candidate source. This is not zero-allocation lifecycle proof.
- [x] Quantify other client TLS control allocations with unchanged accounting:
      twelve public-API TLS/BIO rows and 255 operations reconcile. Valid ticket
      and KeyUpdate processing still allocates after record reservation. Exact
      scopes, source maps, review and offline replay are retained in
      `benchmarks/results/sql_tls_prerequisites_v1/2026_11_17/README.md`.
- [ ] Eliminate remaining request-path TLS control allocations and verify a
      maintained, integrated native solution against the unchanged allocation
      requirement. Define error/reconnect attribution without treating startup
      and teardown measurements as a blanket request-path exception.
- [x] Remove the bounded HKDF label heap buffer in an isolated native candidate:
      1440 differential cases preserve results, errors and full-buffer hashes;
      all 700 successful calls count zero allocator operations. Source, native
      rebuild, controls and replay are retained in
      `benchmarks/results/sql_tls_hkdf_fixed_v1/2026_11_17/README.md`.
- [x] Retain bounded incoming post-handshake storage in an explicit client-only
      native proposal. Fragment/coalescing helpers count zero heap operations;
      encrypted baseline/unreserved/reserved outcomes agree, and 21 new
      lifecycle/fault cases plus inherited record/HKDF checks pass. Default
      startup memory, ceiling restrictions, residual control allocations and
      replay are retained in
      `benchmarks/results/sql_tls_hs_buffer_v1/2026_11_17/README.md`.
- [x] Recycle a single startup-reserved AEAD context in the isolated native
      client proposal. No-response KeyUpdate counts zero allocator operations
      across all three negotiated TLS 1.3 suites; direct crypto/failure tests,
      22 lifecycle cases and inherited regressions pass. Callback/ownership
      restrictions, residual allocations and replay are retained in
      `benchmarks/results/sql_tls_aead_reuse_v1/2026_11_17/README.md`.
- [x] Prepare an unpublished native TLS source proposal from the exact official
      BoringSSL base and fifteen reviewed candidate paths. Full 8,709-file
      content/type and official Git mode comparisons, compact prerequisite
      bundle restoration and rejection controls are retained in
      `benchmarks/results/sql_tls_source_proposal_v1/2026_11_17/README.md`.
      Complete base history is external; publication, pins, SQL adoption and
      the strict PostgreSQL allocation gate remain open.
- [x] D-10: 1,012 enabled tests passed with ASan/UBSan/LSan; retained local
      p50/p99, admission upper-bound and process RSS evidence in
      `benchmarks/results/sql_local_v1/2026_11_11/README.md`.
- [x] FS-1: SQL metrics and optional statement-only tracing.
- [x] D-11: SQL docs, examples and explicit support/security limits.
- [x] Section 8.2: ownership, WebTransport, GRO, perf, adapter, fork/platform,
      and conditional kTLS carryovers audited individually.
- [x] Section 8.2 ownership: cluster runtime, connection parking, HTTP/2
      storage, response async lifecycle, and QUIC header sets extracted,
      independently reviewed, and verified together.
- [x] Section 8.2 archive retention: all three active maintained integration
      histories and three qpack/hpack companion histories retained as complete
      bundles, imported and fscked offline from fresh extraction.
- [x] Section 8.2 WebTransport prerequisite: reviewed local lsquic uni-stream
      API and required lifetime fixes; eight real-engine groups in Debug,
      ReleaseSafe and strict sanitizers, all 83 existing native cases, and
      Windows/macOS production-library cross-compilation pass.
- [x] Section 8.2 reliable-reset functional prerequisite: real lost-prefix
      recovery, full-width metadata, frozen flow credit, header ownership,
      obsolete ACKs and eight-stream ACK batching; 83 upstream Debug cases,
      ten ReleaseSafe regressions, Windows/macOS production compilation and
      native pinned quic-go interoperability pass. The proposal is local;
      remaining smoke/security runs are deferred by the user.
- [x] Section 8.2 WebTransport SETTINGS prerequisite: opt-in draft-16 writer,
      immutable peer query and quiescent notification; real encrypted
      generation, fragmented/invalid control delivery and lifecycle regressions
      pass in Debug, ReleaseSafe and ReleaseFast. Source and evidence are
      archived; the proposal is unpublished and live sessions remain open.
- [x] Section 8.2 stream-credit prerequisite: WT-only client uni admission and
      advertisement agree; outgoing/incoming bidi credit follows initiator.
      Real encrypted uni limits and four raw bidi halves pass in all three
      build modes. The reviewed local proposal remains unpublished.
- [x] Section 8.2 native child-stream functional slice: creation, classification,
      directional metadata, reset/STOP ordering, rejected negotiation and
      GOAWAY isolation pass 65 scenarios in all three modes, all 83 native
      Debug cases and Windows/macOS production compilation. Source and evidence
      are archived; runtime integration and publication remain open.
- [x] Section 8.2 private Zig backend contract: published-pin unsupported paths
      and real candidate TLS, SETTINGS, CONNECT and four child directions pass.
      The ten-test candidate cohort passes Debug, ReleaseSafe and ReleaseFast;
      bounded engine/session integration and listener activation remain open.
- [x] Section 8.2 bounded QUIC connection ownership: generation-checked slots,
      retained stream leases, indexed native stream contexts and immutable peer
      snapshots. All 971 centralized tests pass; actual TLS/HTTP body, abort
      cleanup and slot reuse run through the real engine and UDP send path.
      WebTransport session binding and positive engine child acceptance remain open.
- [x] Section 8.2 single-session App admission checkpoint: explicit synchronous
      CONNECT authorization and Origin policy, stable route identity, bounded
      capsules, header flushing and credit-blocked/delayed-FIN reset recovery.
      All 991 published-pin central tests and eight actual App/TLS cases in
      Debug, ReleaseSafe and ReleaseFast pass. The candidate profile has session
      flow control off; this does not complete WT activation or multi-session
      accounting. Exact sources and evidence are retained in
      `benchmarks/results/webtransport_app_admission_v1/2026_11_16/README.md`.
- [x] Section 8.2 App routing and deferred-admission evidence: real native/UDP
      datagrams, header reuse, callback payloads, per-connection rings,
      overflow/recovery, Close/abort/reuse clearing, held-SETTINGS positive and
      cancellation paths, fragmented flow-off capsules, DRAIN and native
      cooldown effects. All 18 tests (17 functional plus an import anchor)
      pass in Debug, ReleaseSafe and ReleaseFast against unchanged production
      source. Exact proof scope and remaining gates are retained in
      `benchmarks/results/webtransport_app_routing_v1/2026_11_16/README.md`.
- [x] Section 8.2 early datagrams: startup-bounded generation-scoped storage,
      per-connection quota, FIFO replay after admission, supplied-time expiry,
      exact HTTP/refusal/cancellation/Close cleanup, terminal-budget isolation
      and callback-safe teardown. All 1009 centralized tests and the 33-test
      native cohort in all three optimization modes pass. Early child-stream
      association, multi-session
      accounting, independent-client acceptance and published activation remain
      open. Evidence is retained in
      `benchmarks/results/webtransport_early_datagrams_v1/2026_11_16/README.md`.
- [x] Release metadata synchronized to 2.3.0; no tag or publication.
- [x] Section 8.2 private incoming-child lifecycle checkpoint: generation-checked
      association, bounded early receive, coded capacity refusal, native-close
      ownership and unknown final sizes. Nine actual App cases and the existing
      33-case cohort pass in all three modes. Global refusal, terminal orphan
      cleanup and connection-abort cause ordering have retained regressions.
      Local native UNI credit proposal `005ab244169f269689e511d6b77dd2187e318df1`
      resolves the cross-initial-window deadlock; 65 native WT scenarios and
      83 upstream Debug cases pass. This does not complete WT activation.
      Exact scope and remaining work are retained in
      `benchmarks/results/webtransport_child_lifecycle_v1/2026_11_16/README.md`.
- [x] Section 8.2 incoming-child callback/reset safety: native-status guards
      after callbacks, completed terminal RX cleanup and refreshed waiting
      cancellation checks. All 17 actual App cases pass in three modes,
      including prebuffered callback shutdown/abort, Close-before-FIN,
      independent full-width STOP/RESET and reliable final-gap accounting.
      `benchmarks/results/webtransport_child_callbacks_v1/2026_11_16/README.md`
      retains the original failures, source and verification. Public child
      I/O/TX, multi-session flow, independent-client and publication gates
      remain open; this does not complete WT activation.
- [x] Independent slice reviews, findings resolved and changed work
      re-reviewed, including the final adapter and evidence package.
- [x] Section 8.2 public child receive checkpoint: shared sixteen-path endpoint
      registration, App-affine generation handles, receive/session callbacks,
      cancellation, explicit BIDI finish and child-only startup. The 26 actual
      public App cases pass in Debug, ReleaseSafe and ReleaseFast on source
      commit `7ecfc6b9285779e89b99a95dc910efa8f8403c46`; 1049 functional tests
      and final ReleaseSafe compilation/ReleaseFast library checks pass.
      `benchmarks/results/webtransport_public_receive_v1/2026_11_16/README.md`
      retains exact scope, historical failures and reproducible inputs. Public
      duplex writes/outgoing streams, multi-session flow, independent-client
      acceptance and publication remain open.
- [x] Section 8.2 peer-BIDI transmission checkpoint: accepted-prefix writes,
      one-shot writable events, actual typed-publication readiness and bounded
      timer wakes. Source `78fc2d62300c4fdf5cccf57efc3acdb798a1be97` passes
      1063 functional tests. Its 37 actual native cases pass in all three
      modes, including real stream/connection credit and loop-only deadline wakes.
      C-boundary ownership/errno fault tests, io_uring/epoll wake proofs,
      package/examples and Windows/macOS compilation are retained in
      `benchmarks/results/webtransport_public_tx_v1/2026_11_17/README.md`.
      Local half-stop/reset commands, outgoing streams, multi-session flow,
      independent-client acceptance and publication remain open.
- [x] Requirement-by-requirement audit and retained final check results in
      `benchmarks/results/release_candidate_v2_3/2026_11_11/README.md`.
- [ ] Every required release gate passes; open results are listed below.

## Open acceptance evidence

- The retained local SQL cohort reaches 112,674 median RPS at 12 workers;
  the unchanged requirement above 300,000 RPS remains unmet. The shared host
  is not official HttpArena or quiet-host evidence.
- HttpArena snapshot `5646c1d2a4f4656073430ce55ed39a5c9c2e6749` defines
  `/async-db` as an `items` range scan and has removed `crud`. Its adapter
  still pins 1.8.0. The current-contract adapter proposal is implemented,
  independently reviewed, and archived with 4,096 seed-matched responses in
  `benchmarks/results/httparena_adapter_v1/2026_11_11/README.md`.
  Publication requires a real release commit/hash and the external owner.
- WebTransport remains open. The exact lsquic pin lacks draft-16 SETTINGS,
  full-width server stream association, server unidirectional stream creation,
  and reliable reset. The pinned aioquic 1.3.0 client also lacks draft-16
  reliable reset. A flag change or fake backend cannot establish activation.
  The unpublished uni-stream prerequisite and separate native ACK, QPACK and
  crypto-cleanup fixes are reviewed local commits LSQ-003 through LSQ-007;
  `benchmarks/results/lsquic_uni_prerequisite_v1/2026_11_11/README.md` records
  their exact evidence and mandatory maintained-fork integration steps.
  The reliable-reset functional proposal is now frozen at
  `3640992bb231d3f0f2647e03fda6a2776fcc23ca`; its
  [source and evidence](../benchmarks/results/lsquic_reliable_reset_prerequisite_v1/2026_11_13/README.md)
  retain the passing regressions and independent native interoperability.
  The following local SETTINGS proposal is frozen at
  `8b0ef12414cdcf7b8c20e0b9f4fceb321358c2d0`; its
  [source and evidence](../benchmarks/results/lsquic_webtransport_settings_v1/2026_11_13/README.md)
  preserve generation, immutable peer publication and control-delivery checks.
  The following [stream-credit proposal](../benchmarks/results/lsquic_webtransport_credit_v1/2026_11_13/README.md)
  is frozen at `9f0088c58fe67cccf1871dc172c90c2ec6f97944`.
  The incomplete [child-stream checkpoint](../benchmarks/results/lsquic_webtransport_children_checkpoint_v1/2026_11_16/README.md)
  is saved at `a1947ce3a4ceeb98413e53014cc87f72b6d89869`: 41 focused Debug
  scenarios passed at that point, while delayed SETTINGS still allowed reset
  notification before typed publication. The following reviewed
  [functional slice](../benchmarks/results/lsquic_webtransport_children_v1/2026_11_16/README.md)
  is frozen at `2e229b3e0a9bb293c4d7f74f7532e09213b8cb5c`; it fixes that
  regression, placement errors and GOAWAY interactions. Child-specific loss
  campaigns and independent compatible-client acceptance remain open.
  The private Zig adapter and its real TLS scaffold are retained in the
  [backend evidence](../benchmarks/results/webtransport_zig_backend_v1/2026_11_16/README.md).
  This leaf does not yet connect sessions, application routing or datagrams.
  The following [engine ownership slice](../benchmarks/results/webtransport_zig_engine_v1/2026_11_16/README.md)
  connects bounded connection slots and stream contexts to actual engine
  callbacks. The following [App admission checkpoint](../benchmarks/results/webtransport_app_admission_v1/2026_11_16/README.md)
  binds App policy, capsules and one session per connection when compiled
  against the complete local native proposal. That profile has session flow
  control off; the published listener still leaves WT negotiation off.
  The following [routing evidence](../benchmarks/results/webtransport_app_routing_v1/2026_11_16/README.md)
  verifies wire datagrams, ring lifetimes, held-SETTINGS admission/cancellation,
  fragmented capsules, DRAIN/Close and native cooldown without changing that
  source or activation policy. The following
  [early-datagram implementation](../benchmarks/results/webtransport_early_datagrams_v1/2026_11_16/README.md)
  adds bounded generation-scoped buffering and replay after admission.
  The following [private incoming-child checkpoint](../benchmarks/results/webtransport_app_children_v1/2026_11_16/README.md)
  connects the receive consumer and bounded child association. The
  [lifecycle checkpoint](../benchmarks/results/webtransport_child_lifecycle_v1/2026_11_16/README.md)
  adds actual BIDI/early/expiry/capacity/teardown evidence and the reviewed
  local UNI credit proposal. The following
  [callback/reset evidence](../benchmarks/results/webtransport_child_callbacks_v1/2026_11_16/README.md)
  verifies callback shutdown, Close-before-FIN, reliable reset ordering and
  final accounting. The
  [public receive checkpoint](../benchmarks/results/webtransport_public_receive_v1/2026_11_16/README.md)
  adds endpoint callbacks, generation handles, cancellation, explicit send
  finish and session events. The
  [peer-BIDI transmit checkpoint](../benchmarks/results/webtransport_public_tx_v1/2026_11_17/README.md)
  adds writes, one-shot writable events and deferred timer service. Local
  half-stop/reset commands, outgoing streams and multi-session flow accounting
  remain required.
  Published draft-16 SETTINGS, long-lived CONNECT, child association, live session
  integration, client acceptance and published fork/pin updates remain open.
- Dependency provenance still encounters the user's pre-existing h1spec
  checkout mismatch. The recorded pin passed 33/33 tests in an isolated
  checkout; restoring the user's checkout awaits their answer.
- GRO is implemented and verified on both Linux backends, including source
  address preservation, sustained HTTP/3 streams and musl compilation. Its
  typed poll-cancellation dependency fix is the reviewed XEV-008 proposal;
  the active libxev pin is unchanged until the maintained-fork owner merges
  the patch. Its local proposal commit is
  `5b2cde22c4ab8e472b4d810a2f7225ff95cd61d5`; the verified incremental
  maintainer bundle and instructions are in
  `/tmp/uwz-xev008-maintainer-handoff`. This unpublished commit is not a pin.
  Fork write permissions must be rechecked before publication.
- The TLS C-allocation audit retains the failed strict gate. SQLite's
  SQL-ALLOC-001 approval does not approve proposed SQL-ALLOC-002.
  Read-only diagnosis against the exact BoringSSL pin resolves both observed
  malloc return PCs to `SSLBuffer::EnsureCap`; read/write attribution remains
  a source-based inference because the trace captured no parent stacks.
  `SSL_MODE_RELEASE_BUFFERS` and read-ahead compatibility APIs are no-ops in
  that pin; its buffer pool stores certificates. No supported per-session
  record-buffer retention API was found. A reviewed dependency change or an
  explicitly approved exception is still required; accounting is unchanged.
- Native Windows, second-machine fork resolution and designated quiet-host
  runs still require their specified environments. Cross-compilation is
  recorded separately and cannot substitute for those runtime gates.
- Retained fork histories and same-machine offline replay are in
  `benchmarks/results/dependency_archives_v2_3/2026_11_11/README.md`.
  The existing h1spec license uncertainty still needs release-owner resolution.

## WebTransport session ownership and flow control, 2026-11-17

- [x] Move session identity, route, phase and callback ownership into global
  CONNECT stream records with an O(N) startup-sized index; preserve flow-off
  rejection of a second simultaneous session.
- [x] Retain all 67 native cases with updated private observation helpers and
  verify index namespace, stale-handle, capacity and allocation invariants.
- [x] Add and verify native receive high-water/delta observation independently
  of readability, including NULL Root contexts and pre-callback enforcement.
- [x] Add pure cumulative stream/data budgets, bounded coalescing credit output
  and atomic consumption/grant transitions; verify them independently of I/O.
- [x] Retain early used/reclaimed receive debt through child destruction and
  NULL contexts, transfer CONNECT ownership, and verify debit before callbacks.
- [x] Integrate positive receive-limit enforcement, send/create budgets and
  credit capsule output with the retained accounting. Commit `cc5013e` passes
  1124 ordinary unit tests and the native flow/debt/datagram matrices in all
  three optimization modes; production dependency pins remain unchanged.
  Exact scope, retained sources and relocated replay are in
  `benchmarks/results/webtransport_positive_flow_v1/2026_11_17/README.md`.
- [x] Enable and verify multiple sessions, independent routes and scoped cleanup.
- [x] Multiplexing prerequisite: stable session-specific ring cleanup, typed
  Binding cleanup scope and negotiated-only admission, without new allocation.
- [x] Multiplexing evidence: actual same-connection route/child/datagram and
  flow isolation, scoped retirement/drain, full teardown, legacy policy and
  generation reuse. Native 11-case isolation and separate refusal case pass in
  all three modes with retained flow18/debt77/datagram33 regressions. Root passes
  1128 ordinary tests, release compilation, examples and downstream-consumer
  checks; independent source/evidence review is clear. Graceful transport
  teardown can await real peer FIN after logical session retirement.
- [ ] Complete independent draft-16 acceptance, reviewed fork publication and
  the remaining full release requirements.
- [ ] Publish the reviewed native histories through maintained-fork integration
  PRs, then update all four manifest views and verify normal-build activation.
  Current authenticated access remains read-only. The live lsquic mirror is
  behind upstream; branch-protection queries return 404, leaving protection
  unverified.
- [x] Retain a durable publication-preparation handoff with all eighteen
  original/publication source identities, complete canonical metadata,
  unchanged XEV-008 history and self-contained companion bundles. Fresh and
  relocated offline imports, deterministic conversion and refusal checks pass;
  independent metadata review is clear. Exact limits and live provenance are
  retained in
  `benchmarks/results/dependency_publication_v2_3/2026_11_17/README.md`.
- [x] Adapt and verify the two required compatible lsquic fixes found during
  publication review: QPACK terminal-state handling (LSQ-021) and validated-path
  preservation (LSQ-022). Preserve the original candidate and retain regression,
  independent review and combined client/native evidence for the new source.
  Original `ed8f8f7` and prepared `3d775d8` have identical source: 85 native
  cases, fifteen retained mode/cohort runs and all 27 public-client cases pass.
  Exact sources, incremental histories, raw logs and replay tools are retained
  in `benchmarks/results/lsquic_compatible_fixes_v1/2026_11_17/README.md`.
- [x] Independent public-App acceptance: reuse the exact official client pin,
  verify fresh CA/TLS/protocol negotiation, reconcile actual callback/ring and
  child observations, prove bounded credit/isolation behavior and clean shutdown,
  and retain three-profile reviewed/replayed evidence. All 27 final cases pass
  with strict source/identity/payload reconciliation and clean native shutdown;
  actual `RESET_STREAM_AT` wire metadata matches application final-size/code.
  Publication, capability activation and deferred campaigns remain open.
  Exact sources, all 27 final results and relocated replay are retained in
  `benchmarks/results/webtransport_independent_client_v1/2026_11_17/README.md`.
