# Scoped SQL diagnostic follow-up, 2026-11-11

These diagnostics follow the local-v1 retained load cohort. They use the exact
same ReleaseFast server executable and task-owned PostgreSQL container; the
server checksum is retained. They are shared-host observations, not official
HttpArena acceptance. The unchanged target above 300,000 RPS remains unmet.

The root agent held other project builds throughout this window. Unrelated
host work was neither stopped nor controlled. Each untraced cohort uses four
wrk threads, 16 HTTP connections per application worker, two warmup seconds,
and one 20-second `/db` sample. Process counters are sampled about every 200 ms
over the load interval. The bounded PostgreSQL sampler runs for 22 seconds,
including approximately two seconds after the load. Its percentages describe
backend observations across that full window, not exact query execution time.

| Workers | RPS | Application CPU | PostgreSQL CPU | wrk CPU | Host idle | Host softirq |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 101,412.25 | 505.32% | 722.26% | 227.80% | 10.76% | 18.81% |
| 12 | 113,011.54 | 611.86% | 803.11% | 256.52% | 5.74% | 20.96% |

Process CPU uses kernel clock-tick deltas divided by the observed interval;
100% is one logical CPU. Host percentages describe all 28 logical CPUs.
The 12-worker application splits into 129.82% user and 482.04% system CPU;
PostgreSQL splits into 429.04% user and 374.08% system; wrk splits into 37.88%
user and 218.64% system. Host steal is zero. Aggregate host load rises during
the run; raw load/CPU-pressure snapshots are retained. These system counters
are not additive attribution of all kernel work to individual processes.

At 12 workers, 87.37% of PostgreSQL backend observations are idle/ClientRead,
2.79% active/ClientRead, and 9.84% have no reported wait. No lock or I/O waits
are sampled. Database counter deltas show zero blocks read, rollbacks and
deadlocks. PostgreSQL cumulative statistics can flush after a delay; these
deltas are diagnostic context, not an exact HTTP-to-transaction reconciliation.
The data is already cached, and the test database uses tmpfs.

Application worker samples include 241 `io_cqring_wait` observations among
984 worker-thread observations at 12 workers; the supervisor's 82 futex waits
are separate. A zero wait-channel value is retained as reported and does not
prove a thread was running. Thread CPU masks and scheduler-switch deltas are
in `samples.jsonl` and `summary.json`. PostgreSQL CPU includes only processes
enumerated from `docker top` for the owned container after warmup; it excludes
the subsequently created read-only sampler backend.

The measured costs point to kernel/network/scheduling work on the co-located
CPU as a substantial scaling limit. The evidence does not identify one
application function as the sole bottleneck, exclude short unsampled database
waits, or prove that a particular optimization will achieve the release bar.
The four-thread generator uses 256.52% CPU at 12 workers; these results do not
demonstrate saturation of all four generator threads. PostgreSQL uses Docker
bridge networking through the published loopback port, as recorded separately.

## Syscall trace comparison

A separate 12-worker run launches only the owned application under
`strace -f -c`. It reaches 62,411.00 RPS and retains zero HTTP errors. Tracing
substantially perturbs scheduling and throughput. The summary covers startup,
two-second warmup, 20-second load, and clean shutdown, and counts 1,372,129
`sendmsg` calls and 345,175 `io_uring_enter` calls. Those calls account for
59.79% and 26.16% of tracer-attributed syscall elapsed time. That time is an
aggregate of traced calls across threads, including waits; it is not CPU time
or a function-level CPU profile. The observed syscall volume narrows the next
transport investigation without proving the cost of one call in normal load.

`perf stat -e task-clock,context-switches,cycles,instructions -- true` fails
with exit 1 because `perf_event_paranoid=4` and required capabilities are
unavailable. The exact diagnostic is retained in `perf_probe.txt`. No kernel
settings were changed and no hardware-counter profile is claimed.

## Reproduction and scope

`harness/profile_sql.py` is the exact bounded diagnostic helper. It uses only
the Python standard library, the previously retained executable and Lua load
script, wrk, Docker/psql, ss and strace. The original launch was:

```sh
. /tmp/uwz-v230-postgres.env
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER="$POSTGRES_USER"
export PGDATABASE="$POSTGRES_DB" PGPASSWORD="$POSTGRES_PASSWORD"
export UWZ_SQL_ALLOW_PLAINTEXT=1
export LD_LIBRARY_PATH=/tmp/uwz-sql-perf-tools/usr/lib/x86_64-linux-gnu
unset PGSSLROOTCERT
python3 /tmp/uwz-profile-sql.py /tmp/uwz_sql_diagnostic_v1
python3 /tmp/uwz-summarize-sql-profile.py /tmp/uwz_sql_diagnostic_v1
```

The helper records command arguments, validates owned listener PIDs, samples
only its server/wrk and container PostgreSQL PIDs, and queries grouped database
wait states without retaining query text. It terminates only its own children.
Credentials are supplied by the external fixture environment and are absent
from this archive. Exact input/binary/tool provenance is in the preceding
local-v1 archive; this archive adds the non-secret bridge/cgroup configuration.
Adjust the explicitly named tool/input/container paths when reproducing on a
different isolated host, while retaining the same workload and thresholds.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `5788bad97b6e8cf18661d8c5c4761010687a8c78e7ad36a705f307c881c0ae3c`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
