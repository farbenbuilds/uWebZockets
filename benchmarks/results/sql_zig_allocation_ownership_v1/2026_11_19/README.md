# SQL Zig allocator ownership

The four focused Debug tests passed with Zig 0.16.0 against a fresh plaintext
PostgreSQL 18.6 fixture. They cover calls to the allocator supplied to
`Db.init` in the exercised paths. Production code is byte-identical to
the parent commit for the selected source files. The test delta adds one
suite import and the new test file.

| Test | Observed assertion coverage |
| --- | --- |
| Positive control | The armed allocator counted one denied allocation, one denied resize, one denied remap and one free. It recorded the allocation attempt even when the caller consumed the error. The free reached the parent allocator after its ownership check. |
| Startup and deinitialization | The main connection records, auxiliary cancellation records and byte slab were the three allocations. All three frees matched address, extent and alignment. |
| Plaintext SQL runtime | Cold and warm named statements, unnamed results and `Row.keep` passed with scratch reuse. Middle-batch server error recovered on the same lease. Queue saturation, cancellation and the acquire deadline delivered the expected callbacks. Explicit cancellation and the running-query deadline observed `PgSleep`, checked the SDK's auxiliary send flag and 16-byte CancelRequest length, and verified a new backend PID and same-index reuse. |
| World handlers | The actual handler exercised `/db` count 1, `/queries` counts 20 and 500, and `/updates` counts 20 and 500 with real typed PostgreSQL results. Assertions checked continuations, values, body bytes and completion through a caller-owned response target. |

Each test-owned `Db` had three startup allocations and three matching
deinitialization frees. After readiness, the live tests armed the
supplied allocator. The World case seeded its backend-local temporary
tables before arming. All checked armed paths had zero allocation, resize
or remap attempts and zero frees through stop and drain. Main and
auxiliary records, slab, receive/response/transmit and fixed storage,
and pool slots and waiters retained their addresses and extents.

The observer covered the supplied Zig allocator. The World test allocated
one outer context with `std.testing.allocator`, separately from the
supplied allocator. The handler ran directly and returned into a
caller-owned target without a socket HTTP exchange. Temporary World tables
were seeded per backend. The cancellation evidence includes the observed
sleep, SDK send state and reconnection. It contains no independent server
cancellation acknowledgment.

Alternate allocators, C and native TLS allocation, kernel and server
allocation, and whole-process allocation remain outside this evidence.
The historical production TLS C allocation gate remains RED. The master
allocation requirement remains open. The Daybreak-dependent X.509 and
TLS ownership work remains deferred.

## Original test results

The first attempt failed compilation on a test-only array initializer.
The succeeding development runs passed two controls, three tests with
live runtime coverage, and all four final focused tests. The focused run
and full ordinary run recorded the same final test sources. The ordinary
run finished 23 of 23 build steps with **1,202 passed and 7 skipped**
of 1,209 tests. Its seven skips were the unavailable TLS and alternate
credential fixtures listed in the raw log. The original archive retained earlier
source hashes and diagnostics, final source snapshots, raw stdout and
stderr, command exits, and the developer's assertion summary. The
assertion summary records what the tests checked.

The owned fixture verified the SCRAM loopback rule and correct and
incorrect credentials. After the tests, a read-only receipt verified the
same fixture identity with zero TCP clients, other clients, temporary
World relations and lock schemas. The original archive included the original
fixture/setup and post-test receipts. Private inputs are excluded.

## Offline verification

The original archive included selected sources and the exact test delta against
parent `66804326e4f58e276cb51006d5b24186c405af25`. Five source hashes
were recorded with each test command. The additional selected
build and support sources were matched to the parent at packaging.
The recorded compiler SHA-256 is
`2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
Compiler, test executable and build cache contents are omitted.

From the repository root, verify the archive with Python 3.11 or later
and GNU tar.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

The verifier checks exact archive inventory, file modes, source delta,
original run exits and test counts, and fixture receipts. To repeat the
tests, use a matching checkout, Zig 0.16.0 and a fresh plaintext
PostgreSQL SCRAM fixture with the `uwz_test` role and database described
in `fixture/plan.md`. Start without other `UWZ_SQL_TEST_*` inputs and set
`UWZ_SQL_TEST_PASSWORD` and `UWZ_SQL_TEST_PORT` for that fixture.

```sh
zig build test-unit -Dsql=true -Dsqlite=true '-Dtest-filter=sql allocation ownership:' --summary all
zig build test-unit -Dsql=true -Dsqlite=true --summary all
```

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `ad39a1c452fbc953b5dec352ee3a71dcf3143786d6a5fd31ef09771c42277b31`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
