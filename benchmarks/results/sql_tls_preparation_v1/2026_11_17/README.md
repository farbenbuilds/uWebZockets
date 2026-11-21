# PostgreSQL TLS preparation integration, 2026-11-17

The isolated SQL candidate prepares native TLS storage after verified handshake
and before PostgreSQL StartupMessage or auxiliary CancelRequest. It waits for
buffered controls and pending output, checks all six reservation results, and
admits SQL work only after complete preparation. The production dependency pins
remain unchanged; this checkpoint retains the implementation and its evidence.

The candidate uses the complete native source from the
[readiness prerequisite](../../sql_tls_readiness_v1/2026_11_17/README.md).
Its source proposal is `f6176c03304e835d315cf4d9cbd86fc27e979f95`.
The archived SQL connection source has SHA256
`501d63f8dc94a90f6861b71a7a88277000c2f64f5fc403a4fbcb1f76b4c81c73`.

## Measured result

The original all-C counter and its 63-byte self-test are unchanged. Each warmed
query interval starts before `Db.query` and ends at callback entry; 16 warmups
precede 256 measured queries. Both typed fixture values are checked afterward.

| Candidate / interval | Samples | malloc | calloc | realloc | free | Requested bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Unchanged SQL, plaintext query | 256 | 0 | 0 | 0 | 0 | 0 |
| Unchanged SQL, verified TLS query | 256 | 2 | 0 | 0 | 2 | 213 |
| Prepared SQL, plaintext query | 256 | 0 | 0 | 0 | 0 | 0 |
| Prepared SQL, verified TLS query | 256 | 0 | 0 | 0 | 0 | 0 |
| Prepared SQL, failure/reconnect worker interval | 3 | 268 | 2 | 0 | 270 | 412698 |
| Prepared SQL, cancellation/reconnect worker interval | 3 | 536 | 4 | 0 | 540 | 825396 |

The counts are per query or per lifecycle round. Both baseline query allocation
sites resolve to `SSLBuffer::EnsureCap`. The six lifecycle rounds hold six of
eight leases and submit a long query, a failing or deadline-bound target, and a
queued query. Their wider worker interval includes all three submissions through
the final callback entry. Target callbacks observe destroyed SSL/BIO state and
115 frees before returning. The queued query uses the reconnected slot with a
new backend PID, generation and prepared TLS while the long query remains active.
All three auxiliary cancellations send through verified, prepared TLS.

All six lifecycle scenarios pass their functional assertions, then fail the
strict allocation check with `NonZeroLifecycleAllocations`. PostgreSQL's full
zero-allocation requirement remains open. SQLite's approved allocation exception
does not apply to PostgreSQL.

## Verification

- Four original focused behavioral tests failed before the SQL implementation;
  the final seven regressions pass, including fragmented/coalesced controls,
  original deadlines, Startup/Cancel gating, plaintext rejection and peer close.
- The candidate's ordinary SQL+SQLite unit suite passes all 1189 tests against
  an isolated PostgreSQL 17.11 fixture, including certificate/name rejection,
  authentication, cancellation and reconnect behavior.
- ReleaseSafe test compilation and ReleaseFast library builds pass. Formatting,
  conventions and release metadata checks pass.
- Source and lifecycle-counter reviews found no actionable defects. Staged
  executables reproduce warmed-query GREEN and lifecycle RED with a fresh fixture.
- The unchanged root suite passes 1158 tests with 24 unavailable-live-fixture
  skips. Dedicated security, sanitizer, fuzz and scan campaigns remain deferred.
  The developer's earlier full `test` command also ran configured C API smoke
  and header checks; subsequent verification uses `test-unit`.

The focused preparation fixture completes its verified handshake over memory
BIOs before exercising real SQL socket callbacks. Separate PostgreSQL runs
exercise actual socket handshakes. Forced short writes/BIO-capacity pressure,
per-reservation allocation-failure injection, ticket controls and hidden
handshake-message fragmentation remain consumer verification gaps.

## Retained evidence

`raw_evidence_archive.tgz` contains the 497-file candidate SDK snapshot, baseline
SQL sources, source-only patch, isolated build delta, three exact executables,
unchanged counters, raw CSV/JSON/logs, source identities, reviews and replay tools.
`files.sha256` inside binds every payload file. No private fixture credentials or
generated private keys are included. Native source publication/adoption and a
bounded TLS lifecycle allocation design remain separate work.

Extract the archive into an empty directory, then replay on the recorded Linux
glibc/Docker environment with an output path outside the artifact:

```sh
python3 replay.py --output /path/on/ssd/fresh-sql-replay
```

The replay provisions only its own pinned PostgreSQL image on a random loopback
port, retains strict check exits, then removes its container and private PKI.
`reconstruct_sdk.py --native-root /path/to/complete/native/tree --output /path/on/ssd/fresh-sdk`
checks all 8709 native file hashes and reconstructs the isolated SDK. Obtain that
complete source from the prerequisite's reviewed source proposal; the SDK
snapshot intentionally does not change the repository's published dependency pin.
