# SQL mapping compile-time and binary-size comparison v1

This scoped measurement compares direct `Row.get` calls and explicit `Param`
construction with the same conversions invoked through named `FromRow` and
`ToParam` callback records. It addresses the pre-adoption measurement in
TODO v2.3 D9. No production source, API or performance threshold is changed.

## Measured results

| Mode | Variant | Median compile time | Sample range | Stripped ELF bytes | `.text` bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| ReleaseSafe | Direct | 8.237417 s | 8.086778–8.312144 s | 369,656 | 211,049 |
| ReleaseSafe | Named callbacks | 8.283062 s | 8.210750–8.293228 s | 369,640 | 211,033 |
| ReleaseFast | Direct | 7.817196 s | 7.756210–7.927947 s | 288,856 | 172,729 |
| ReleaseFast | Named callbacks | 7.833702 s | 7.696132–8.013581 s | 288,856 | 172,729 |

Each row contains six measured builds. Named callback median compile times
are 0.045646 seconds higher in ReleaseSafe and 0.016506 seconds higher in
ReleaseFast. The timing ranges overlap on this shared host; no statistical
significance or general compile-time speed claim is made. The named fixture
is 16 bytes smaller in ReleaseSafe and the same file size in ReleaseFast.
Binary hashes are stable within each variant/mode across every build, and
are retained even when two variants have the same size but different bytes.

These are complete stripped executable file sizes, not object files or
unstripped debug artifacts. ELF section tables are retained separately.
The shared entry point, environment parsing and output formatting contribute
to both executables. This is one three-field schema with constant callback
descriptors; it does not measure arbitrary application schemas, runtime-selected
callbacks, the full SQL server, request throughput, or request allocations.
The existing SQL target above 300,000 RPS is outside this comparison and remains
unchanged and unmet in the separately retained network cohort.

## Fixture and verification

The fixture copies only `src/sql/rows.zig`, `types.zig` and their pure
`pg_wire.zig` dependency. It imports no SQL runtime, C library, database,
network driver or project build graph. The runtime inputs are int4, borrowed
UTF-8 text and boolean fields. Both variants validate the same column metadata,
decode the same borrowed row, fill three caller-owned parameters and print
both decoded and encoded values, including OIDs. The named variant supplies
explicit callbacks through the existing `FromRow`/`ToParam` declarations;
it generates no schema or reflection-based mapper.

All 28 driver builds succeeded: four untimed warmups and 24 measured builds.
Each emitted binary passed ten exact output cases: normal values, minimum
integer with Unicode text, maximum integer with empty text, wrong column OID,
NULL integer, invalid boolean bytes, short parameter storage, invalid boolean
input, integer overflow and oversized text. The independent `verify.py` uses
a separate Python output model, reruns all 280 cases, checks raw results and
timing medians, verifies binary hashes and file lengths, and cross-checks
`.text` sizes from GNU size against readelf. `verification_gate.txt` records
the passing result. Fixture hashes match before and after measurement, and
the original three repository SQL files and Zig executable still match their
recorded checksums after the run.

## Timing and provenance

The toolchain is Zig 0.16.0. Every compiler invocation explicitly selects
`x86_64-linux-gnu`, baseline CPU, the mode shown above, `-fstrip`, and the
common compilation-unit name `sql_mapping`. Compiler/linker backend selection
uses this toolchain's defaults. Compilation is sequential. Odd sample rounds
build direct then named; even rounds build named then direct. Each build has
a fresh local cache directory. A cohort-local global cache is shared and
primed by an initial direct smoke build and untimed builds of both variants
for each mode. The operating-system page cache is uncontrolled. These are
fresh-local-cache, warm-global-cache measurements, not cold-machine builds.

Wall duration is measured with Python's monotonic nanosecond clock around
the compiler process wrapped by `/usr/bin/time`; GNU time's independent wall,
user/system and maximum-RSS values are retained. Durations include compiler
startup, semantic analysis, code generation, linking and output writes.
There is no compile-time or size threshold invented for this comparison.
The independent gate covers functional equivalence and evidence integrity.

The host is a shared Intel Xeon E5-2680 v4 system with 14 physical cores and
28 logical CPUs. Hardware/kernel, affinity, SMT/governor, CPU quota ancestry,
per-build host load, tool/package versions, source commit/patch/status and
input checksums are retained. No quiet host or controlled CPU frequency is
claimed. Nix was unavailable. Zig source/retrieval metadata is recorded;
historical retrieval times for preinstalled system packages are unavailable.

## Reproduction

Extract the archive and use a fresh directory, preserving the supplied SQL
source snapshot. The measured command list for every build is retained under
`results/<mode>_<sample>_<variant>/command.json`. For example:

```sh
/tmp/zig-x86_64-linux-0.16.0/zig build-exe fixtures/direct.zig \
    -O ReleaseSafe -fstrip -target x86_64-linux-gnu -mcpu baseline \
    --name sql_mapping --cache-dir local-cache/ReleaseSafe_1_direct \
    --global-cache-dir global-cache \
    -femit-bin=results/ReleaseSafe_1_direct/sql_mapping
```

To repeat the whole cohort with installed Zig 0.16.0:

```sh
mkdir /tmp/sql_mapping_reproduction
cp -R fixtures main.template generate_fixtures.py measure.py verify.py \
    /tmp/sql_mapping_reproduction/
export UWZ_ZIG=/path/to/zig-0.16.0/zig
python3 /tmp/sql_mapping_reproduction/generate_fixtures.py
"$UWZ_ZIG" fmt /tmp/sql_mapping_reproduction/fixtures
python3 /tmp/sql_mapping_reproduction/measure.py
python3 /tmp/sql_mapping_reproduction/verify.py
```

Only Python 3, GNU time, GNU binutils and the specified Zig toolchain are
required. No downloads or database access occur. Cache directories and the
preliminary smoke executable are omitted from the archive; exact fixture
sources, generator/template, measurement and independent verification helpers,
all per-build commands/logs/results, stripped binaries, raw section tables,
hashes and summaries are retained. Identical executable bodies are hard-linked
inside the tar archive to avoid duplicate artifact data.
