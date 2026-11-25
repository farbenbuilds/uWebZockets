# Recycled client KeyUpdate context candidate

This isolated native proposal adds `SSL_reserve_key_update_context` for an idle,
completed ordinary TLS 1.3 client. One startup-allocated spare is prepared before
installation; successful installation recycles the replaced active context.
Initializer and install-hook failures recover and cleanse the candidate.
Unavailable or inconsistent ownership never falls back to heap allocation.
Production pins and PostgreSQL's strict allocation gate remain unchanged.

The baseline is the reviewed
[incoming post-handshake buffer candidate](../../sql_tls_hs_buffer_v1/2026_11_17/README.md)
on BoringSSL `d3bf4795ad5b79d646cddf2fec687da5b9b502db`. Exactly six of 8709
native source entries change, with nine cumulative changes from the original
package. Full source snapshots, inventories and the diff are inside the archive.
The final complete SSL/crypto Debug build passes all six steps, including all
38 SSL translation units. No FIPS certification or production adoption is claimed.

## Ownership, memory and ordering

The bounded object set is active RX, active TX and one spare. Three SSL3_STATE
pointers capture the supported cipher, owned spare and temporarily borrowed
candidate identity. Startup failure preserves existing ownership and leaves the
mode disabled. Idle repeated reservation allocates nothing. `SSL_clear` frees
the spare and disables the mode before a fresh handshake.

| Measured default quantity | Value |
| --- | ---: |
| Spare object size | 600 bytes |
| Added startup C allocation | 1 malloc, 608 requested bytes including prefix |
| SSL3_STATE size before / after | 608 / 632 bytes |
| Live context object bound | 3 |

The existing read excess-handshake-data guard and old-key write sealing occur
before swapping active contexts. Traffic secrets commit only after hook success.
Existing alert, message-consumption and flight effects are preserved; failure
does not promise whole-operation rollback. Recycled inline AEAD/key/IV storage
is explicitly cleansed, including nonce-tracker state and nonce/AAD/direction
flags. Touched local key, IV and derived-secret copies use the existing native
cleanup primitive. The generic `Create` body is unchanged.

Callbacks can run while the spare is borrowed. The opt-in requires serialized,
non-reentrant mutating SSL I/O; observation callbacks remain supported. Servers,
DTLS/QUIC, initialization, shutdown/error and pending states are excluded. The
caller verifies the certificate and hostname before reservation.

## Actual encrypted KeyUpdate and controls

Each peer context selects a singleton TLS 1.3 suite through this pin's public
`SSL_CTX_set1_tls13_ciphers`, and both peers assert the actual negotiated ID:
`0x1301` AES-128-GCM, `0x1302` AES-256-GCM or `0x1303` ChaCha20-Poly1305.
Legacy cipher-list settings are not used to infer TLS 1.3 selection.

The primary gate runs eight valid peer updates per suite: 24 no-response updates
and 600 metered client calls per variant. Exact 4096-byte application payloads
travel both ways after every update. Baseline and new-unreserved builds each
count one malloc/free pair and 608 requested bytes per update and fail the
strict zero assertion. The reserved candidate passes the same assertion with
zero malloc, calloc, realloc, free and requested bytes for every complete client
read and application-write interval. The original all-C counter and 63-byte
self-test are unchanged.

The protocol matrix has twelve rows and 783 client calls per variant across
the three suites. Requested responses, repeated/alternating rotations,
coalescing, backpressure/retries, excess old-epoch handshake data and the
consecutive-update limit preserve baseline payload/callback/error semantics.
Twenty-seven header observations see the old active write context while a
prepared candidate is borrowed. Read-guard rejection preserves the installed
read context, its bytes, secret and sequence and restores the same neutral
spare. These observations use real encrypted traffic and native peer output,
without staging client parser or cipher state.

The public control witness repeats four scenarios across three fresh pairs:
twelve rows and 255 metered client operations per build. Startup, peer work,
payload validation and logging are outside client read/write and immediate
error-mapping intervals. The witness adds only the new startup option.

| Client phase | Prior malloc/free | Reserved malloc/free | Prior bytes | Reserved bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload read | 0/0 | 0/0 | 0 | 0 |
| Two initial tickets, caching off: read | 12/12 | 12/12 | 1600 | 1600 |
| Peer KeyUpdate, no response requested: read | 1/1 | 0/0 | 608 | 0 |
| Peer KeyUpdate, response requested: read | 7/5 | 5/3 | 1416 | 200 |
| Following client response/application write | 0/2 | 0/2 | 0 | 0 |

