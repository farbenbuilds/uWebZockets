# SQL local characterization v1

This harness measures real PostgreSQL query paths and the World HTTP routes.
It retains local evidence and does not declare a quiet host or an official
HttpArena run. The release target remains **above 300,000 requests/second**;
an unsuccessful target result is recorded without changing that threshold.

## Contract and cohorts

[`sql_local_v1.env`](sql_local_v1.env) fixes four wrk threads, 16 HTTP
connections per worker, a two-second warmup, and three ten-second samples.
The independently owned SQL pools contain eight connections per worker.
Select 1, 4, 8, or 12 workers; 12 workers require 96 database connections plus
administrative capacity. Use worker counts supported by the host's physical
cores and the database connection limit. Each worker count, backend, TLS
policy, and host is a distinct cohort.

The benchmark server uses the public thread-per-core builder and reuses the
actual SQL example handlers. Every worker owns a separate Sql, PRNG, request
slots, pool, statement cache, and row storage. CPU pinning uses the public
cluster policy; effective per-thread affinities are retained. No shared SQL
pool, fake data, response cache, or driver replacement is introduced.

HTTP uses HTTP/1.1 keep-alive, one request per connection at a time, no HTTP
TLS, and no response compression. The `all` selection measures `/db`,
`/queries?count=20`, and `/updates?count=20`; `db` selects the single-query
route for scaling runs. Exact generated HTTP requests and representative
wire responses are retained. Dynamic World response values are not claimed
to be constant across requests. Nonzero HTTP/socket/timeout errors invalidate
the run. A valid run may still fall below the release throughput target.

The separate direct-query probe uses one worker, eight SQL connections,
16 caller-owned in-flight requests, 1,024 warmup queries, and 16,384 measured
queries per sample. It binds `id=1` against the real World table and validates
the binary row. The probe records every query's submission-to-completion time
and submission-to-assignment-trace time in nanoseconds. The latter is an
upper bound on pool wait that also includes admission/parameter-encoding and
trace overhead; it is not claimed to isolate only time inside the FIFO.
Nearest-rank p50, p99, p99.9, and maxima are checked independently from the
raw CSV. Clock and trace observation are benchmark overhead, not production
query instrumentation enabled by default.

Process CPU and RSS are sampled every 100 ms. One-worker process RSS is the
one-worker cohort's resident footprint; a cluster RSS is aggregate shared
process memory and is never divided into invented per-thread RSS values.
Peak sampled RSS is labeled as sampled, not an exact lifetime high-water
mark. `/proc` descriptor snapshots identify io_uring or epoll, and listener
ownership is checked against the child process before loading it.

## Reproduction

Install Zig 0.16.0, wrk, curl, Python 3, and normal Linux process tools. These
are benchmark tools; no new tool is required to build the SQL library.
Supply a seeded PostgreSQL database using [`../examples/sql/world.sql`](../examples/sql/world.sql).
Set `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, and `PGPASSWORD` through the
environment. Set `PGSSLROOTCERT` and `PGSSLSERVERNAME` for verified database
TLS; recorded TLS measurements require non-development credentials. For a
separate isolated plaintext development cohort, omit the CA path and set
`UWZ_SQL_ALLOW_PLAINTEXT=1` explicitly.

Record `UWZ_SQL_PG_VERSION`, immutable `UWZ_SQL_PG_IMAGE`, load-generator source
URL `UWZ_WRK_SOURCE`, and its UTC retrieval time `UWZ_WRK_RETRIEVED_AT`.
`UWZ_ZIG_RETRIEVED_AT` records the toolchain retrieval time. Preinstalled
system tools retain OS package versions; unknown historical retrieval times
are stated as unavailable instead of invented.
`UWZ_ZIG` and `UWZ_WRK` can select locally extracted executables. Credentials
are inherited by the child and excluded from every retained metadata file.

```sh
sh scripts/benchmark_sql.sh /tmp/sql_one_worker 1 all
sh scripts/benchmark_sql.sh /tmp/sql_four_workers 4 db
sh scripts/benchmark_sql.sh /tmp/sql_eight_workers 8 db
sh scripts/benchmark_sql.sh /tmp/sql_twelve_workers 12 db
```

Each output directory must start empty. The harness builds ReleaseFast
artifacts, records their hashes, checks server startup and shutdown, retains
raw wrk/probe/resource output, and writes `summary.json` without hand edits.
It captures the commit, tracked binary patch, untracked-file checksums, and a
source archive containing the native benchmark's build inputs. Build-input
checksums are compared before and after the workload; concurrent code or
harness changes invalidate the run. Documentation-only edits are recorded in
the status snapshots and do not change the measured binary.
The `passed` run status means collection and validation succeeded, while
`local_target_met` separately records the unchanged throughput comparison.

Recordings under `benchmarks/results/` follow the repository artifact rule:
commit a README and checksum manifest only; keep raw output and the evidence
archive outside the repository. The README records the omitted archive's
SHA-256 and states that clean-clone replay is unavailable. Never commit
credentials, ephemeral private keys, or raw per-sample files.

wrk's timing units and scripting contract are defined in its
[versioned SCRIPTING reference](https://github.com/wg/wrk/blob/4.1.0/SCRIPTING).
