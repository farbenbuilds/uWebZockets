# Bounded client post-handshake buffer candidate

This isolated native candidate adds
`SSL_reserve_client_post_handshake_buffer` for completed, idle ordinary TLS 1.3
clients. It reserves incoming handshake storage during startup, retains it
across messages and rejects growth beyond a fixed logical bound. Existing
record reservation and generic unreserved behavior are preserved. Production
pins and the strict PostgreSQL allocation gate remain unchanged.

The baseline is the reviewed
[fixed-storage HKDF candidate](../../sql_tls_hkdf_fixed_v1/2026_11_17/README.md)
on BoringSSL `d3bf4795ad5b79d646cddf2fec687da5b9b502db`. Exactly four of 8709
native entries change: the public header, internal state, SSL lifecycle/setter
and handshake-buffer implementation. The HKDF source remains identical.
Six files differ cumulatively from the original pinned package. The source
diff and full snapshots are retained inside the archive, not as build overlays.
The complete SSL/crypto Debug build passes all six steps, including all 38 SSL
translation units. No FIPS certification or production adoption is claimed.

## Bounds and contract

The opt-in captures `M = max(16384, SSL_get_max_cert_list(ssl))`. Before an
accepted record, an incomplete head occupies at most `M + 3` bytes; one whole
decrypted TLS record can add 16384 bytes. Consuming messages decreases length,
and oversized incomplete heads fail before another append. Thus the reserved
logical bound is `L = M + 3 + 16384`, including whole-record trailing slack.
This preserves existing message validation rather than assuming a separate
complete-message size check.

| Default quantity | Measured value |
| --- | ---: |
| Captured message ceiling M | 102400 bytes |
| Logical append limit L | 118787 bytes |
| Rounded BUF_MEM data capacity A | 158384 bytes |
| New startup C allocations | 2 malloc calls |
| New startup requested bytes, including descriptor/native prefixes | 158424 bytes |
| SSL3_STATE size before / after | 600 / 608 bytes |

Rounded capacity is not extra logical capacity. Later `SSL_set_max_cert_list`
calls clamp increases to M; lowering and re-raising within M work, and the
getter exposes the effective setting. Context setters and unreserved SSL
remain generic. `SSL_clear` frees the reservation and removes the restriction.

Eligibility excludes servers, DTLS/QUIC, initialization, errors, shutdown and
pending plaintext, records, writes, messages, handshake plaintext or flights.
The caller must verify the peer certificate and hostname first. Temporary
descriptor/data allocations commit only after success; failure preserves prior
ownership and configuration. Idle repeated calls allocate nothing. Consumed
retained tails are cleansed; destruction follows BoringSSL's OPENSSL_free
contract. Actual full-allocation cleanse/free observations cover the default
OPENSSL/glibc path used here, not custom allocator-hook implementations.

## Allocation and encrypted protocol results

After a real verified TLS handshake, the direct helper fixture runs 64
fragment/coalescing loops and near-M input with a full final-record append.
The unchanged baseline counts 258 malloc/free pairs and 272600 requested bytes;
its strict zero-allocation assertion fails. The reserved candidate passes with
zero malloc, calloc, realloc, free and requested bytes. Exact-L appends,
L+1/A+1 rejection, partial-length overflow, pointer/capacity stability,
vacated-tail cleansing and configuration/idempotence checks also pass. These
are internal buffer-helper proofs, distinct from encrypted protocol tests.

A separate real encrypted peer fixture passes twelve scenarios in three
configurations: original baseline, new library unreserved, and new library
reserved. Ten rows exchange exact application payloads; two preserve protocol
errors. Callback sequences, payloads, error/reason results, retries and peak
logical lengths match; each complete callback also matches the known server
plaintext byte for byte. Each configuration reconciles 383 client operations.
The near-limit case reaches exactly 118787 buffered
bytes; the reserved pointer and capacity remain stable. The server fixture uses
native record sealing and BIO delivery; it never stages client parser state.

The existing public control witness repeats four scenarios across three fresh
verified pairs each: twelve rows and 255 metered client operations per build.
The same all-C counter and 63-byte self-test are unchanged. The witness adds
only an explicit startup reservation option. Each client SSL read/write and
its immediate error mapping is metered; peer preparation, startup, payload
validation and logging are outside those intervals.

| Client phase | Prior malloc/free | Reserved malloc/free | Prior bytes | Reserved bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload read | 0/0 | 0/0 | 0 | 0 |
| Two initially queued tickets, caching off: read | 14/14 | 12/12 | 2128 | 1600 |
| Peer KeyUpdate, no response requested: read | 3/3 | 1/1 | 656 | 608 |
| Peer KeyUpdate, response requested: read | 9/7 | 7/5 | 1464 | 1416 |
| Following client response/application write | 0/2 | 0/2 | 0 | 0 |

These vectors are stable across three repetitions; calloc/realloc remain zero.
Tickets were queued by the initial handshake and delivered after reservation.
These are synthetic TLS/BIO client-call counts, not PostgreSQL query counts.
AEAD, ticket/session, outgoing-flight and error/reconnect allocations remain
separate work. No PostgreSQL allocation exception is approved.

## Lifecycle, inherited checks and replay

All 21 new reservation cases pass. Descriptor/data allocation failures preserve
prior ownership/configuration, destroy temporary storage and allow retry on the
same SSL. The separate fault observer verifies actual default-allocator
cleansing and exactly-once frees, not whole-process leak freedom. Pending
plaintext/record/write states preserve their bytes and support valid traffic
continuation. Queued KeyUpdate and backpressured-flight cases use real TLS
output and the native canonical flight-flush helper; their scope is distinct
from the public encrypted peer tests. Shutdown, saved fatal-read error,
protocol/role exclusions, configuration bounds and verified clear/re-handshake
reuse pass. DTLS/QUIC exclusions use configured objects, not completed handshakes.

The unchanged inherited fixtures also pass against the complete changed native
library: sixteen record-reservation cases, both buffer/record helpers, and
1440 HKDF differential cases with 700 successful calls counting zero heap
operations and 740 unchanged rejections. Preliminary fixture corrections are
retained and labeled; final results and hashes identify the actual tested code.

Ordinary root checks pass: formatting leaves 314 source/build inputs unchanged,
conventions and release-version checks pass, and the SQL/SQLite-enabled unit
suite reports 1158 passed with 24 existing live-PostgreSQL cases skipped because
their fixture settings were unavailable. Dedicated smoke, security, sanitizer,
fuzz and scan campaigns remain user-deferred. The earlier standalone HKDF patch
packaging error was corrected separately at `d88dd57`; no gate was weakened.

the original archive retained native source/build/provenance under `native/`,
helper/lifecycle/inherited proofs under `helper/`, encrypted/control proofs under
`wire/`, and independent reviews plus root verification. Source restoration from
the original pinned package or explicit prior-HKDF input is documented in
`native/HANDOFF.md`; both restore all 8709 candidate entries exactly.

From this result directory, choose fresh extraction and external replay paths:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Each output directory must be absent and outside the extracted evidence. The
restore helper reads only the checksum-pinned PKI executable from the existing
independent-client artifact. Replays verify retained binary identities, require
baseline RED/candidate GREEN, compare exact protocol/allocation results and
remove owned private PKI in finally blocks. No compiler, native archives or
network access is needed for prebuilt replay. Root validates both commands from
the delivery layout. Python serves evidence tooling, not the project build.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `bd59c7d647b0924e3b9db99896a9a59e23a8bd752eed95a041d61781eea712af`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
