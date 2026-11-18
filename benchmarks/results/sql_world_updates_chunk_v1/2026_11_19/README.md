# Bounded `/updates` chunks on PostgreSQL World, 2026-11-19

**Retained the `/updates` change after median throughput rose from 4,256.105 to
12,719.059 requests/s** in the matched local SCRAM comparison. Median HTTP
p99 fell from 69.928 to 25.855 ms. The D5 requirement above 300,000 requests/s
for each of `/db`, `/queries`, and `/updates` remains open.

The candidate uses the existing `Query.batch` field to submit at most eight
SELECT/UPDATE pairs per transaction. It acquires row locks in stable ID order
within each chunk and returns values in original request order, including
duplicates. Each requested item still gets a parameterized read and a real
`UPDATE ... RETURNING`. The original deadline covers every chunk. Failed
chunks preserve the prior committed work, and a missing result can be detected
after its chunk commits. The measured change is confined to `/updates`.

## Matched result

| Timed metric | Control median | Candidate median | Median paired improvement | Control range / median |
| --- | ---: | ---: | ---: | ---: |
| `/updates?count=20`, requests/s | 4,256.105 | 12,719.059 | +198.843% | 1.389% |
| HTTP p99 | 69.928 ms | 25.855 ms | 63.151% lower | 24.731% |
| App cgroup CPU per completed response | 1,355.011 µs | 192.408 µs | 85.775% lower | 0.494% |
| PostgreSQL cgroup CPU per completed response | 4,188.295 µs | 1,587.826 µs | 62.011% lower | 0.410% |

The three throughput gains were +199.902%, +198.595%, and +198.843%.
Throughput and both CPU metrics improved in every pair, and the median paired
improvements exceeded their control spans. HTTP p99 improved in all three
pairs. The first and third pairs started with control, and the second started
with candidate. The control was the exact retained `/queries` executable.

Each case started a fresh app with 12 workers, eight SQL sessions per worker,
and 192 loopback HTTP/1.1 connections at pipeline depth one. Four wrk threads
ran a two-second warmup and ten-second measured interval at count 20. Both
arms used the same owned PostgreSQL 18.6 postmaster, plaintext host loopback
with SCRAM, default `auto` plan policy, and 10,000 seeded World rows. Logical
World contents were restored and checked before every case. The run took place
on a shared development host. SQL query latency within the SDK under load was
unmeasured.

Twelve serial fixed cases covered counts 1, 7, 8, 9, 20 and 500 in each arm.
The verifier checked all 600 complete HTTP 200 bodies, exact reads and
updates per request, and the full persisted World overlay after accounting for repeated
IDs in response order. The six warmup-plus-timed cases recorded 605,074 HTTP
200 responses, zero client errors and zero observed rollbacks. They had
7,400–7,660 extra SELECTs and the same number of extra updates per case,
within the 7,680 bound for outstanding work at both client cutoffs. The
recorded pool and HTTP socket samples spanned at least 1.288 seconds of
sampled quiescence. The snapshots leave the intervals between samples
unobserved. All 18 app containers exited zero and were removed.

## PostgreSQL observations

CPU values aggregate time across cores. PostgreSQL CPU and WAL are
cluster-level measurements and can include background work. Default
maintenance stayed enabled. Auto-vacuum and auto-analyze advanced in pair 1
control and pair 3 candidate. Checkpointer requests advanced in pair 1
candidate and pair 2 control. `num_done` advanced in pair 2 candidate and
pair 3 control. These are observations of separate counters across case
boundaries. The primary-key index grew from 344,064 to 466,944 bytes across
the run. The packet preserves per-phase storage, WAL, maintenance and
checkpoint observations. The comparison holds starting logical rows fixed
and leaves the observed physical-history differences in the record.

## Lifecycle and test evidence

The successful HTTP lifecycle run retained 12 responses and their SQL and
World journals. It covered healthy chunk boundaries, duplicate IDs and
recovery on `/db`, `/queries`, and `/updates`. An injected second-chunk
update failure started ten reads and ten updates and left eight of each
committed. The missing-result case committed sixteen pairs before returning
HTTP 503. The original-deadline case returned HTTP 503 in 10.001918 seconds
with sixteen committed pairs. Successful recovery followed. The first HTTP
producer attempt failed in its client shim before sending an HTTP request. Its
raw records, revision and guarded cleanup are retained. The verifier
recomputes the successful cases using the original lifecycle validation
functions and recorded SQL/HTTP observations.

The focused run passed 13 tests including live opposing update chunks. The
ordinary unit run passed 1,198 tests and skipped seven of 1,205. The archive
preserves the preceding red and failed lock attempts, owned cleanup, and the
guarded restoration of the isolated lifecycle World. The benchmark app and
client processes are gone. The owned host PostgreSQL fixture was idle at the
last measurement boundary and was retained locally for further D5 work.
Its private inputs are excluded from this packet.

## Evidence and offline verification

The [updates archive](raw_evidence_archive.tgz) contains the candidate’s exact
server ELF, 348-file source closure, build receipt, separate documentation
seal, raw cases, frozen producers, failed attempts, and checker tests. The
candidate ELF SHA-256 is
`ee9261859ee0cd5f9271f15081520f5cae05426eb06bdf19d15d31774298f760`.
The unchanged control, compiler, wrk, and fixture provenance come from the
exact [queries archive](../../sql_world_queries_chunk_v1/2026_11_19/raw_evidence_archive.tgz),
SHA-256 `965f2d156fdadfad52252ff3bc34885015ee4340fee9a8fc5113096d3a00d351`.
`base_dependency.json` binds the specific prerequisite files and their modes
and SHA-256 values. Keeping the dependency separate avoids duplicating the
compiler, control ELF and prior raw histories.

From this result directory, extract both archives into a new destination.
The Python 3.11+ verifier checks the pinned base tar and every extracted base
file against its sealed manifest before running the base checker in a
separate process. It reads updates inputs only from the two manifested
extraction roots. The updates archive also carries the original Zig 0.16.0
musl copyright notice at `notices/zig-0.16.0/lib/libc/musl/COPYRIGHT`. The original paths stay in
the enclosed producer records. The checker verifies all measurements offline
and leaves the archives and the historical producer workspace untouched.

```sh
(
    set -eu
    sha256sum -c manifest.sha256
    queries_archive="$PWD/../../sql_world_queries_chunk_v1/2026_11_19/raw_evidence_archive.tgz"
    printf '%s  %s\n' '965f2d156fdadfad52252ff3bc34885015ee4340fee9a8fc5113096d3a00d351' "$queries_archive" | sha256sum -c -
    mkdir extracted
    tar -xzpf "$queries_archive" -C extracted
    tar -xzpf raw_evidence_archive.tgz -C extracted
    python3 -B extracted/sql_world_updates_chunk_v1_2026_11_19/verify_bundle.py \
        --queries-archive "$queries_archive" \
        --queries-root extracted/sql_world_queries_chunk_v1_2026_11_19 \
        --test-checkers
)
```

The packet retains the original runtime commands and records. Verification
used the archived bytes. A fresh live runtime replay was not performed.
