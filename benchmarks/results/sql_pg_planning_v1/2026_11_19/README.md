# PostgreSQL planning and execution under local async-db load, 2026-11-19

**The diagnostic profile recorded 1,392,567 PostgreSQL planner invocations and
1,392,567 completed calls across its three timed phases.** The planner and
executor hooks averaged 152.748 µs and 279.867 µs per completed call,
respectively. Observed throughput and PostgreSQL CPU per response differed
beyond normal-run variation, so these timings apply to the diagnostic profile.
The normal profile measured 48,079.013 requests/s. The target above 300,000
requests/s remains unmet and R2 remains open.

## Server-side measurements

The production SDK used its existing named prepared statement. The diagnostic
monitor collected the one matching top-level parameterized `items` query from
`pg_stat_statements` 1.12, filtered by database and role. Each phase value is
the difference between quiescent PostgreSQL snapshots bracketing the client
invocation. It includes work completed around the client cutoff. The counts
show repeated planner-hook invocations even with the existing prepared
statement. They leave custom and generic plan selection unresolved.

| Diagnostic phase, summed across three samples | Plans | Calls | Planner elapsed total | Executor elapsed total | Planner µs/call | Executor µs/call |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Warmup | 713,929 | 713,161 | 109,760.182 ms | 198,364.743 ms | 153.907 | 278.149 |
| Timed | 1,392,567 | 1,392,567 | 212,711.206 ms | 389,733.287 ms | 152.748 | 279.867 |

The timed planner total was 35.3% of the **sum of the two hook elapsed totals**.
The hooks aggregate elapsed time across concurrent queries. These totals and
per-call means cover hook boundaries only. PostgreSQL CPU, full protocol and
SDK latency, and per-query percentiles are separate measures. Each warmup
recorded 256 more plans than calls. Startup, between-load and shutdown gaps
had zero deltas for plans, calls, rows, buffers and hook times in all
three samples. The original archive retained the per-phase and gap records.

## Paired normal and diagnostic profiles

Both profiles used the exact same production binary. Each used 32 application
workers, 256 plaintext PostgreSQL TCP sockets and 1,024 loopback HTTP/1.1
connections at pipeline depth one. Eight wrk threads rotated
`GET /async-db?min=10&max=50&limit=N` through limits 5, 10, 20, 35 and 50.
Timed cases used a 5-second warmup and nominal 10-second measurement. The
first and third pairs started with normal, and the second with diagnostic.
The app, databases and client shared a development host. The inactive database
used at most 6,452 µs of cgroup CPU in a timed sample.

| Pair | Normal requests/s | Diagnostic requests/s | Diagnostic throughput change | Diagnostic PostgreSQL CPU/response change |
| --- | ---: | ---: | ---: | ---: |
| 1 | 48,232.370 | 48,879.721 | +1.342% | +0.912% |
| 2 | 46,695.209 | 44,183.440 | −5.379% | +3.390% |
| 3 | 48,079.013 | 45,069.436 | −6.260% | +3.359% |

| Timed metric | Normal median | Diagnostic median |
| --- | ---: | ---: |
| Requests/s | 48,079.013 | 45,069.436 |
| HTTP p50 | 20.567 ms | 22.051 ms |
| HTTP p90 | 29.100 ms | 31.924 ms |
| HTTP p95 | 31.939 ms | 35.043 ms |
| HTTP p99 | 38.026 ms | 41.414 ms |
| Application cgroup CPU per completed response | 111.421 µs | 112.757 µs |
| PostgreSQL cgroup CPU per completed response | 265.112 µs | 273.288 µs |
| wrk process CPU per completed response | 37.888 µs | 37.872 µs |

Two paired throughput decreases exceeded the observed range of the three
normal samples. PostgreSQL CPU per response rose in all three pairs. This
was configuration-level diagnostic perturbation. The two independently
seeded clusters used byte-identical dataset exports and equivalent off-load
plan shapes and costs. Each cluster autoanalyzed once at a different recorded
time. Live planner statistics contents were unmeasured, as was isolated hook
overhead. The hook measurements apply to the tracked configuration only.

## Fixture and correctness

Both fixtures used the cached, immutable PostgreSQL 18.6 image and the
unchanged 100,000-row seed. The 8,237 matching rows exported byte-identically.
Normal used `compute_query_id=auto`, no preload library and no PGss settings.
Diagnostic used `compute_query_id=on`, preloaded `pg_stat_statements` and set
`track=top`, `track_planning=on`, `track_utility=off` and `save=off`. The PGss
`max` value remained at its default of 5,000. The settable differences were
those settings. Read-only derived shared memory increased from 161 to 163 MB
and the corresponding huge page count from 81 to 82.

The extension was installed only in the diagnostic `postgres` monitoring
database. The diagnostic epoch was initialized before any measurement and
with zero TCP clients. The first quiescent diagnostic fixed-case snapshot
matched the empty target, database and role OIDs, reset timestamp and zero
statement deallocations recorded at preparation. The verifier checks these
identities along with the exact profile settings and all subsequent records.

