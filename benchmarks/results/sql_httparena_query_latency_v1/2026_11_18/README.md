# Local HttpArena async-db query latency, 2026-11-18

**The median p99 total SDK query latency under active HTTP load was 36.045 ms.**
The paired uninstrumented control measured 49,275.733 requests/s at 38.234 ms
p99 HTTP latency. The target above 300,000 requests/s remains unmet and R2
remains open. These measurements come from a local reconstruction on a shared
development host. Official and quiet-host measurements remain outstanding.
The exact control executable comes from the earlier local throughput run.
[Local throughput evidence](../../sql_httparena_local_v1/2026_11_18/README.md)

## SDK timing under load

The instrumented copy records monotonic nanoseconds immediately before the
adapter calls `Db.query`, at `Db.assign` entry before encoding and transport,
and at the adapter callback entry before token inspection and JSON rendering.
The three intervals cover SDK admission, SDK service after assignment, and
the entire SDK query. Assigned service includes encoding, transport,
PostgreSQL work and result reception. PostgreSQL engine execution under load
was unmeasured. The retained PostgreSQL `EXPLAIN` timings ran off load.
Client-side HTTP timings cover the full request and response.

| SDK interval | Boundaries | p50 | p90 | p95 | p99 |
| --- | --- | ---: | ---: | ---: | ---: |
| Admission, including submission bookkeeping | Submit to assign | 14.430 ms | 20.861 ms | 22.938 ms | 27.068 ms |
| Assigned SDK service | Assign to callback | 4.093 ms | 9.495 ms | 11.539 ms | 15.950 ms |
| Total SDK query | Submit to callback | 19.112 ms | 27.497 ms | 30.224 ms | 36.045 ms |

Each column is the median of three per-sample nearest-rank percentiles. A
successful record contributes only if submission, assignment, and callback
all fall inside the closed timed active-load window. The SDK windows are
trimmed inside each wrk process. A window starts at the latest second-request
hook across the eight client threads. It ends at the earliest of the latest
observed late hook, the time before process spawn plus nominal test duration,
and the combined wrk completion hook. Late hooks use request 20,000 per
thread in warmup and 40,000 in the timed phase. At least one late hook is
required. HTTP throughput uses the full reported wrk duration.

| Pair | Timed SDK window | Successful triples inside | Successful records outside |
| --- | ---: | ---: | ---: |
| 1 | 6.586640 s | 325,112 | 416,018 |
| 2 | 6.566471 s | 325,914 | 424,162 |
| 3 | 6.519299 s | 324,955 | 410,169 |
| Total | | 975,981 | 1,250,349 |

The three instrumented timed cases recorded 2,226,330 successful callbacks
across their full lifetimes. Warmup, lead and tail periods, and boundary
crossings appear in the raw classifications. Of the records excluded from timed
percentiles, 2,295 crossed the timed start and 2,901 crossed the timed end.
There were zero failed callbacks, immediate submission failures, unassigned
completions, clipped records, pending records at dump, invalid orders,
duplicate assignment or completion observations, or unexpected assignments.
This is an active-window latency distribution for fully contained successes.

## Matched HTTP controls

Each fresh case used 32 application workers, 256 plaintext PostgreSQL TCP
sockets, and 1,024 loopback HTTP/1.1 connections with pipeline depth one.
Eight wrk threads rotated `GET /async-db?min=10&max=50&limit=N` across `N`
values `5, 10, 20, 35, 50`. The cached PostgreSQL 18.6 image was pinned to
`postgres@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42`.
The unchanged seed contains 100,000 items and the comparison export contains
all 8,237 matching rows. The app, PostgreSQL and wrk shared a Linux
7.0.0-43-generic host with 28 logical CPUs on an Intel Xeon E5-2680 v4.

Each timed case had a 5-second warmup and nominal 10-second timed interval.
The first and third pairs started with the control. The second started with
the instrumented executable.

| Pair | Control requests/s | Instrumented requests/s | Instrumented change from control |
| --- | ---: | ---: | ---: |
| 1 | 50,031.476 | 49,262.351 | −1.537% |
| 2 | 49,275.733 | 49,730.261 | +0.922% |
| 3 | 47,917.941 | 49,135.751 | +2.541% |

| HTTP medians | Requests/s | p50 | p90 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Control | 49,275.733 | 20.152 ms | 29.181 ms | 32.153 ms | 38.234 ms |
| Instrumented | 49,262.351 | 20.012 ms | 28.784 ms | 31.595 ms | 37.363 ms |

The paired throughput differences varied in direction on this host. The
instrumentation reserves worker buffers at startup and touches their pages
as records arrive. The comparison includes first-touch, record writes, clock
reads and the rest of the instrumentation path. The raw resource snapshots
include role-specific CPU and memory observations.

The two fixed cases each produced 50 HTTP 200 responses with exact typed values
and unique IDs matching PostgreSQL, and exactly 50 renders and sequential
scans. The instrumented fixed case also produced 50 fully contained triples.
Across both phases of all six timed cases, wrk reported zero socket and timeout
errors and zero statuses at or above HTTP 400. All app fallback and rejection
counters were zero. App renders equaled PostgreSQL sequential-scan deltas with
zero index-scan deltas. Renders exceeded warmup-plus-timed client completions
by 2,012–2,031, within the 2,048 bound for outstanding work at two client
cutoffs. All eight application containers exited cleanly and were removed.

