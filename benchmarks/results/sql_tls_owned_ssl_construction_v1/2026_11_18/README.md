# SQL TLS owned SSL construction and identity setup

Date: 2026-11-18. Isolated native/SDK proposal; production pins remain unchanged.
The original complete PostgreSQL allocation gate remains **RED**. SQLite's
approved SQL-ALLOC-001 exception does not apply to PostgreSQL.

The same-fixture worker-wide comparison removes **180 mallocs, 180 frees and
53847 requested bytes** across six original failure/reconnect/cancellation
intervals. Every functional, callback, pool, preparation and interval invariant
matches the owned-BIO parent. No reconnect or cancellation work is exempted.

## Scope and ownership

Sixteen native files add `SSL_client_construction_storage_requirements` and
`SSL_new_client_with_construction_domain`, owning admitted client construction,
SNI and DNS/IP verification setup through an explicit borrowed domain. The pure
query derives native raw extents, alignment and reusable fixed-slot capacity.
The standard image reports 46400 bytes, alignment 16, stride 2320 and 20 slots.
Empty group arrays report 18 slots; retained larger cipher capacity changes the
stride. These values describe construction/setup, not total TLS memory.

The new profile admits the existing SQL TLS 1.3 settings, arbitrary caller CA
bundles, verification scalars/flags/depth and development `verify=false`.
Unsupported raw-context clone shapes are rejected before domain allocation;
the exact predicate and lifetime contract are retained in `contract.md`.
Ordinary APIs preserve successful behavior and allocation representation.
An actual inherited OOM defect is also corrected: failed hostname-constraint
inheritance now makes construction fail instead of returning an SSL missing
that constraint. Parent RED and candidate GREEN are retained.

Each stable normal and cancellation connection owns separate BIO and SSL
construction descriptors, backing and slot metadata outside resettable Session.
All 2N regions are allocated during startup with checked arithmetic. Released
SSL slots are immediately reusable while permanent roots remain live, including
`SSL_clear`. Clear retains its existing destructive failure semantics and stays
freeable after partial replacement. Both session arrays are destroyed before
their backing/context is released; dormant cancellation sessions may own data.

## Original lifecycle measurements

Every row is repeated three times. Counters include all C malloc/calloc/realloc/
free calls and requested bytes from first worker query submission through final
callback entry, including overlapping close, reconnect and cancellation.

| Scenario | Image | malloc | calloc | realloc | free | Requested bytes |
|---|---|---:|---:|---:|---:|---:|
| Failure/reconnect | Owned-BIO parent | 262 | 2 | 0 | 264 | 346909 |
| Failure/reconnect | Owned SSL setup | 242 | 2 | 0 | 244 | 340926 |
| Deadline/cancel | Owned-BIO parent | 524 | 4 | 0 | 528 | 693818 |
| Deadline/cancel | Owned SSL setup | 484 | 4 | 0 | 488 | 681852 |

Fresh fixture totals differ from historical fixtures; only this paired run
establishes the measured delta. The original probe and counter are unchanged:

- Probe SHA256: `bc552c885af280e4ad6ac7ba0c1b752e6c42ccdb3589f5f0434380ce68d0c159`.
- Counter SHA256: `afd763bd0dbda66b4e7ee5193bb5c6c785e79f9c6d8ddf2dd671911341cf66ac`.
- Parent ELF SHA256: `8cfc5c07644ff04e73d879b9da374d09ad7bf246f94e1f69ec30e305bac0cf12`.
- Candidate ELF SHA256: `dcc8073ae0d17b4c584e72f3156cd9b40de841b2496346be32f01e7e6c8b0bc2`.

`compare_lifecycle.py` checks every semantic invariant and the measured
constructor/setup reduction under optimized Python. All four malformed-report
controls reject. Both original executables still exit with the strict nonzero
allocation error; the runner checks that expected failure explicitly.

## Verification

- Full native ReleaseSafe proof plus separate handshake compilation: 57/57
  steps. Twenty-six construction rows pass; 24 count zero calls and bytes across
  all C heap operations. The two allocating shared-context/copy controls stay
  explicit. Ordinary construction/setup still measures 20 mallocs/20 frees and
  5983 requested bytes with the unchanged 63-byte counter self-test.