Each fixed case issued 50 requests and returned 50 HTTP 200 responses with
exact typed values and unique IDs matching PostgreSQL. Render counts matched
sequential-scan deltas. Diagnostic fixed calls also matched the 50 scans.
Across both phases of every timed case, wrk reported zero connect, read,
write or timeout errors and zero statuses at or above HTTP 400. Fallback,
reject and index-scan deltas were zero. The warmup-plus-timed render excess
was between 2,001 and 2,033, within the two-cutoff bound of 2,048. All eight
application containers exited cleanly. Both database containers and their
private inputs were removed after ownership and zero TCP clients were checked.
The bounded producer check found zero exact matches for either generated
password across the 1,601 named public files it checked.

## Archive and offline verification

The raw archive (omitted raw evidence archive) includes both fixtures, the exact
server and wrk ELFs, the wrk package and runtime-library identities, all
monitor preparation and settings proofs, and the raw phase, gap, CPU, HTTP and
cleanup records. The identical server SHA-256 for both profiles is
`836f823e81f6d8fd7242dfc5b3910ceb6d72930bc7a115c05aff01c79e09989b`.
The original archive included its original Zig 0.16.0 static musl ReleaseFast build
record and all 346 package source files. Their Git blob identities match the
source in the measurement workspace. No new server build was used.
[Original local throughput evidence](../../sql_httparena_local_v1/2026_11_18/README.md)

From this result directory, verify checksums and extract with modes preserved.
The verifier requires Python 3.11+ and runs offline. It checks source and tool
identities, exact fixture GUCs and diagnostic epoch before recomputing the raw
results. The archive also includes 11 focused verifier tests.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

## Local replay

Use a compatible Linux x86-64 host with Docker, cgroup v2, readable host PID
statistics and cgroup identity, container time namespace offsets, GNU time,
`readelf`, and Python 3.11+. The host needs the wrk runtime libraries listed in
`tooling/wrk_libraries.txt` and the pinned PostgreSQL image in the Docker cache.
The helpers use `--pull=never`. Use the exact server and client binaries from the archive.
The server was built with `-Dcpu=native` and requires a compatible CPU
instruction set.
The procedure prepares the monitor before it creates the measurements
directory. It runs the owned-fixture cleanup for both profiles when the shell
exits.

```sh
archive="$PWD/extracted/sql_pg_planning_v1_2026_11_19"
(
    set -eu
    replay="$PWD/replay_run"
    mkdir "$replay"
    cp -a "$archive/runner" "$replay/"
    cp -p "$archive/monitor.sql" "$archive/prepare_monitor.py" "$archive/verify_profiles.py" "$replay/"
    for profile in normal diagnostic; do
        fixture="$replay/fixtures/$profile"
        mkdir -p "$fixture"
        cp -a "$archive/fixtures/$profile/archived_fixture" "$fixture/"
        cp -p "$archive/fixtures/$profile/setup_fixture.py" "$archive/fixtures/$profile/cleanup_fixture.py" "$fixture/"
    done
    cleanup() {
        cleanup_status=0
        for profile in normal diagnostic; do
            fixture="$replay/fixtures/$profile"
            if [ -f "$fixture/private/owner_token" ]; then
                python3 "$fixture/cleanup_fixture.py" || cleanup_status=1
            fi
        done
        return "$cleanup_status"
    }
    trap cleanup EXIT
    normal="$replay/fixtures/normal"
    diagnostic="$replay/fixtures/diagnostic"
    python3 "$normal/setup_fixture.py"
    python3 "$diagnostic/setup_fixture.py"
    python3 "$replay/verify_profiles.py" --fixtures "$replay/fixtures" \
        --output "$replay/preflight/profile_settings_comparison.json"
    python3 "$replay/prepare_monitor.py" --fixture "$diagnostic/fixture.json" \
        --monitor "$replay/monitor.sql" --run-root "$replay" \
        --output "$replay/preflight/prepared_monitor.json"
    mkdir "$replay/measurements"
    run="$replay/measurements/run_01"
    python3 "$replay/runner/measure.py" --binary "$archive/install/bin/sql_httparena" \
        --wrk "$archive/tooling/root/usr/bin/wrk" --pgss-sql "$replay/monitor.sql" \
        --normal-fixture "$normal/fixture.json" --normal-app-env "$normal/private/app.env" \
        --diagnostic-fixture "$diagnostic/fixture.json" --diagnostic-app-env "$diagnostic/private/app.env" \
        --output "$run"
    python3 -B "$archive/verification/verify.py" "$run" \
        --normal-fixture "$normal/fixture.json" --normal-items "$normal/fixture/expected_items.jsonl" \
        --diagnostic-fixture "$diagnostic/fixture.json" --diagnostic-items "$diagnostic/fixture/expected_items.jsonl" \
        --pgss-sql "$replay/monitor.sql" --binary "$archive/install/bin/sql_httparena" \
        --wrk "$archive/tooling/root/usr/bin/wrk" --lua "$replay/runner/async_db.lua"
)
```

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `15d48495dfdeddd8ffead5dfc69e8c829a728d447614544b4dc3cdf87d4b7ba9`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