## Clock evidence and attempt history

Zig's awake timestamps are bracketed by direct Linux `CLOCK_MONOTONIC` reads
at startup and after draining. The successful run bound the containers and
client to the same kernel boot digest and zero monotonic and boottime offsets.
The current and child namespaces agreed within each process. The host view of
application PID time namespace links returned permission error 13. The runner
retained the container-local namespace evidence and full container-ID-to-host
cgroup binding.

`run_01` stopped at preflight because the host and Docker time namespace inodes
differed despite zero offsets. It produced zero HTTP requests, renders and
additional scans. Its command records, raw logs and historical script digests
are retained. The original preflight runner and verifier bytes were not
retained. `run_02` uses the corrected clock proof with the same two server
executables and supplies all reported measurements.

## Archive and verification

The raw archive (omitted raw evidence archive) includes both exact executables,
the wrk ELF and Ubuntu `4.1.0-4build3` package, runtime-library identities,
fixture and runner inputs, the source and build identities, and both attempts.
The instrumented Zig 0.16.0 static musl `ReleaseFast` native-CPU build completed
18 of 18 steps. Its ELF SHA-256 is
`88b6c0afb45f32dccf3e035682d538439f4143c1fef97ec66170a06ffccfae53`.
The normal control ELF SHA-256 is
`836f823e81f6d8fd7242dfc5b3910ceb6d72930bc7a115c05aff01c79e09989b`.

The 346 tracked package source files are included. `parent_source/` supplies
the three original files needed to reconstruct the normal build source and
`instrumentation/` supplies the additional module and its tests. The archive
includes the raw per-worker 40-byte little-endian records, their finalization
metadata, phase markers, app and PostgreSQL observations, and cleanup record.
The owned database container was removed after its TCP consumer count returned
to zero. The experiment's generated password matched none of the 1,342
allowlisted producer files checked before private inputs were deleted.

From this result directory, run the following in an empty extraction location.
The verifier uses Python 3.11+, validates file modes and hashes, checks both
build and workload identities, and derives the timing and throughput results
from raw records. It uses no Docker or network connection.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

## Local replay

Use a compatible Linux x86-64 host with Docker, GNU time, `readelf`, Python
3.11+, the preexisting pinned PostgreSQL image, and the dynamic runtime listed
for wrk. The runner uses `--pull=never`. The exact ELFs use the producer's native
CPU instruction set. To build local equivalents, set `UWZ_ZIG` to the absolute
path of the pinned Zig 0.16.0 binary and `UWZ_ZIG_CACHE` to an absolute cache
path with the pinned dependencies already present. Build offline and keep the
instrumentation module beside the instrumented source directory.

```sh
archive="$PWD/extracted/sql_httparena_query_latency_v1_2026_11_18"
(
    set -eu
    mkdir replay_build
    cp -a "$archive/source" replay_build/instrumented
    cp -a "$archive/instrumentation" replay_build/instrumentation
    cp -a "$archive/source" replay_build/control
    cp -a "$archive/parent_source/." replay_build/control/
    cd replay_build/instrumented
    "${UWZ_ZIG:?set the pinned Zig path}" build install-sql-httparena-evidence \
        -Dsql=true -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl \
        -Dcpu=native -j2 --cache-dir ../instrumented_cache \
        --global-cache-dir "${UWZ_ZIG_CACHE:?set the prepared Zig cache path}" \
        --prefix ../instrumented_install --summary all
    cd ../control
    "$UWZ_ZIG" build install \
        -Dsql=true -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl \
        -Dcpu=native -j2 --cache-dir ../control_cache \
        --global-cache-dir "$UWZ_ZIG_CACHE" --prefix ../control_install --summary all
)
```

To replay with the exact archived binaries, copy the helpers and archived input
fixture into a new directory. The setup helper generates the working fixture
and transient private inputs there. The trap runs the exact-ownership cleanup
at shell exit.

```sh
archive="$PWD/extracted/sql_httparena_query_latency_v1_2026_11_18"
(
    set -eu
    replay="$PWD/replay_run"
    mkdir "$replay"
    cp -a "$archive/archived_fixture" "$archive/runner" "$replay/"
    cp -p "$archive/setup_fixture.py" "$archive/cleanup_fixture.py" "$replay/"
    cleanup() {
        if [ -f "$replay/private/owner_token" ]; then
            python3 "$replay/cleanup_fixture.py"
        fi
    }
    trap cleanup EXIT
    python3 "$replay/setup_fixture.py"
    python3 "$replay/runner/measure.py" \
        --control "${UWZ_REPLAY_CONTROL:-$archive/baseline/install/bin/sql_httparena}" \
        --instrumented "${UWZ_REPLAY_INSTRUMENTED:-$archive/install/bin/sql_httparena}" \
        --wrk "$archive/tooling/root/usr/bin/wrk" \
        --app-env "$replay/private/app.env" --fixture "$replay/fixture.json" \
        --output "$replay/run_02"
    python3 -B "$archive/verification/verify.py" "$replay/run_02" \
        --items "$replay/fixture/expected_items.jsonl"
)
```

The two `UWZ_REPLAY_*` binary variables can select local rebuilds. Each replay
requires a fresh `replay_run` and produces measurements for its own host.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `ef5abffd13d34b23f9c33a34f7ccfbfd33dff2afe09ad898030aab5c6a649ef2`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
