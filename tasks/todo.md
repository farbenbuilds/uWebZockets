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
      proposed SQL-ALLOC-002 is pending explicit user approval.
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
- [x] Release metadata synchronized to 2.3.0; no tag or publication.
- [x] Independent slice reviews, findings resolved and changed work
      re-reviewed, including the final adapter and evidence package.
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
  Current GitHub credentials have read-only access to the libxev and lsquic
  forks.
- The TLS C-allocation audit retains the failed strict gate. SQLite's
  SQL-ALLOC-001 approval does not approve proposed SQL-ALLOC-002.
- Native Windows, second-machine fork resolution and designated quiet-host
  runs still require their specified environments. Cross-compilation is
  recorded separately and cannot substitute for those runtime gates.
- Retained fork histories and same-machine offline replay are in
  `benchmarks/results/dependency_archives_v2_3/2026_11_11/README.md`.
  The existing h1spec license uncertainty still needs release-owner resolution.
