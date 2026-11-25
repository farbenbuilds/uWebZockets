# Bounded client KeyUpdate output candidate

This isolated native proposal adds `SSL_reserve_key_update_output_buffers` for
an idle, completed ordinary TLS 1.3 client. Startup reserves plaintext and
ciphertext flight storage. KeyUpdate construction uses a fixed five-byte CBB;
the synchronous borrowed-message entry copies the complete message before its
callback. Retained buffers eliminate allocation and later frees when sending
requested responses. Production pins and PostgreSQL's strict allocation gate
remain unchanged.

The baseline is the reviewed
[recycled KeyUpdate context candidate](../../sql_tls_aead_reuse_v1/2026_11_17/README.md)
on BoringSSL `d3bf4795ad5b79d646cddf2fec687da5b9b502db`. Six of 8709 native
source entries change, with eleven cumulative changed files from the original
package. The complete matching crypto/SSL Debug rebuild passes all six steps,
including all 38 SSL translation units.

## Bounds, ownership and startup

The exact pin's supported application suites have a five-byte KeyUpdate and
22 bytes of record overhead. Ordinary client output has no dynamic padding
path, and legal fragment settings remain between 512 and 16384 bytes. Startup
and use validate the captured cipher and seal bound; later legal fragment
changes remain supported.

| Measured quantity | Value |
| --- | ---: |
| Logical plaintext / ciphertext limits | 5 / 27 bytes |
| Rounded plaintext / ciphertext data capacities | 8 / 40 bytes |
| Startup C allocation | 4 mallocs, 128 requested bytes including prefixes |
| SSL3_STATE size before / after | 632 / 640 bytes |

Both temporary BUF_MEM objects and data allocations complete before either
owner or the profile is installed. Startup failure preserves prior ownership
and configuration. Idle repeated reservations allocate nothing. `SSL_clear`
destroys the storage and disables the mode. The caller verifies the certificate
and hostname first. Servers, DTLS/QUIC, initialization, shutdown/error and pending
I/O, messages, alerts, updates, flights or borrowed contexts are excluded.
Mutating SSL operations must be serialized and non-reentrant; observation
callbacks remain supported.

Plaintext ownership is temporarily borrowed while sealing, then its consumed
bytes are cleansed and its empty allocation restored on success and failure.
Failures preserve existing message-consumption effects rather than replaying
the plaintext. Flight storage remains allocated after successful direct flush
or staging into the bounded write buffer. Only transferred bytes are cleansed;
unsent ciphertext remains intact. Empty retained buffers behave as absent.
Length and offset reset together, and partial-flight append is rejected before
mutation. Old application data drains first, old-key sealing precedes key
installation, and existing pending-write retry and coalescing rules remain.

## Encrypted requested-update allocation gate

Public singleton TLS 1.3 cipher selection and assertions on both peers establish
the actual negotiated suites: `0x1301` AES-128-GCM, `0x1302` AES-256-GCM and
`0x1303` ChaCha20-Poly1305. The gate processes eight valid requested peer updates
per suite, 24 updates and 600 complete metered client read/write calls per
variant. Exact 4096-byte application payloads travel both ways after every
update; response modes and counts are checked.

The baseline and new-unreserved variant each count five mallocs, three frees
and 200 requested bytes per read/update, followed by two frees on the client
response/application write. Both fail the unchanged strict-zero assertion only
after completing valid traffic. The reserved candidate passes that assertion:
every read and following write counts zero malloc, calloc, realloc, free and
requested bytes. The original all-C interposer and 63-byte self-test are
unchanged. Startup, peer work, payload validation and logging remain outside the
complete client-call and immediate error-mapping intervals. These are synthetic
TLS/BIO measurements rather than PostgreSQL query counts.

## Protocol ordering and public controls

The protocol matrix has 24 rows and 3855 metered operations per variant:
3843 read/write calls, including nine zero-length flushes, plus twelve local
KeyUpdate calls. Baseline, reserved and new-unreserved variants preserve exact
payloads, response modes, callbacks, retry/error tuples and ordering. Fifteen
healthy reserved rows count zero heap operations in every measured phase.
Repeated/coalesced and alternating updates, older partial application records,
older partial KeyUpdate ciphertext and exact retry ownership are covered.
Changed-buffer retries reject with the same BAD_WRITE_RETRY result; continuation
after that error is not claimed. Sixty-three header observations retain the old
write context while its prepared replacement is borrowed. Message callbacks
verify the complete five bytes were already copied.

Zero-length success is tracked separately from raw error mapping: this pin
returns zero and maps that return through `SSL_get_error` to error 5. Six such
successful flushes and three WANT_WRITE flushes preserve their actual baseline
tuples; the fixture does not manufacture SSL_ERROR_NONE. These witnesses use
default BIO pairs with 17-byte or 1024-byte capacities. Their flush control
always succeeds; custom-BIO flush-failure recovery across different operations
remains an inherited limit described in `native/REFERENCE_NOTES.md`.

The public control witness repeats four scenarios across three fresh pairs,
twelve rows and 255 complete metered client calls per build. Counts remain
stable across repetitions; calloc/realloc stay zero.

