# PostgreSQL TLS record-buffer reservation experiment

An isolated BoringSSL prototype removes the two observed record-buffer
allocations from the warmed cached-query case. Production source and dependency
pins are unchanged. SQL-ALLOC-002 remains open; no PostgreSQL allocation
exception has been approved.

The exact pinned native baseline is
`d3bf4795ad5b79d646cddf2fec687da5b9b502db`. The four-file temporary native patch
adds an explicit post-handshake reservation API and retains bounded record
buffers until SSL destruction. The temporary SQL caller opts in after TLS 1.3
handshake and certificate verification, before PostgreSQL startup/readiness.
It reserves 131070 bytes per SSL connection, in addition to existing buffers.

| Verified TLS cached-query case | Allocator calls per query | Requested bytes |
| --- | --- | --- |
| Archived audit binary rerun | 2 malloc + 2 free | 213 |
| Rebuilt native prototype, reservation off | 2 malloc + 2 free | 213 |
| Same prototype, reservation on | 0 | 0 |

Each comparison measured 256 queries, with one in flight after startup/warmup;
plaintext controls counted zero. Result checks require one row, ID equal to 1,
and successful integer decoding of column two. The probe does not compare that
second value with the fixture's 42. Query validation runs after accounting ends.
The exact probe/interposer are unchanged from the
[original audit](../../sql_tls_allocation_v1/2026_11_11/README.md).

Ordinary functional proofs cover full retained capacity, alignment, compaction,
cleansing before actual free, verified TLS maximum-size records through a
1024-byte BIO under short reads, and reservation reset by SSL_clear. Independent
read-only native lifecycle review found no confirmed defect in the documented
opt-in path. It corrected the result-validation claim above.

Reservation allocation failures, additional pending/protocol API preconditions,
re-handshake after SSL_clear, other post-handshake allocation paths and native
maintenance/integration still require proof. These measurements do not close
the production strict-allocation gate or establish production interoperability.
Dedicated smoke/security/sanitizer/fuzz campaigns remain user-deferred.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
internal `files.sha256` (48 payloads). The archive retains the native/caller
patches, test sources, raw results, source hashes and review. Ephemeral database
credentials and private fixture material were removed; the existing database
on port 55432 was untouched.
