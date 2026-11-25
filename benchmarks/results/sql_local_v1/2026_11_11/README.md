# SQL local characterization v1, 2026-11-11

These are real-engine measurements from one shared development host, not
quiet-host or official HttpArena acceptance. The unchanged release target
above 300,000 RPS was **not met**; that acceptance item remains open.

## Host and workload

| Field | Value |
| --- | --- |
| CPU | Intel Xeon E5-2680 v4, 14 physical cores / 28 logical CPUs |
| Zig | 0.16.0, ReleaseFast |
| SQL engine | PostgreSQL 17.11, image digest retained in tools.txt |
| PostgreSQL storage | Test-container tmpfs; fsync and synchronous_commit enabled |
| Transport | io_uring, HTTP/1.1 keep-alive, PostgreSQL plaintext development opt-in |
| Affinity | Public cluster physical-core pinning; effective thread masks retained |
| SQL pool | Eight independent connections per worker |
| Load generator | wrk Debian/4.1.0-4build3, four threads, 16 HTTP connections per worker |
| Sampling | Two-second warmup, three ten-second samples per route/cohort |

## HTTP results

| Workers | Route | Median RPS | Sample range RPS | Median p50 | Median p99 | Max sampled process RSS |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | `/db` | 28,325.08 | 28,246.40–28,685.12 | 554 us | 751 us | 13,948 KiB |
| 1 | `/queries?count=20` | 2,002.30 | 1,998.31–2,015.55 | 8,290 us | 9,443 us | 13,948 KiB |
| 1 | `/updates?count=20` | 860.30 | 838.72–860.92 | 19,582 us | 22,529 us | 13,948 KiB |
| 4 | `/db` | 80,884.65 | 80,103.91–81,623.27 | 710 us | 1,506 us | 41,008 KiB |
| 8 | `/db` | 100,205.43 | 99,381.84–101,559.16 | 1,150 us | 2,642 us | 78,028 KiB |
| 12 | `/db` | 112,674.14 | 111,299.17–113,422.13 | 1,469 us | 3,743 us | 114,368 KiB |

Every retained HTTP sample reported zero connect, read, write, timeout, and
status errors. Cluster RSS is aggregate process memory and is not divided
into an invented per-worker resident footprint. The one-worker cohort supplies
the single-worker resident measurement.

## Direct query and acquisition timing

Each probe uses one worker, eight SQL connections, 16 caller-owned in-flight
requests, 1,024 warmup queries and 16,384 measured bound `id=1` queries. Each
cohort retains three independent probe runs after its HTTP server stops.
These are distinct from HTTP request latency. The admission measurement is
submission-to-assignment-trace time and includes admission/encoding overhead;
it is an upper bound on pure queue wait.

| Preceding HTTP cohort | Query p50 | Query p99 | Admission p50 | Admission p99 |
| ---: | ---: | ---: | ---: | ---: |
| 1 workers | 404.194 us | 563.744 us | 201.978 us | 297.648 us |
| 4 workers | 387.168 us | 546.142 us | 193.814 us | 287.163 us |
| 8 workers | 405.561 us | 559.377 us | 202.687 us | 293.981 us |
| 12 workers | 398.570 us | 556.657 us | 198.999 us | 295.030 us |

All 196,608 measured direct queries succeeded. Raw CSV distributions are
retained, including p99.9 and maximum latency; an independent standard-library
summary checks the probe-reported percentiles against every raw sample.

## Interpretation and limits

The local database, application workers, wrk and unrelated host workloads share
this CPU. Adding workers increases single-query throughput but does not reach
the required absolute target on this cohort. The 12-worker process reports a
maximum lifetime CPU average of 590%; this alone does not identify whether the
remaining limit is database execution, local transport, scheduling, or another
host cost. A [scoped diagnostic follow-up](diagnostic/README.md) measures
substantial kernel/network/scheduling cost, with raw counters and a separate
perturbed syscall trace in `diagnostic/the omitted raw evidence archive`. It does not yet
identify one function as the sole bottleneck or establish an accepted fix.
The multi-query and update routes perform their real parameterized SQL calls;
the count-20 values are not relabeled as single-query benchmark results.

The database uses tmpfs and these results make no disk-durability performance
claim. No ephemeral development TLS certificate was used for recorded load:
PostgreSQL plaintext was explicitly selected for this isolated local cohort.

## Reproduction and provenance

Use [`../../../sql_local_v1.md`](../../../sql_local_v1.md) and the unchanged
[`../../../sql_local_v1.env`](../../../sql_local_v1.env). The original archive contained
the exact harness, tool package versions/checksums and retrieval times,
dependency pins, flake-lock checksum, source archive, binary checksums, CPU
quota ancestry, governor/SMT/memlock/kernel metadata, effective affinities,
descriptor snapshots, owned listener PIDs, sampled CPU/RSS, raw wrk output,
request/representative response bytes, direct-query CSV, database settings,
and generated summaries. Credentials and private keys are excluded.

All four before/after build-input snapshots matched. The working tree was an
uncommitted 2.3.0 candidate; its exact commit, tracked patch and untracked-input
checksums are retained rather than presenting the older base commit as the
complete candidate. The identical source archive is hard-linked within the tar
archive. Executable bodies are omitted to keep the evidence reviewable; their
exact hashes, build command, and complete benchmark build inputs remain in the
archive.
The pre-existing h1spec checkout difference is recorded in status snapshots;
the SQL benchmark does not build or change that submodule.

`run.status=passed` means evidence collection and validation succeeded, not
that the 300K RPS target passed. `cohorts.json` records the explicit false
throughput/official-acceptance outcomes. System tools were preinstalled; their
unknown historical retrieval times are stated as unavailable.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `7051cc01f25670e0def4f67d1a330b91c87837f862cfc5c2fd03cf3ad448a613`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
