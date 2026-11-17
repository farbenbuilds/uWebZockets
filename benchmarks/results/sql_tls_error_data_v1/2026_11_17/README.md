# Owned short TLS error data

Isolated native candidate for v2.3.0 PostgreSQL TLS allocation work. Copied
diagnostic text through 31 payload bytes plus NUL uses owned inline storage;
longer text retains complete heap spill. The bounded native peer-alert formatter
now uses that copy path. Production sources and pins remain unchanged, and
PostgreSQL's complete request-path gate remains open.

Each error and the thread's popped-data holder own separate 32-byte buffers.
Queue data never borrows SSL, snapshot or caller storage. Output flags remain
STRING|MALLOCED even for inline text: the pointer belongs to the queue and stays
valid until its next modifying call. Empty text remains distinct from absence.
Valid input flagged MALLOCED is still consumed with OPENSSL_free after copying.
Generic printf/concatenation generation and raw-buffer adoption are preserved.

## Complete-call measurements

The original all-C counter and 63-byte self-test measure malloc, calloc,
realloc, free and requested bytes over each complete client operation and
immediate SSL_get_error. Each verified CA/localhost pair warms exact 4096-byte
traffic both ways with all prior reservations enabled.

| First client read | Prior reserved malloc/free/bytes | New reserved malloc/free/bytes |
|---|---:|---:|
| Peer-sealed fatal0, labeled invalid input | 2 / 0 / 83 | 0 / 0 / 0 |
| Public fatal99 | 2 / 0 / 84 | 0 / 0 / 0 |
| Public fatal255 | 2 / 0 / 85 | 0 / 0 / 0 |
| Public warning close0 | 0 / 0 / 0 | 0 / 0 / 0 |
| One-byte malformed alert | 0 / 0 / 0 | 0 / 0 / 0 |

All 164 measured I/O calls per reserved selector are zero, including repeated
reads/writes and cross-SSL restoration. Separate lifetime checks verify popped
text after SSL_free. The same five cases pass
for actually negotiated 0x1301, 0x1302 and 0x1303. Full ordered reasons, raw
file/line observations, text, flags, callbacks and peer payloads are preserved;
explicit source-site mappings account for changed source lines. Peer-fatal
writes retain their existing successful result, while malformed input rejects
writes. Warning close0 remains distinct from fatal0.

Unreserved controls remain allocating: each fatal first read counts two mallocs
and 72 requested bytes; malformed input counts four mallocs/two frees/144 bytes.
Generic entry arrays grew, so old array-byte equality is intentionally not a
parity claim. Inherited full-fatal checks cover 163 calls, protocol checks cover
27 rows/1320 calls across three suites, and public controls cover twelve
rows/255 calls at their retained 0x1301 scope. All reserved counts are zero.

## Ownership, memory and delivery

Twelve direct rows preserve absent/empty, boundary text, aliases, FIFO/wrap and
marks. Twenty-one expanded cases cover nonuniform long aliases, per-copy and
persistent OOM, input provenance, heap-history frees, peek/pop variants and real
thread destruction. Warm short operations make zero allocator attempts with
failure injection armed. Long text and generic formatters remain positive
allocation controls. Clearing old heap data can legitimately free it.

| Private host object | Prior bytes | Current bytes |
|---|---:|---:|
| Error entry | 24 | 56 |
| Thread error state | 400 | 944 |
| Reserved snapshot | 368 | 848 |
| Two startup snapshots | 736 | 1696 |
| SSL connection state | 656 | 656 |

The generic snapshot header stays sixteen bytes, followed by 56 bytes per
entry. These are measured x86_64 values, not public ABI guarantees. Three
inherited fixture files change only four source-derived size expectations;
their originals and exact deltas are retained. All 51 earlier inputs plus
their record driver remain byte-identical.

The matching Zig 0.16 Debug build passes six steps and all 38 SSL translation
units. Two functional files and two comment-only headers change, fifteen
native paths cumulatively. Independent ownership and maintainability reviews
have no unresolved finding. The archive retains source/restoration inputs,
raw results, compiler/layout proofs, selected programs and delivery records.
Only staged executable copies have debug sections removed, with ELF load-image,
symbol-table, permission and unchanged-input proofs retained.

Verify the outer manifest, then the archive's files.sha256; its README and
handoffs give exact replay commands and external PKI-tool identities. Full SQL
query teardown, cancellation/reconnect allocation, publication and production
adoption remain open. No PostgreSQL allocation exception is approved. Dedicated
smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.
