# PostgreSQL plan policy under local async-db load, 2026-11-19

**Forcing generic plans raised median throughput from 51,741.211 to 60,778.695
requests/s.** Throughput rose in all three pairs, PostgreSQL cgroup CPU per
completed response fell from 258.570 to 193.887 µs, and median HTTP p99 fell
from 35.820 to 29.532 ms. This is the net local effect of a temporary
PostgreSQL role/database policy. The production SDK and default policy are
unchanged. Both profiles fell short of the target above 300,000 requests/s.
R2 remains open.

| Pair | `auto` requests/s | `force_generic_plan` requests/s | Throughput change | PostgreSQL CPU/response change |
| --- | ---: | ---: | ---: | ---: |
| 1 | 51,965.841 | 60,664.775 | +16.740% | −24.957% |
| 2 | 51,741.211 | 60,778.695 | +17.467% | −25.016% |
| 3 | 51,580.422 | 61,169.630 | +18.591% | −25.148% |

| Timed metric | `auto` median | `force_generic_plan` median |
| --- | ---: | ---: |
| HTTP p50 | 19.123 ms | 16.308 ms |
| HTTP p90 | 27.071 ms | 23.190 ms |
| HTTP p95 | 29.883 ms | 25.275 ms |
| HTTP p99 | 35.820 ms | 29.532 ms |
| Application cgroup CPU/response | 110.011 µs | 105.500 µs |
| PostgreSQL cgroup CPU/response | 258.570 µs | 193.887 µs |
| wrk process CPU/response | 37.410 µs | 35.253 µs |

The cgroup snapshots bracket each wrk invocation and GNU time measures the
client process. CPU ratios divide by completed responses in that invocation.
CPU time sums across cores. The measurements establish a net policy effect on
this workload. Isolated planner CPU time and policy-matched SDK query latency
were unmeasured. This was a shared development host and a local reconstruction
of HttpArena async-db. Official acceptance remains outstanding.

## Policy and workload

Both profiles used the same exact SDK executable, prepared query, parameter
types and connection budget. They used one cached PostgreSQL 18.6 cluster
without PGss instrumentation, the unmodified 100,000-row seed, and the same
8,237-row comparison export. A guarded helper reset `plan_cache_mode` for
`bench` in `benchmark` to inherit `auto` or set the scoped override to
`force_generic_plan`. The helper checked the full owned container ID and nonce,
required zero TCP clients before each change, and verified inherited setting,
source, reset value and role catalog. Each fresh app reached 256 PostgreSQL
TCP sessions with zero TLS sessions. The postmaster and the observed
autoanalyze, autovacuum, analyze and vacuum timestamps and counts stayed the
same through the probes and measured cases.

Each case used 32 application workers, 1,024 loopback HTTP/1.1 connections
with pipeline depth one, and eight wrk threads. Requests rotated
`GET /async-db?min=10&max=50&limit=N` through limits 5, 10, 20, 35 and 50.
Each timed case had a 5-second warmup and nominal 10-second measurement. Pair
one and pair three started with `auto`. Pair two started with generic.

The off-window probes prepared the same query with three `int4` parameters.
They issued five `EXPLAIN (FORMAT JSON) EXECUTE` commands per profile without
`ANALYZE`. All ten plans used a nonparallel `Limit` over `Seq Scan` on `items`.
The `auto` probe session recorded five custom and zero generic plans. The
`force_generic_plan` probe session recorded five generic and zero custom
plans. These counts describe only the two standalone probe sessions. App
session plan-choice counts were unmeasured.

## Validation and restoration

Both fixed cases returned 50 HTTP 200 responses with exact typed PostgreSQL
values and unique IDs. The raw bodies matched byte-for-byte across policies for
each limit. Each fixed case recorded exactly 50 renders and sequential scans.
All timed and warmup samples reported zero wrk connect, read, write and timeout
errors and zero statuses at or above HTTP 400. App fallback and rejection
counts and index-scan deltas were zero. Render counts equaled sequential-scan
deltas and exceeded warmup-plus-timed client completions by 2,009 to 2,034,
within the two-cutoff allowance of 2,048. All eight application containers
exited cleanly and were removed.

`final_restore.json` records the final `RESET` on the owned cluster. A fresh
login then showed `auto`, source `default`, reset value `auto`, an empty
role settings catalog for the policy and zero TCP clients. Cleanup removed
the owned database container and transient private inputs. The bounded
producer check found zero exact password matches in 981 named public files.
A `perf stat` availability probe on an owned no-op child returned exit 1
under `perf_event_paranoid=4` with no effective capabilities. No other
process was sampled and host permissions stayed unchanged.

## Archive and offline verification

