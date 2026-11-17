# Reusable TLS fatal-error snapshots

Isolated native proposal for v2.3.0 PostgreSQL TLS allocation work. Production
sources, dependency pins and release status are unchanged. No PostgreSQL
allocation exception is approved.

`SSL_reserve_error_state` prepares two independently owned, fifteen-entry error
snapshots for an idle, completed ordinary TLS 1.3 client. It preserves the full
error queue, alert behavior and generic arbitrary-length diagnostic copies.
The persistent read snapshot and temporary alert snapshot cannot share storage:
alert output may call another SSL and replace the thread's error queue.

The native Debug build passes all six steps and compiles all 38 SSL translation
units with matching crypto through Zig 0.16.0. The six-file increment preserves
the default generic error-snapshot layout and allocation path; the cumulative
proposal changes fourteen native files. Reservation adds
two startup malloc calls totaling 736 requested bytes on this host; connection
state grows from 640 to 656 bytes. A worker must initialize its own error queue
before counted use; warming another thread is insufficient.

## Complete-call allocation measurements

The unchanged all-C interposer and its 63-byte self-test count malloc, calloc,
realloc, free and requested bytes over each complete client operation and
immediate SSL_get_error. Five verified CA/localhost pairs negotiate suite 0x1301
and exchange exact 4096-byte payloads in both directions before the fault.
Observe, metadata-only, peer-data and full-zero selectors execute the same 163
calls and retain byte-identical raw outputs within each variant.

| First fatal client read | Prior malloc/free/bytes | Reserved malloc/free/bytes |
|---|---:|---:|
| Empty NewSessionTicket | 2 / 0 / 40 | 0 / 0 / 0 |
| Duplicate recognized ticket flags | 4 / 2 / 80 | 0 / 0 / 0 |
| Corrupted authenticated record | 4 / 2 / 128 | 0 / 0 / 0 |
| Oversized record header | 4 / 2 / 80 | 0 / 0 / 0 |
| Public peer fatal alert with text | 4 / 0 / 124 | 2 / 0 / 84 |

All 29 metadata-only fatal/repeated/cross-SSL calls count zero heap operations.
The 125 warm calls also count zero. Nine peer-data calls still total seven
mallocs, five frees and 184 requested bytes; individual free timing follows queue
ownership. The metadata gate passes; peer-data and full gates remain RED. The
new unreserved control exactly matches the prior library's per-call counts.

Full ordered reasons, file/line sites, data, flags and alert observations match.
The bad-MAC case retains both cipher and SSL errors. Peer-fatal writes retain
their existing successful result and exact peer payloads; the other four cases
reject writes. A popped error string remains valid after SSL_free until the
thread's next queue modification. Raw locations are retained and seven exact
unchanged source sites are mapped explicitly.

Inherited encrypted protocol checks cover 27 rows and 1320 client calls,
including eighteen fatal rows across suites 0x1301, 0x1302 and 0x1303. Twelve
public control rows add 255 calls. All reserved counts are zero; current
unreserved outputs match the immutable prior evidence exactly.

Seven direct cases cover queue order, marks, cross-snapshot ownership, long
text, shrink cleanup and cold/warm worker behavior. Three copy-OOM and trailing
data cases run against each library. Public controls cover both startup failure
ordinals, seventeen state guards plus null, idempotence/sibling isolation and
the preserving/destructive clear boundaries. Both reserved owners free once;
the watched 656-byte connection state is erased before release.
An authentic nested BIO callback preserves independent error queues, and two
cold-thread initialization failures clean up before a successful retry. Final
delivered copies pass 86 native and eighteen wire replay commands.

## Scope and reproduction

The archive retains the source increment and cumulative proposal, exact source
inventories/restoration tools, native build identities, functional and ownership
fixtures, raw records, selected replay programs and independent reviews.
Its README and handoffs describe the precise commands and external inputs.
The outer manifest binds the archive; its internal files.sha256 binds every
retained payload file. Delivery strips debug sections only from staged copies,
with original identities and ELF/load-image proofs retained.

Fatal diagnostic text, query teardown, cancellation and reconnect allocations,
native publication, production adoption and PostgreSQL's full request-path gate
remain open. Dedicated smoke/security/sanitizer/fuzz/scan campaigns remain
user-deferred. This result is not a release or a complete allocation proof.
