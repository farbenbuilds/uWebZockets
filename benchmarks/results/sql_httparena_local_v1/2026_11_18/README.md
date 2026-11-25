# Local HttpArena async-db reconstruction, 2026-11-18

**The standard cohort measured 48,963.107 requests/s and 38.284 ms p99 HTTP
latency. The target above 300,000 requests/s remains unmet and R2 remains open.**
This was a local reconstruction on a shared development host. Official
HttpArena and quiet-host measurements remain outstanding. The earlier
112,674.14 requests/s result used the World-table `/db` workload. [Earlier local SQL evidence](../../sql_local_v1/2026_11_11/README.md)

| Cohort | App workers | SQL sockets | HTTP connections | wrk threads | Median requests/s | Median p50 | Median p90 | Median p95 | Median p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Standard | 32 | 256 | 1,024 | 8 | 48,963.107 | 20.236 ms | 29.254 ms | 32.216 ms | 38.284 ms |
| Diagnostic | 1 | 8 | 32 | 1 | 14,225.632 | 2.232 ms | 2.624 ms | 2.746 ms | 3.038 ms |

Each cohort had three fresh timed cases with a 5-second warmup followed by a
10-second measured interval. Each table value is the median of its three timed
sample values. Standard timed throughput ranged from 48,698.716 to 49,521.606
requests/s. The host ran Linux 7.0.0-43-generic on an Intel Xeon E5-2680 v4
with 28 logical CPUs. The application, PostgreSQL, and wrk shared the host.

## Workload and validation

The production adapter served loopback HTTP/1.1 with pipeline depth one. wrk
rotated `GET /async-db?min=10&max=50&limit=N` across limits `5, 10, 20, 35, 50`.
The app used plaintext PostgreSQL TCP from an explicit loopback profile. The
cached PostgreSQL 18.6 image was pinned to
`postgres@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42`.
The database used the unmodified official 100,000-row seed. The working fixture
export contains all 8,237 rows matching the price range. The archived adapter
preparation records the workload provenance. [Adapter preparation](../../httparena_adapter_v1/2026_11_11/README.md)

The two fixed-count cases each produced 50 HTTP/1.1 200 responses and matching
PostgreSQL renders and sequential scans. Each body had the exact requested
number of unique IDs, correct byte length, and complete typed values matching
the independent PostgreSQL export by ID. Every warmup and timed sample had
zero wrk socket and timeout errors and zero statuses at or above HTTP 400.
The fixed-count cases establish exact status 200 and typed-body validation.
The Lua rotation counts record generated request shapes. A request hook can
run before completion or at cutoff, so those counts describe generated traffic.

All eight cases had zero app fallbacks and rejections. In every timed case the
settled PostgreSQL sequential-scan delta equaled the app render count. For
`C` client completions across warmup and measurement and `N` concurrent HTTP
connections, the allowed render count was `C <= renders <= C + 2*N`. The upper
bound covers one outstanding request per connection at each of the two client
cutoffs. The observed excesses were `2,020 / 2,025 / 2,030` in the standard
cohort and `63 / 58 / 63` in the diagnostic cohort. All eight application
containers exited zero and were removed. Independent review checked the
retained raw evidence without replaying the benchmark.

The raw snapshots record app and PostgreSQL cgroup CPU and memory, process RSS,
and GNU time data for the client. PostgreSQL accounted for 128.6–130.3 CPU
seconds and the app accounted for 54.4–55.3 CPU seconds per standard timed
sample. CPU seconds sum across cores. HTTP percentiles are end-to-end client
latency. These observations quantify CPU consumption by role and leave the
throughput limit unattributed. SQL execution times were measured only in the
off-load `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)` runs. They ranged from 0.046 to
0.118 ms across the five limits. SQL latency under HTTP load was unmeasured.

## Build and evidence

