# Owned PostgreSQL TLS BIO pairs, 2026-11-18

This isolated native and prepared-SDK implementation removes the complete
six-allocation BIO-pair construction path from the original PostgreSQL lifecycle
intervals. It builds on the [explicit memory/CBB domain](../../sql_tls_domain_v1/2026_11_18/README.md).
The complete PostgreSQL allocation gate remains strictly RED. Production pins,
publication and the other v2.3.0 requirements remain open.

## Measured lifecycle result

The original probe and all-C counter sources are unchanged. Only the consumer's
SDK dependency path is rebound. Control and candidate run against the same
owned PostgreSQL 17.11 TLS fixture, with the same worker-wide interval:
first `Db.query` submission through final callback entry, including overlapping
close/reconnect/cancellation, another active query and a queued waiter.

All six functional scenarios pass. Callback order, outcomes, pool counts,
generations, preparation and cancellation observations match. Both executables
exit 1 with `NonZeroLifecycleAllocations`; no interval, assertion or allocator
body is changed to make the complete gate pass.

| Scenario, three rounds each | Profile | malloc | calloc | realloc | free | Requested bytes per round |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Failure/reconnection | Control | 268 | 2 | 0 | 270 | 412766 |
| Failure/reconnection | Owned pairs | 262 | 2 | 0 | 264 | 346910 |
| Deadline/cancellation | Control | 536 | 4 | 0 | 540 | 825532 |
| Deadline/cancellation | Owned pairs | 524 | 4 | 0 | 528 | 693820 |

The nine pair constructions therefore remove **54 mallocs, 54 frees and 592704
requested bytes**. The ordinary pair control measures six mallocs, six frees
and 65856 requested bytes for two 32 KiB rings. Its strict invocation exits 1.
The original five-operation, 63-byte counter self-test passes.

## Ownership and source

`BIO_new_bio_pair_with_domain` owns both BIO objects, both pair-state objects and
both rings through one borrowed immutable `OPENSSL_ALLOCATION_DOMAIN` descriptor.
Partial construction releases every acquired block and leaves accessible outputs
null. Generic `BIO_free` and reference counting retain owner provenance. There
is no ordinary-heap fallback. The descriptor, callbacks, context and storage must
survive the last endpoint reference in one compatible native image.

`BIO_pair_storage_requirements` is a pure checked query for the complete six
raw allocations and alignment padding. It normalizes zero capacities to the
ordinary 17 KiB default, rejects overflow and performs no allocation, ERR,
hook, thread or once operation. One private memory helper supplies authoritative
raw-size/alignment calculation to both this query and the owned allocator.
Ordinary allocation, the private header layout and ordinary BIO behavior remain
unchanged.

Each normal and cancellation SQL `Connection` gets reusable startup storage;
there are `2N` slabs for `N` configured pool connections. The native query
determines bytes and alignment. The measured Linux x86-64 query returns 66016
bytes and alignment 16 for two 32 KiB rings. These are proof expectations, not
private constants embedded in Zig. The structural bound is `2N` queried slabs
plus bounded metadata, independent of reconnect count. This is a BIO-specific
bound, not a total TLS capacity bound.

Descriptors are initialized only at stable connection addresses and live outside
`Session`, whose deinitializer resets its fields. Bump storage resets only after
the final raw release. Unavailable, undersized, misaligned or overlapping use
fails without growing or waiting. Both normal and preconstructed dormant
cancellation sessions release before backing storage and descriptors are freed.

Exactly four of 8709 native files change from the preceding complete native
leaf: `include/openssl/bio.h`, `crypto/bio/pair.cc`, `crypto/mem_internal.h` and
`crypto/mem.cc`. There are no additions, deletions, links or mode changes.
The native diff SHA-256 is
`482dd921181067ba48d575c4576f1a1d2164a149196839a618d56cf69fb1008f`.
The prepared SDK contains 499 source files: six runtime/test paths change,
including two additions, plus the separately recorded builder-path binding and
test-only support aliases. Complete content/mode identities are retained.

## Verification and retained failure

Before native edits, the public C probe fails against the immutable parent
because the new type/query/factory are absent. This is compile-time RED. The
ordinary six-allocation positive control and its strict RED are retained too.

The final native ReleaseSafe proof passes 38/38 build steps. Nine new BIO rows
count zero malloc/calloc/realloc/free and requested bytes; the whole-SSL ownership
control deliberately counts 59 mallocs, 58 frees and 14802 requested bytes while
releasing every pair block correctly. It does not claim a zero-allocation SSL
lifetime. The inherited memory/CBB proof retains 14 passing rows, 13 measured
zero. Full/partial weak hooks, six OOM sites, exact release cleansing, two owners,
128 reuse cycles per owner, ring/retry/half-close behavior and extra-reference
release orders pass. Cold-query heap behavior and source purity are checked;
no separate pthread/once interposer is claimed.

Only the requirements-query row runs before ERR warm-up. Factory, OOM and other
error-path zero counts use an explicitly initialized ERR queue. Cold-thread
error ownership remains open.