[The raw archive](raw_evidence_archive.tgz) includes the single exact server
ELF, wrk ELF and package, runtime library identities, the owned fixture and
policy helpers, both off-window probes, policy snapshots and restore proof,
raw HTTP/CPU/database records, and the offline checker and its 12 tests.
Server SHA-256 is
`836f823e81f6d8fd7242dfc5b3910ceb6d72930bc7a115c05aff01c79e09989b`.
The 346 packaged source files match the original build input and the current
measurement source. The original build record documents the Zig 0.16.0
static musl `ReleaseFast` native-CPU executable. [Original local throughput evidence](../../sql_httparena_local_v1/2026_11_18/README.md)

From this result directory, use Python 3.11+ to recompute the archive's
results offline. The verifier checks file modes and hashes, source and build
identities, probes and exact role policy, final reset and cleanup, and all
eight raw cases.

```sh
sha256sum -c manifest.sha256
mkdir extracted
tar -xzpf raw_evidence_archive.tgz -C extracted
python3 -B extracted/sql_plan_policy_v1_2026_11_19/verify_bundle.py
```

## Local replay

Use a Linux x86-64 host supporting the archived native Broadwell CPU
instructions, with Docker, cgroup v2, readable host PID
statistics and cgroup identity, container time namespace offsets, GNU time,
`readelf`, Python 3.11+, and the wrk runtime libraries in
`tooling/wrk_libraries.txt`. The pinned PostgreSQL image must already be cached.
The fixture and runtime use `--pull=never`. Use the exact archived ELFs. The
replay waits for the seeded table's initial automatic maintenance, runs both
probes, restores `auto` before measurements, and applies a final reset before
owned-fixture cleanup.

```sh
archive="$PWD/extracted/sql_plan_policy_v1_2026_11_19"
(
    set -eu
    replay="$PWD/replay_run"
    mkdir "$replay" "$replay/preflight"
    cp -a "$archive/archived_fixture" "$archive/runner" "$replay/"
    cp -p "$archive/setup_fixture.py" "$archive/cleanup_fixture.py" "$archive/policy.py" "$replay/"
    fixture="$replay/fixture.json"
    policy="$replay/policy.py"
    cleanup() {
        cleanup_status=0
        if [ -f "$replay/private/owner_token" ]; then
            if [ -f "$fixture" ]; then
                python3 "$policy" apply --mode auto --fixture "$fixture" \
                    --output "$replay/final_restore.json" || cleanup_status=1
            fi
            python3 "$replay/cleanup_fixture.py" || cleanup_status=1
        fi
        return "$cleanup_status"
    }
    trap cleanup EXIT
    python3 "$replay/setup_fixture.py"
    remaining=90
    while :; do
        python3 "$policy" snapshot --mode auto --fixture "$fixture" \
            --output "$replay/preflight/maintenance.json"
        if python3 - "$replay/preflight/maintenance.json" <<'PY'
import json
from pathlib import Path
import sys

stats = json.loads(Path(sys.argv[1]).read_text())['snapshot']['statistics']
ready = stats['autoanalyze_count'] > 0 and stats['autovacuum_count'] > 0
raise SystemExit(0 if ready else 1)
PY
        then
            break
        fi
        remaining=$((remaining - 1))
        test "$remaining" -gt 0
        sleep 2
    done
    auto_probe="$replay/preflight/auto_probe.json"
    generic_probe="$replay/preflight/force_generic_plan_probe.json"
    python3 "$policy" probe --mode auto --fixture "$fixture" --output "$auto_probe"
    python3 "$policy" apply --mode force_generic_plan --fixture "$fixture" \
        --output "$replay/preflight/force_generic_plan_apply.json"
    python3 "$policy" probe --mode force_generic_plan --fixture "$fixture" --output "$generic_probe"
    python3 "$policy" apply --mode auto --fixture "$fixture" \
        --output "$replay/preflight/auto_apply.json"
    run="$replay/run_01"
    python3 "$replay/runner/measure.py" --binary "$archive/install/bin/sql_httparena" \
        --wrk "$archive/tooling/root/usr/bin/wrk" --app-env "$replay/private/app.env" \
        --fixture "$fixture" --policy "$policy" --auto-probe "$auto_probe" \
        --generic-probe "$generic_probe" --output "$run"
    python3 -B "$archive/verification/verify.py" "$run" --items "$replay/fixture/expected_items.jsonl" \
        --fixture "$fixture" --binary "$archive/install/bin/sql_httparena" --wrk "$archive/tooling/root/usr/bin/wrk" \
        --lua "$replay/runner/async_db.lua" --policy "$policy" --auto-probe "$auto_probe" --generic-probe "$generic_probe"
)
```