The normal source build at commit `537ed1d44ed2c2a82979d6dc5b362f66c6db29a8`
completed all 54 steps in 707 seconds with Zig 0.16.0, `ReleaseFast`, static
`x86_64-linux-musl`, and `-Dcpu=native`. The exact selected 32,323,808-byte
`sql_httparena` executable has SHA-256
`836f823e81f6d8fd7242dfc5b3910ceb6d72930bc7a115c05aff01c79e09989b`.
The Ubuntu amd64 wrk package is `4.1.0-4build3`. Its extracted executable has
SHA-256 `f6536e3f9479584fa2b4a97d12c56671487be9f1011f309dc7a3b1bb0f6ea06c`.
The exact ELFs and Ubuntu package are included. `tooling/` holds the package
metadata, runtime library paths and post-run SHA-256 identities of the local
files at those paths.

The archive (omitted raw evidence archive) includes the 346 tracked source files
under the `build.zig.zon` package paths, all four ZON views, the fixture and
runner inputs, the build and host records, and raw command records, output and
resources for each case. `source_identity.json` is the producer's original
288-file build-input inventory. `packaged_source_identity.json` records all
346 source files, their Git blob identities, modes and SHA-256 values. The
archive stores the exact producer outputs and uses `payload_manifest.json`
for file checksums and modes. The recorded cleanup verified database ownership,
observed zero remaining database consumers, removed the database container,
and removed private inputs. `producer_hygiene.json` records the exact benchmark
password comparison against the five named producer directories before that
password was deleted. The plaintext loopback run required no generated PKI.

## Offline evidence check

From this result directory, verify the archive checksum and extract to an
empty directory. Preserve modes when extracting.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

The verifier uses Python 3.11+ and the retained observations. It checks the
payload and source identities, revalidates the 100 stored bodies, reconstructs
the eight case summaries from raw evidence, and calculates both three-sample
median rows and the gate result. It uses no Docker or network connection.

## Local replay

Use a compatible Linux x86-64 host with Docker, GNU time, Python 3.11+, the
preexisting pinned PostgreSQL image, and the dynamic runtime listed for wrk.
The runtime helpers use the cached image with `--pull=never`. The server was
built for the producer's native CPU instruction set. To rebuild on another
host, use the archived source and an existing Zig 0.16.0 toolchain and cache
containing the pinned dependencies. The compiler checksum is recorded in
`build/result.json`. Set `UWZ_ZIG` and `UWZ_ZIG_CACHE` to their absolute paths
and run the normal install build in a copy of the archived source. Use an
offline environment with the dependencies already present.

```sh
archive="$PWD/extracted/sql_httparena_local_v1_2026_11_18"
(
    set -eu
    mkdir replay_build
    cp -a "$archive/source" replay_build/source
    cd replay_build/source
    "${UWZ_ZIG:?set the pinned Zig path}" build install \
        -Dsql=true -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl \
        -Dcpu=native -j2 --cache-dir ../build-cache \
        --global-cache-dir "${UWZ_ZIG_CACHE:?set the prepared Zig cache path}" \
        --prefix ../install --summary all
)
```

To run with the archived server, stage the helpers and archived input fixture
in a fresh directory. The setup helper generates the working fixture and
private inputs there. The archived shell scripts preserve earlier fixture
provenance. The commands below use the owned replay helpers.

```sh
archive="$PWD/extracted/sql_httparena_local_v1_2026_11_18"
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
        --binary "${UWZ_REPLAY_BINARY:-$archive/install/bin/sql_httparena}" \
        --wrk "$archive/tooling/root/usr/bin/wrk" \
        --app-env "$replay/private/app.env" --fixture "$replay/fixture.json" \
        --output "$replay/run_01"
)
```

`UWZ_REPLAY_BINARY` can select the rebuilt `replay_build/install/bin/sql_httparena`.
Keep `replay_run` fresh for each run. Replay generates new measurements for
its host and writes an owned-fixture cleanup record on exit.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `bc3e357884ed01548be1e6aac285d153e125794f4031938842cbc48375e17bd1`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
