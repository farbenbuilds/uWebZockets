# SQL pool dispatch experiment, 2026-11-19

**The pool dispatch optimization was rejected and reverted.** The three pairs
showed no consistent throughput or application CPU gain beyond observed
variation, and candidate HTTP p99 was worse in two pairs. The production pool
source was restored byte-for-byte. The candidate is retained as evidence only.
The target above 300,000 requests/s remains unmet and R2 remains open.

The candidate returned early for an empty waiter queue, expired waiters before
admission as before, and acquired an idle lease before searching for the oldest remaining
waiter. It used the same SQL, route and pool sizes as the control. This local
HttpArena async-db reconstruction ran on a shared development host. The exact
control executable comes from the earlier local throughput run.
[Local throughput evidence](../../sql_httparena_local_v1/2026_11_18/README.md)

## Paired result

| Pair | Control requests/s | Candidate requests/s | Throughput change | App CPU/response change | HTTP p99 change |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 47,743.663 | 48,072.433 | +0.689% | −0.154% | +1.130% |
| 2 | 47,398.865 | 48,980.446 | +3.337% | −0.729% | −6.872% |
| 3 | 47,982.294 | 47,626.679 | −0.741% | +0.059% | +1.471% |

| Timed metric | Control median | Candidate median |
| --- | ---: | ---: |
| Requests/s | 47,743.663 | 48,072.433 |
| HTTP p50 | 20.814 ms | 20.590 ms |
| HTTP p90 | 29.308 ms | 28.992 ms |
| HTTP p95 | 32.151 ms | 31.826 ms |
| HTTP p99 | 38.056 ms | 38.013 ms |
| App cgroup CPU per completed response | 111.368 µs | 110.950 µs |
| App process CPU per completed response | 111.355 µs | 110.952 µs |
| PostgreSQL cgroup CPU per completed response | 265.153 µs | 264.873 µs |
| wrk process CPU per completed response | 37.810 µs | 37.646 µs |

App cgroup CPU per response ranged from 111.121 to 111.370 µs for the control
and 110.558 to 111.434 µs for the candidate. Changes in throughput and CPU
varied in direction across the pairs. The cgroup snapshots bracket each wrk
subprocess, application PID statistics retain user and system ticks, and GNU
time records client CPU. Ratios use completed responses in the corresponding
full wrk run. CPU seconds sum across cores. These observations leave the
throughput limit unattributed. This experiment measured HTTP latency and CPU.

## Workload and checks

Each application case used 32 workers and 256 plaintext PostgreSQL TCP sockets.
Eight wrk threads used 1,024 loopback HTTP/1.1 connections with pipeline depth
one. Requests rotated `GET /async-db?min=10&max=50&limit=N` across limits 5, 10,
20, 35 and 50. Each timed case had a 5-second warmup and nominal 10-second
measurement. Pairs one and three ran the control first. Pair two ran the
candidate first. The cached PostgreSQL 18.6 fixture used the unchanged 100,000
item seed and the 8,237 matching rows as the typed comparison export.

Each fixed case produced 50 HTTP 200 responses with exact typed values and
unique item IDs matching the PostgreSQL export. Each also recorded 50 renders
and sequential scans. Across all six timed cases both phases had zero wrk
socket or timeout errors and zero statuses at or above HTTP 400. App fallbacks
and rejections were zero. Render counts equaled PostgreSQL sequential-scan
deltas with zero index-scan deltas. The excess over warmup-plus-timed client
completions ranged from 2,022 to 2,033, within the 2,048 bound for outstanding
work at the two client cutoffs. All eight app containers exited and were removed.

The candidate build completed 18 of 18 steps. All five focused pool tests passed.
The ordinary unit run on the candidate passed 1,175 of 1,182 tests and skipped
seven because TLS and alternate-credential fixtures were unavailable. Its
exit status was zero. The raw stderr includes libxev io_uring `ECANCELED`
(errno 125) diagnostics. The ordinary unit run used a separate `uwz_test`
role and database on the owned PostgreSQL cluster before the benchmark. The
benchmark schema, seed, settings and user stayed the same. The paired runner
targeted `benchmark`, and `uwz_test` was removed with the owned container.
The cleanup record follows an observation of zero remaining TCP consumers.

## Evidence and offline verification

The raw archive (omitted raw evidence archive) includes exact ELFs, the wrk ELF and
Ubuntu package, fixture inputs, build and test records, all raw pair logs and
resource snapshots, and the recorded decision and cleanup. The control ELF
SHA-256 is `836f823e81f6d8fd7242dfc5b3910ceb6d72930bc7a115c05aff01c79e09989b`.
The frozen candidate ELF SHA-256 is
`3b64d0a84a8debcc8f3f1ebf875ef9dd170d258293a9f87657e0a51c5adbb784`.
Both are static musl `x86_64` `ReleaseFast` builds with native CPU targeting.
The 346 package source files match the normal source except for the tested
pool change and the isolated benchmark build step. `parent_source/` holds the
original versions of those two files. `source_delta.json` binds the tested
edits, original source and candidate ELF. The bounded producer comparison
checked 888 named public files for the exact fixture password before deleting
the private inputs and found zero matches.

From this result directory, use an empty extraction directory. The verifier
checks file modes and hashes, reconstructs the baseline source identity,
revalidates the fixed bodies and derives per-case CPU, HTTP and paired results
from the raw observations. It uses Python 3.11+ and runs offline.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

## Local replay

Use a compatible Linux x86-64 host with Docker, GNU time, `readelf`, Python
3.11+, the runtime libraries listed for wrk in `tooling/wrk_libraries.txt`,
and the cached PostgreSQL image pinned in `archived_fixture/image.txt`.
Replay requires cgroup v2, host-readable application and PostgreSQL PID
`stat` and `cgroup` records, and container time-namespace offsets. The exact
server ELFs require the producer's native CPU instruction set. The runtime
uses `--pull=never`.
The commands below require the two exact archived server ELFs. Start from the
result directory after extraction. A fresh replay root keeps its generated
fixture and transient private inputs separate from the retained evidence.

```sh
archive="$PWD/extracted/sql_pool_dispatch_v1_2026_11_19"
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
        --control "$archive/baseline/install/bin/sql_httparena" \
        --candidate "$archive/install/bin/sql_httparena" \
        --wrk "$archive/tooling/root/usr/bin/wrk" \
        --app-env "$replay/private/app.env" --fixture "$replay/fixture.json" \
        --output "$replay/run_01"
    python3 -B "$archive/verification/verify.py" "$replay/run_01" \
        --items "$replay/fixture/expected_items.jsonl" --fixture "$replay/fixture.json" \
        --control "$archive/baseline/install/bin/sql_httparena" \
        --candidate "$archive/install/bin/sql_httparena" \
        --wrk "$archive/tooling/root/usr/bin/wrk" --lua "$replay/runner/async_db.lua"
)
```

The replay writes measurements for its own host. The archived candidate build
command is in `build/result.json`. To inspect the normal source, copy `source/`
and overlay `parent_source/` in that copy. A rebuilt control has a separate
identity from the exact archived control pinned by the checker.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `8afffd9ec6425d7e474b5a43df4fb3a2d012254201fdac1440fda97441b401da`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