Eight focused SDK tests cover backing validation, all six OOM sites, reuse,
cleansing, two owners, extra references, Session reset and startup cleanup. The
missing-module RED snapshot contains the original two guard/query tests; the
remaining cases were added later. The unchanged alignment-zero regression found
a real guard bug, which was fixed before final verification.

The final unfiltered live SDK suite passes **1197/1197**, and the
production-pinned root suite passes **1182/1182**, both without live skips.
SQL+SQLite ReleaseSafe `test-compile` and ReleaseFast `lib` each pass 24/24 steps.
`test-compile` compiles the C API smoke executable without running it. Formatting,
conventions and release-version checks pass. Independent contract, native source,
native evidence and runtime source reviews report no actionable findings.

The first full live SDK run passed 1196/1197 and failed one unchanged plaintext
migration-deadline case with an empty migration name. That establishes a
pre-apply timeout, without distinguishing readiness from transaction, lock,
schema or history setup. The new BIO path is not selected there. With the same
500 ms deadline and original seed, targeted candidate replays pass 5/5; the
immutable parent passes 4/5 and reproduces the same failure once. No source,
test, deadline or gate was changed. The exact delayed phase and scheduling/load
cause remain unproven; the AuthenticationFailed warning is not causally tied to
the failing case. The failed run, redacted diagnostics and subsequent full
unfiltered serial pass are all retained.

## Restore and replay

the original archive contained four native replacement files, full SDK,
proof/consumer sources, ten executed native ELFs, the preserved parent ordinary
control, both lifecycle ELFs, source identities, public raw results and reviews.
It contains no build caches, installed libraries, generated credentials or PKI.
The top-level `files.sha256` covers every other payload, including the nested
diagnosis manifest. Source modes and binary mappings are recorded separately.

After extraction into `$packet`, run `sha256sum -c files.sha256` there. The ten
programs in `bin/native/` each exit zero on a compatible Linux x86-64/glibc host.
The preserved ordinary parent control exits zero normally and one with `--strict`.
Lifecycle binaries require a fresh owned fixture and both retain strict RED.

The complete native parent from the preceding memory/CBB artifact is an explicit
external input. It is not fetched from an unpublished remote:

```sh
python3 -O "$packet/restore.py" --parent "$complete_owned_memory_parent" \
  --output "$new_scratch_output" --zig "$zig_0_16_0"
```

The helper verifies all 8709 parent files/modes, copies the full tree, replaces
only four files, verifies all 8709 final files/modes and checks all 499 SDK plus
11 proof/build inputs. It rebinds exactly one SDK builder source path, then uses
the normal complete native source lists. Compiler SHA-256 must be
`2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
Omit `--zig` to restore without building. Outputs must be new and outside an
evidence artifact; quote, backslash and control characters in output paths are
rejected for the documented Zig 0.16 source-path limitations. Validation remains
active under optimized Python. Python restores evidence; it is not a native
build dependency.

Fresh optimized-mode restoration verifies all source/mode identities and passes
the complete 38/38 native proof again; `restoration_evidence/` retains that result.
Ten copied-invalid-input/path cases reject without creating output, and four
malformed lifecycle-report comparisons also reject under optimized Python.

For offline counter comparison:

```sh
python3 -O "$packet/compare_lifecycle.py" \
  --control "$packet/evidence/run_parent_lifecycle/lifecycle.json" \
  --candidate "$packet/evidence/run_owned_lifecycle/lifecycle.json" \
  --output "$new_comparison_output"
```

For live replay, copy the two public `fixture/*.py` helpers to a new scratch fixture,
run setup there and supply that fixture to `run_lifecycle.py` for each lifecycle
binary, then compare the two new reports. The setup helper leaves its exact
owned container ID and generated private inputs under `private_fixture`; remove
that container and directory after use. Full live unit replay additionally
needs a fresh untrusted CA at `private_fixture/untrusted.pem` and the generated
Unicode roles, as required by `run_sdk_check.py --mode units --expected-tests
1197`. Generate that separate untrusted CA with OpenSSL into the scratch private
directory; its private key must never enter an evidence packet. Docker/OpenSSL are fixture
tools. No live fixture or its credentials are bundled. `fixture_cleanup.json`
records Root's removal and verified absence of the owned container and private
directory. Its exact generated-secret scan covers the initial 676 staged files;
the later restoration/manifest records use only public, fixture-independent inputs.

Complete SSL construction, transcript/certificate/verification/crypto/ERR/thread
ownership, total TLS capacity, cross-target execution and production publication/
pins remain open. There is no PostgreSQL allocation exception. SQLite's approved
SQL-ALLOC-001 remains separate. Dedicated smoke/security/sanitizer/fuzz campaigns
remain user-deferred with their existing configuration and thresholds.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `d9b18315711348aa3b34ef6db2e769e2fde33006f558abf6ff9ffe0ee217c73a`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
