# SQL World capacity screen

The accepted SQL World binary fell below 300,000 requests/s on all three
routes across the four local client profiles tested on November 19, 2026
(Bangkok time). D5 remains open.

| HTTP connections | wrk threads | `/db` requests/s | `/queries?count=20` requests/s | `/updates?count=20` requests/s |
| ---: | ---: | ---: | ---: | ---: |
| 96 | 4 | 166,125.74 | 49,290.49 | 12,905.49 |
| 192 | 4 | 172,238.03 | 49,820.47 | 12,781.71 |
| 384 | 4 | **174,418.69** | **49,899.19** | 12,665.63 |
| 192 | 8 | 162,490.54 | 48,349.06 | 12,711.78 |

Each cell is the median of three timed samples. The archive records all
throughput, HTTP p99, CPU-per-response and wrk utilization triplets. The
fastest median for `/updates` used 96 HTTP connections, while `/db` and
`/queries` recorded their fastest medians at 384. Every timed sample remained
below the target.

## Measurement

The shared development host ran PostgreSQL 18.6 over loopback TCP with
SCRAM-SHA-256, default `plan_cache_mode=auto`, autovacuum enabled and the
fixture's existing durability settings. The accepted `/updates` checkpoint
binary served every case with 12 application workers and 96 PostgreSQL
connections. The recorded build targets native x86-64 Linux with musl.
`/db` performs one primary-key read. `/queries` performs 20 reads. `/updates`
performs 20 reads and 20 row updates. The HTTP/1.1 client pipeline depth was
one, with a 2-second warmup and 10-second timed invocation in each timed case.

The three serial fixed cohorts verified 150 typed HTTP 200 response bodies,
exact SQL work, and persisted update values. The 36 timed cases and their
warmups completed 24,375,205, 7,086,772 and 1,818,714 HTTP 200 responses for
`/db`, `/queries` and `/updates`, respectively, with zero recorded client
errors or PostgreSQL rollbacks. Per-case SQL work was checked against the
actual connection setting and its cutoff allowance. The cutoff recorded
stable samples spanning 1.284 to 1.320 seconds. All 39 application containers
exited successfully and were removed. At the final measurement boundary,
the owned PostgreSQL fixture was idle with zero TCP clients and no matching
application containers remained.

Application and PostgreSQL cgroup CPU and wrk process CPU include user and
system time. PostgreSQL CPU, WAL and checkpointer observations are cluster
scoped. The archive retains storage, maintenance and physical table/index
observations by case. wrk utilization divides aggregate client CPU by the
configured thread count and measured duration. These observations describe
the tested profiles on this host.

For each route's fastest profile, the median of the same-case application
plus PostgreSQL CPU cost was 116.418, 495.379 and 1,761.479 microseconds per
response for `/db`, `/queries` and `/updates`, respectively. At those
unchanged costs, 300,000 requests/s would require 34.93, 148.61 and 528.44
CPU-seconds per wall second before generator cost. Including wrk gives
41.53, 158.55 and 542.09. The host exposed 28 logical CPUs. These conditional
estimates apply at the measured CPU costs on the observed host.

## Evidence and offline verification

`world_scaling/` in the payload holds the frozen producer, checker, plan,
prelaunch checksums, eight contract tests and complete 39-case raw run.
`measurements/capacity_screen_01/verified.json` in that directory contains
the recomputed full summary alongside the raw logs. The original runtime
commands are preserved. A fresh live run was outside this verification.

The exact prior [queries packet](../../sql_world_queries_chunk_v1/2026_11_19/README.md)
and [updates packet](../../sql_world_updates_chunk_v1/2026_11_19/README.md)
provide the compiler, wrk, fixture and shared producer inputs, the updates
ELF and its build and source closure, and the bundled notices, including
musl's copyright notice. The capacity archive lists each referenced file's
owning prerequisite in `dependencies.json`. The verifier checks both
archives against their pinned checksums and checks the complete extracted
inventories, file modes and hashes before loading the shared Python
checkers. Recorded input paths resolve only to the three extracted packets.
The verifier recomputes the summary from raw data and compares it to the
frozen result.

From the repository root, verify using Python 3.11 or later and GNU tar.

```sh
(
  set -eu
  results="$PWD/benchmarks/results"
  capacity="$results/sql_world_capacity_v1/2026_11_19"
  queries="$results/sql_world_queries_chunk_v1/2026_11_19/raw_evidence_archive.tgz"
  updates="$results/sql_world_updates_chunk_v1/2026_11_19/raw_evidence_archive.tgz"

  (cd "$capacity" && sha256sum -c manifest.sha256)
  printf '%s  %s\n' \
    965f2d156fdadfad52252ff3bc34885015ee4340fee9a8fc5113096d3a00d351 "$queries" \
    af164645eabbe06a5fc3fe14d7bee32e458366767b1f7c7d13cb955ab38de8b9 "$updates" |
    sha256sum -c -

  mkdir -p "$PWD/.zig-cache"
  check=$(mktemp -d "$PWD/.zig-cache/sql-world-capacity-check.XXXXXXXX")
  tar -xzpf "$queries" -C "$check"
  tar -xzpf "$updates" -C "$check"
  tar -xzpf "$capacity/raw_evidence_archive.tgz" -C "$check"
  python3 -E -s -B "$check/sql_world_capacity_v1_2026_11_19/verify_bundle.py" \
    --queries-archive "$queries" --queries-root "$check/sql_world_queries_chunk_v1_2026_11_19" \
    --updates-archive "$updates" --updates-root "$check/sql_world_updates_chunk_v1_2026_11_19" \
    --test-checkers
)
```
