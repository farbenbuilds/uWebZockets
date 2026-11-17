# Fixed-storage TLS 1.3 HKDF label candidate

An isolated BoringSSL candidate replaces the heap-backed TLS 1.3 HKDF label
encoder with a 514-byte stack buffer. The existing CBB serialization and HKDF
implementation remain in use. The [single-file diff](candidate.patch) is retained
for review. This removes one allocation site; production
source, dependency pins and maintained forks are unchanged. The strict
PostgreSQL request-path allocation gate remains open.

The exact baseline is BoringSSL
`d3bf4795ad5b79d646cddf2fec687da5b9b502db` plus the previously retained
[four-file record-reservation candidate](../../sql_tls_retention_v1/2026_11_17/README.md).
All 8709 native source entries are inventoried. Only
`crypto/fipsmodule/tls/kdf.cc.inc` changes relative to that candidate; its four
record-retention files remain identical. The complete SSL and crypto libraries
were rebuilt in Debug using the existing Zig 0.16 source-list build: six of six
build steps passed. This is not a FIPS certification or validation claim.

## Direct differential and allocation result

The unchanged baseline fails the strict zero-allocation assertion; the fixed
candidate passes the same assertion. All 1440 cases match return values,
error-library/reason queues and hashes of the complete 65,568-byte output
buffers. All 700 successful baseline calls use one malloc/free pair; all 700
successful candidate calls count zero malloc, calloc, realloc, free and
requested bytes. The other 740 cases preserve rejection and output sentinels.
No zero-allocation claim is made for error paths.

The fixture covers SHA-1/256/384/512, empty/binary labels and contexts, the
249-byte caller-label and 255-byte context limits, rejected vector lengths,
the maximum 514-byte encoding, digest/output limits, and output lengths 65535
and 65536. It preserves this pin's implicit 16-bit output-length narrowing.
Independent manual HkdfLabel serialization followed by unchanged `HKDF_expand`
checks valid encodings, including output-limit rejections. The all-C interposer
and its 63-byte self-test are unchanged. Only the complete native helper call
is metered; fixture setup, reference calculation, hashing and logging occur
outside accounting.

## Public TLS control measurements

The unchanged public-API witness runs four scenarios against three fresh,
verified TLS 1.3 pairs each: twelve rows and 255 client operations. Each measured
SSL read/write includes its immediate error mapping. Reservation occurs before
these intervals; server work, payload checks and logging are outside them.
All 4096-byte payloads and the requested KeyUpdate response are verified.

The counts below are stable across the three repetitions. Requested bytes
include native allocator bookkeeping. All calloc/realloc counts are zero.

| Client phase | Prior malloc/free | Fixed malloc/free | Prior requested bytes | Fixed requested bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload read | 0/0 | 0/0 | 0 | 0 |
| Two initially queued tickets, caching off: read | 16/16 | 14/14 | 2186 | 2128 |
| Peer KeyUpdate, no response requested: read | 6/6 | 3/3 | 726 | 656 |
| Peer KeyUpdate, response requested: read | 15/13 | 9/7 | 1604 | 1464 |
| Following client response/application write | 0/2 | 0/2 | 0 | 0 |

These are synthetic TLS/BIO client-call counts, not PostgreSQL per-query
measurements. The tickets were queued by the initial handshake and flushed
after client reservation; arbitrarily minted later tickets are not tested.
The prior counts come from the immutable
[control witness](../../sql_tls_prerequisites_v1/2026_11_17/README.md).
Other ticket/session, AEAD, response-flight and error allocations remain work.

All sixteen inherited reservation lifecycle cases, the 256-loop buffer proof
and seven record-size exchanges also pass against the changed complete library.
The separate fault observer remains distinct from ordinary allocation
accounting. Configured DTLS/QUIC negative fixtures are not completed protocol
interoperability tests. Private fixture PKI is removed after the runs.

Ordinary root checks pass: formatting leaves 314 source/build inputs unchanged,
conventions and release-version checks pass, and the SQL/SQLite-enabled unit
suite reports 1158 passed with 24 existing live-PostgreSQL cases skipped because
their fixture settings were unavailable. Dedicated smoke, security, sanitizer,
fuzz and scan campaigns remain user-deferred; no gate or assertion was weakened.

## Retained evidence and replay

`raw_evidence_archive.tgz` contains the native source delta, full changed source,
baseline/candidate inventories and build inputs/logs under `native/`; the
fixtures, six prebuilt Linux x86-64 helpers, RED/GREEN results, control rows and
lifecycle evidence under `verification/`; and independent reviews plus root
checks. Native source restoration is documented in `native/HANDOFF.md`.
`verification/preliminary/` preserves the earlier fixture spelling explicitly;
the final fixture uses a named digest-function alias and repeats baseline RED
before candidate GREEN. Both spellings produce identical baseline rows.

From this result directory, verify and extract into a fresh directory:

```sh
sha256sum -c manifest.sha256
mkdir /tmp/uwz-hkdf-evidence
tar -xzf raw_evidence_archive.tgz -C /tmp/uwz-hkdf-evidence
cd /tmp/uwz-hkdf-evidence
sha256sum -c files.sha256
python3 restore_pki_tool.py /absolute/path/to/uWebZockets
python3 verification/replay_prebuilt.py --pki-tool tools/wt-tools --output /tmp/uwz-hkdf-new-replay
```

Choose absent extraction and replay directories. The replay directory must be
outside the extracted evidence. The restore helper reads only the checksum-pinned
PKI executable from the existing independent-client artifact in the repository;
it needs no network access. The replay verifies all six binary identities,
requires the unchanged baseline to fail and the fixed candidate to pass, checks
all differential/control/lifecycle results and removes owned private PKI in a
finally block. No compiler or native archive is needed for this prebuilt replay.
Root verified that command from the delivered layout.

Offline comparisons can also be repeated without running the helpers:

```sh
python3 verification/compare_results.py verification/baseline/observe.stdout verification/candidate/observe.stdout
python3 verification/compare_controls.py
```

Source builds still use the Zig source-list build. Python is evidence tooling,
not a new project build dependency. Archive checksums cover the final payload;
no private keys, certificates or native library archives are retained.
