# Bounded `/queries` chunks on PostgreSQL World, 2026-11-19

**Retained the `/queries` change after median throughput rose from 13,457.279 to
50,050.214 requests/s** on the matched local SCRAM fixture. Median HTTP p99 fell
from 27.792 to 9.225 ms. The change submits the existing parameterized point
reads in request-local chunks of at most 16 through the existing `Query.batch` field. It preserves
one database read per requested value, output order, duplicates, and the
original request deadline. The D5 target above 300,000 requests/s for each of
`/db`, `/queries`, and `/updates` remains unmet.

## Matched read-only result

| Timed metric | Control median | Candidate median | Median paired improvement | Control range / median |
| --- | ---: | ---: | ---: | ---: |
| `/queries?count=20`, requests/s | 13,457.279 | 50,050.214 | +270.930% | 2.916% |
| HTTP p99 | 27.792 ms | 9.225 ms | 66.807% lower | 2.058% |
| Application cgroup CPU per completed response | 598.196 µs | 107.441 µs | 82.027% lower | 0.722% |
| PostgreSQL cgroup CPU per completed response | 1,309.442 µs | 385.222 µs | 70.547% lower | 0.630% |

The throughput gains were +265.227%, +280.658%, and +270.930% across the three
pairs. Throughput and both CPU metrics improved in every pair. Their median paired
improvements exceeded the declared control variability thresholds. HTTP p99 improved in every
pair. The first and third pairs started with control, and the second started
with candidate. Each case used a fresh app with 12 workers, eight SQL sockets
per worker, 192 HTTP/1.1 connections at pipeline depth one, and four wrk threads.
Each timed case had a two-second warmup and ten-second measurement. Both arms
used the same cached PostgreSQL 18.6 postmaster, default `auto` plan policy,
World table and index, and the same host-loopback plaintext TCP with SCRAM.
All CPU ratios use completed HTTP responses and aggregate CPU time across cores.
The measurements establish the local `/queries` throughput result. This slice
has no application SDK query latency measurement under load.

The verifier checked 700 exact HTTP 200 bodies against the canonical World
export and 58,900 point reads in 14 fixed cases. Each arm ran a count-20 primary
case and a separate case at each of counts 1, 15, 16, 17, 20 and 500. Duplicates
were allowed. The six warmup-plus-timed cases recorded 2,277,757 HTTP 200
responses and 45,599,420 primary-key reads, with zero writes. The combined
44,280 extra reads were within the 7,680-read allowance in each case for
outstanding requests at the two client cutoffs. All 20 app containers were
removed. The retained timings come from a shared development host.

## Correctness and run history

The exact candidate binary passed the SCRAM lifecycle checks for healthy
counts, order and duplicates, an injected SQL error at call 18, a missing row
in the second chunk after 32 reads, and the original 10-second deadline across
chunks. The deadline returned HTTP 503 in 10.003 seconds and the subsequent
request succeeded. A centralized live test separately invalidates the
caller-owned response token after submitting the first chunk and before
dispatching its completion. All 16 operations in that chunk complete
successfully, and the test verifies that no later chunk starts. An earlier
HTTP/1 peer-reset probe failed its immediate
file-descriptor-closure precondition. HTTP/1 reads are disarmed while an async
response is pending, so the server may observe a peer reset later. The
initial probe's controlled HTTP response objects were not retained. Its raw
SQL observer records and three original-route responses remain in the archive.

The final ordinary unit run passed 1,191 tests and skipped seven of 1,198.
The focused cancellation and migration runs passed six and seven tests,
respectively. An earlier wrong-password unit run used the invalid trust
fixture and was stopped. The original named-apply timeout test failure is
retained. The corrected test waits for SQL readiness before starting the
unchanged 500 ms migration timeout and separately verifies that apply began.

The first paired producer stopped after one control fixed block, before any
candidate or timed case. Live statistics reported one read delta while the
pool was still open. Once the app shut down, the same 50 requests accounted
for exactly 1,000 reads. The final producer uses a fresh app for each fixed
block and validates drained counters. It preserves the failed raw attempt
and the producer/verifier revisions. The screening checker history also
retains the bridge `hashlib` import fix and the host verifier's shadowed
variable fix.

## Screening context and authentication

| Historical screen | `/db` median requests/s | `/queries?count=20` median requests/s | `/updates?count=20` median requests/s |
| --- | ---: | ---: | ---: |
| Bridge fixture | 101,542.332 | 7,255.679 | 2,607.054 |
| Host-loopback fixture before HBA correction | 174,307.638 | 13,483.111 | 4,209.871 |

The screens used separate fixtures and network topologies. A later HBA
inspection established that the host screen matched a localhost `trust` rule.
Bridge authentication remains unverified because the bridge HBA rules were
not retained. The paired SCRAM comparison above supplies the control for the
retained `/queries` change.
The correction made ordinary IPv4 loopback database logins use SCRAM. It
recorded six results covering correct-password success and wrong-password
rejection for `bench`, `uwz_test`, and `uwz_world_test`. The authentication
proof covers these database roles and logins.

The old bridge database and its private files were removed. The owned host
PostgreSQL fixture was idle at the final paired boundary and remains available
locally for subsequent D5 work. Its private inputs stay outside the archive.
A bounded exact-value comparison found zero matches for the three current
host passwords in the 3,117 named staged files it checked. The previously
removed bridge password was outside that comparison.

## Archive verification and replay

[The raw archive](raw_evidence_archive.tgz) preserves both complete source
closures, the candidate patch and test/documentation snapshots, the two
exact executed server ELFs, their original Zig 0.16.0 build receipts, the
pinned compiler executable and notices, the exact wrk package and ELF,
and all relevant raw producer, verifier, fixture and lifecycle evidence.
The control closure has 347 files and the candidate has 348. The candidate's
only runtime source change is `examples/sql_postgres.zig`. The candidate
and control ELF SHA-256 values are recorded in the two build receipts.

From this directory, extract into a new destination with file modes preserved.
The verifier uses Python 3.11+ and does no Docker or network work. It checks
both source and binary identities, then replays the two screening checkers
and the primary raw checker. Original absolute path strings stay in the raw
records. The verifier resolves artifact reads inside the extracted archive.

```sh
sha256sum -c manifest.sha256
mkdir extracted
tar -xzpf raw_evidence_archive.tgz -C extracted
python3 -B extracted/sql_world_queries_chunk_v1_2026_11_19/verify_bundle.py
```

For a new runtime replay, use compatible x86-64 Broadwell instructions,
Linux with io_uring, Docker and cgroup v2, readable host PID and time namespace
coordinates, GNU time, Python 3.11+, the recorded wrk runtime libraries, and
the pinned PostgreSQL 18.6 image already cached. The replay also needs the
recorded CPU affinity and available loopback HTTP port. Use a host with no
active D5 fixture or application using that endpoint.

```sh
python3 -B extracted/sql_world_queries_chunk_v1_2026_11_19/replay_queries.py "$PWD/replay_run"
```

The replay stages the byte-exact World export and verifies the fresh
fixture’s container, PID, postmaster and assigned PostgreSQL port. It binds
copies of the setup and HBA helpers to that port, establishes the SCRAM
rules, and verifies all six authentication outcomes before timing. It uses
the exact archived app binaries and World data and records a new fixture
binding plus the derived harness hashes outside the archive. The frozen
producer, checker and raw records stay intact. The replay invokes the owned
fixture cleanup on exit. Six offline tests cover the fresh-fixture handoff
and reject invalid identity or active clients. The completed D5 comparison
was the runtime measurement for this report.