| Client phase | Prior malloc/free | Reserved malloc/free | Prior bytes | Reserved bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload read | 0/0 | 0/0 | 0 | 0 |
| Two initial tickets, caching off: read | 12/12 | 12/12 | 1600 | 1600 |
| Peer KeyUpdate, no response requested: read | 0/0 | 0/0 | 0 | 0 |
| Peer KeyUpdate, response requested: read | 5/3 | 0/0 | 200 | 0 |
| Following client response/application write | 0/2 | 0/0 | 0 | 0 |

## Direct helpers and failure evidence

All three suites pass exact five-byte encoding/copy-before-callback checks,
27-byte flight checks, logical-size/overflow/capacity guards, retained-empty
semantics, idempotence and later legal fragment changes. Append-guard rejection
leaves owners, data and callbacks unchanged. Borrowed plaintext ownership is
restored after storage failure. A direct 2-byte prefix plus 25-byte tail fixture
checks partial-offset rejection, stable owners and consumed-only cleansing,
with zero heap operations. This direct transport fixture does not claim peer
decryption; the separate encrypted gate proves peer acceptance.

Three separate injected cases call the real record sealer successfully and
then force failure. They preserve the existing consumed-plaintext contract and
restore its cleansed empty owner without heap operations. They do not claim
whole cryptographic-state rollback. Injection remains separate from ordinary
allocation accounting and adds no native test branch.

All 23 lifecycle/failure cases pass. Each of the four startup allocation failure
points preserves the existing record, incoming-handshake and AEAD owners and
configuration, frees temporary allocations and permits retry on the same SSL.
Eligibility checks cover actual pending states, shutdown and saved fatal errors,
roles and protocol configuration. Clear/reuse performs a fresh verified,
nonresumed handshake, reserves new storage and exchanges updates both ways.
Tracked default-allocator storage is cleansed and actually freed once; the two
clear/reuse epochs record eight successful allocations and eight real frees.
This is a bounded ownership check rather than whole-process leak accounting.

The 38 inherited fixture inputs remain byte-identical. Their final-archive
regressions pass: sixteen record lifecycle cases and both buffer/pair helpers;
64 incoming-handshake fragment/coalescing loops and 21 lifecycle cases;
1440 HKDF differential cases with 700 zero-allocator successes and 740 matching
rejections; and 24 AEAD direct epochs, twelve populated-initializer failures,
48 zero-heap three-context transitions and 22 lifecycle cases.

## Retained evidence and replay

the original archive contained source/build/provenance under `native/`,
direct/failure/lifecycle/inherited evidence under `helper/`, protocol/control
evidence under `wire/`, independent reviews and root checks. The eleven complete
candidate snapshots and source-restoration helper reconstruct all 8709 entries
from either the original pinned package or explicit prior-AEAD input. Root
validated both modes from the copied payload, existing-destination refusals and
wrong-mode refusal before writing. See `native/HANDOFF.md` for build commands.

The measured programs use Zig Debug optimization. Delivery executable copies
have debug information removed with the recorded existing GNU objcopy
`--strip-debug` option. Native compilation/linking, native/test source,
functional assertions and raw results remain unchanged. The 21 executables
shrink from 380612944 to 105848016 bytes. `delivery_transform/manifest.json` maps
original measured identities to
current delivery identities and verifies allocated sections, entrypoints,
program layout and normalized load bytes. Regular symbol tables remain.
Section-table coordinates and file hashes change as recorded in those maps.
Original `measured_debug_identity.json` and measured-size fields are preserved;
current `prebuilt_identity.json` hashes and explicit delivery sizes identify the
delivered copies. This packaging tool is not a native project-build requirement.

Prebuilt replay needs neither objcopy, a compiler, native archives nor network
access. Choose fresh extraction and external replay directories:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Each replay output must be absent and outside the entire extracted evidence.
The restore tool reads only the checksum-pinned PKI executable from the existing
independent-client artifact. Wrappers verify current binary identities, require
baseline/unreserved RED and reserved GREEN, compare exact protocol/allocation
results and remove owned private PKI in finally blocks. Their combined-root
guards also protect sibling native/helper/wire payloads. Standalone use retains
its own-tree guard. Producer evidence retains nine helper and five wire guard
checks, including valid-tool rejection before output creation.
Both complete Root replays pass after transformation: 78 helper commands and
15 wire commands with their expected statuses. Raw outputs and post-replay
checksums are retained under `root_checks/`.

Ordinary root formatting leaves 314 source/build inputs unchanged, and the
SQL/SQLite-enabled unit suite passes 1158 tests with 24 existing live-PostgreSQL
tests skipped without fixture settings.
Conventions, release metadata and documentation-link checks also pass.

Ticket/session and error/reconnect allocation, maintained native publication,
production adoption and PostgreSQL's complete allocation gate remain open.
Dedicated smoke, security, sanitizer, fuzz and scan campaigns remain user-deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `6481bb5036e2b33806445895c076077e0d5b562c8aea9f5e9b840e1eed13801f`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