All vectors are stable across repetitions; calloc/realloc remain zero. Initial
tickets were queued by the handshake and delivered after reservation. These
synthetic TLS/BIO client-call counts are not PostgreSQL query measurements.
Ticket/session, response-flight and error/reconnect allocations remain work;
no PostgreSQL allocation exception is approved.

## Direct crypto, failures and lifecycle

The unwrapped direct fixture compares 24 reused/fresh epochs across all three
suites and both directions, including sequence-zero/one behavior, nonce reset,
invalid preparations, AAD rejection and erased inline state. Forty-eight direct
traffic-key transitions keep exactly three distinct objects and count zero heap
operations. Missing, busy and inconsistent spare checks reject without fallback.

A separate injected fixture covers twelve failures after the real initializer
has populated candidate state, including null and live AEAD-pointer cases.
Active keys/ownership remain intact and the candidate is recovered empty.
Fault injection is separate from ordinary allocation accounting. The injected
link uses Zig's bundled `ld.lld` with driver-produced CRT/runtime arguments;
unwrapped measurement fixtures use the ordinary Zig driver. No system linker
is introduced.
Compiler record-layout output supports Linux Debug byte-region inspection
without private-access macros or test-only native accessors; padding is excluded
from erasure claims. Keys and secret snapshots are never logged and are cleansed.

All 22 new lifecycle/failure cases pass, including startup rollback/retry,
eligibility, saved fatal-error preservation, idempotence, clear/re-handshake and
real traffic in both update directions. Write-hook flight-storage failure
preserves the active write key/secret and recovered spare while retaining the
existing consumed-handshake-data/empty-flight-descriptor effects. Actual
cleansing and exactly-once frees cover tracked default OPENSSL/glibc
allocations, not whole-process leak freedom or custom allocator hooks.

Unchanged inherited sources also pass against the final archives: sixteen
record lifecycle cases, both buffer/record helpers, the incoming-buffer helper
and 21 lifecycle cases, and 1440 HKDF differential cases with 700 successful
zero-allocator calls and 740 matching rejections. Preliminary fixture fixes and
the removed unused forwarding predicate are explicitly classified. They do not
weaken the final assertions or change native cryptographic behavior.

## Retained evidence and delivery replay

the original archive contained native source/build/provenance under `native/`,
direct/failure/lifecycle/inherited evidence under `helper/`, wire/control evidence
under `wire/`, and independent reviews plus root checks. Exact source restoration
from the original pinned package or explicit prior-HS input is documented in
`native/HANDOFF.md`; both modes restore all 8709 final entries exactly.

The measured programs use Zig Debug optimization. Delivery executable copies
have debug information removed with the recorded existing GNU objcopy 2.46;
native compilation/linking, native/test-fixture source, functional assertions
and raw results are unchanged.
`delivery_transform/manifest.json` maps original measured Debug identities to
current delivery identities. Producer handoffs/build records retain their
original identities; `helper/prebuilt_identity.json` and
`wire/prebuilt_identity.json` identify the actual delivery copies. Allocated
sections, entrypoints, program layout and
normalized load bytes are verified unchanged; regular symbol tables remain.
The ELF section-table coordinates changed, so file hashes deliberately differ.
See `delivery_transform/HANDOFF.md` for exact tools and comparison rules.
The delivered replay wrappers also exclude the entire combined evidence root
from output paths, with their existing own-tree exclusion retained for standalone
use. This guard strengthening is recorded as a separate delivery step; original
producer wrappers and their hashes are preserved.

Both complete replays pass after this transformation. Prebuilt replay requires
neither objcopy, a compiler, native archives nor network access. From this result
directory, choose fresh extraction and external replay paths:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Each output must be absent and outside the extracted evidence. The restore tool
reads only the checksum-pinned PKI executable from the existing independent-client
artifact. Replays verify delivery binary identities, require baseline/unreserved
RED and reserved GREEN, compare exact protocol/allocation results and remove
owned private PKI in finally blocks. Root validated both documented commands
from the delivered layout. Python and objcopy serve evidence preparation;
neither is a new native project-build requirement.

Ordinary root checks pass: formatting leaves 314 source/build inputs unchanged,
conventions/version checks pass, and the SQL/SQLite-enabled suite reports 1158
passed with 24 existing live-PostgreSQL cases skipped without fixture settings.
Dedicated smoke, security, sanitizer, fuzz and scan campaigns remain user-deferred.
Production adoption and PostgreSQL's complete allocation gate remain open.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `dfa3560044a81f0e2e387d636d9d88cc5734ff55f68c0d29ce5dbd3fc74b208b`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