- Pure cold-process/fresh-thread queries, invalid/profile/overflow inputs,
  each construction/setup/clear failure site, all slot capacities, 128-cycle
  reuse, interleaved owners, exact release extent/alignment/cleansing, and
  destination-owned parameter copying pass. Cold RNG/ERR remains a separate
  allocating control. Full hooks reject the owned factory before callbacks;
  inherited partial-hook leaf coverage does not claim a valid-context partial-
  hook SSL-factory test.
- Fifteen separate actual TLS 1.3 handshake cases pass across AES-128-GCM,
  AES-256-GCM and ChaCha20-Poly1305: verified DNS/IPv4, bidirectional application
  data, wrong DNS, untrusted CA and TLS 1.2-only peer rejection. IPv6 setup/clear
  is tested; successful IPv6 handshakes and whole-handshake zero allocation are
  not claimed.
- Ordinary live SDK: 1205/1205; production-pinned root: 1182/1182. SDK ReleaseSafe
  test compilation and ReleaseFast library each pass 24/24 build steps. Full
  formatting, conventions and release-version checks pass.
- Initial focused SDK run: 6/8. One new test used an unsupported two-connection
  pool; the other assumed immediate stop after allocation failure, although
  native code initializes two AEAD members before checking either. Corrected
  inputs and explicit selected-failure, bounded-call, release/cleansing/reuse
  checks pass 8/8. Initial logs and source-based diagnosis remain retained.
- Fresh optimized-Python restoration verifies 8709 parent and 8709 candidate
  files, 501 SDK files and 16 proof inputs, then passes all 54 fixture-independent
  proof steps from empty caches. All 28 restore rejection controls pass.
- Independent source and frozen-proof reviews have no unresolved findings.
  The disposable container and all private fixture files were removed after
  live checks; the public evidence scan found no generated secrets.

Raw logs, complete source/mode identities, the exact 16-file native delta, full
SDK sources, selected ELF binaries, reviews and replay scripts are in the
archive. No generated PKI, fixture passwords, caches or native object/archive
files are included. Four unchanged SDK benchmark/build `.env` contracts are
allowed only by exact source paths and SHA256; they contain public parameters.

## Replay and provenance

Verify `manifest.sha256`, then extract the archive into an SSD workspace.
`sql_tls_owned_ssl_construction/restore.py` requires the complete external
[owned-BIO native parent](../../sql_tls_owned_bio_pair_v1/2026_11_18/README.md).
Its 8709-file identity SHA256 is
`698bc252dcd3b629fb4f779e18ec3889aa96ccf5ab2b6eb2f174e0789647ed7b`.
The candidate identity is
`4b2feb7f16a45250c88feb1ab57a24fd3ea0196f8cde777cd87c9f8ba54d3699`;
the full SDK identity is
`e9b6135a8da083cbdac2bb51554f15e6602397ba9c05e555c330b61be92372bf`.

Use the exact Zig 0.16.0 executable SHA256
`2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`:

```sh
python3 -O sql_tls_owned_ssl_construction/restore.py \
  --parent /absolute/path/to/complete-owned-bio-native-parent \
  --output /absolute/path/to/new-SSD-restoration-directory \
  --zig /absolute/path/to/exact-zig-0.16.0
```

Restoration verifies exact path sets, bytes and modes before creating output,
overlays the 16 declared files and rebinds exactly one native source path in the
SDK builder. The fixture-free `proof` target executes every existing row.
`handshake-build` separately compiles the fixture-driven compatibility program;
run it against fresh external `server.pem`, `server.key`, `ca.pem` and
`untrusted.pem`. Copy the public fixture setup scripts outside the immutable
packet before generating private inputs. SQL live runners also require a fresh
disposable PostgreSQL fixture. They never record passwords in command logs.

## Remaining full-goal work

Transcript descriptor ownership does not own transcript payload growth.
ClientHello/CBB payloads, key shares, certificate/ASN1 parsing and verification
chains, EVP/EC/RSA/BN workspaces, negotiated AEAD/session/ticket data and cold
ERR/RNG/thread facilities remain outside this constructor budget. Full
PostgreSQL ownership/capacity, native publication/pins, production adoption,
D-5 throughput and other open v2.3.0 requirements remain required.
Dedicated smoke/security/sanitizer/fuzz campaigns remain user-deferred with
their configured gates unchanged. This artifact is progress, not a release.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `8ff2ce04b932a492bb673eea604c3b2e0ea7402cc8f1ff60265e6eb0c29c9a9d`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
