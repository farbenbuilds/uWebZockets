# PostgreSQL TLS allocation audit, 2026-11-11

**Strict all-C steady-query allocation gate: FAILED.** Verified TLS queries allocate inside pinned upstream BoringSSL after startup and warmup. This evidence does not approve a TLS allocation exception; the approved SQLite exception SQL-ALLOC-001 does not cover this boundary.

The same ReleaseSafe probe ran one in-flight read query against the same PostgreSQL 17 loopback fixture, with eight initialized pool connections, 16 warmups and 256 measured successful queries per mode. Startup, handshake, authentication and warmup were excluded. Every query returned one valid row; both runs had zero query errors.

| Per measured query | Plaintext development control | Verified TLS 1.3 |
| --- | ---: | ---: |
| malloc calls | 0 | 2 |
| calloc / realloc calls | 0 / 0 | 0 / 0 |
| non-null free calls | 0 | 2 |
| requested C bytes | 0 | 213 |
| measured queries | 256 | 256 |

TLS totals were 512 malloc calls, 512 non-null frees and 54,528 requested bytes. Both malloc return addresses in every TLS query resolve to `bssl::SSLBuffer::EnsureCap` at `ssl/ssl_buffer.cc:72` in BoringSSL revision `d3bf4795ad5b79d646cddf2fec687da5b9b502db`, package `N-V-__8AAA5Ieg5843crc8uXWdNhmmfStwJqA-9TknJSx3_n`. Its record buffer has only a five-byte inline header buffer, directly allocates larger records with C malloc, and frees external storage after consumption/flush. Startup BIO allocation and warming up do not retain this storage.

No suitable supported per-session caller-owned record-buffer or allocator API was found in the inspected pinned public SSL/memory headers. `SSL_CTX_set1_buffer_pool` pools certificates. This audit implements no new record layer, key handoff, vendor patch, allocator policy or TLS weakening. A narrow SQL-ALLOC-002 policy proposal remains pending explicit user approval outside this artifact.

The original archive contained the measured Linux x86_64/glibc executable, test-only malloc-family wrapper and self-test, probe/build/runner sources, all 512 raw sample rows, run logs, address attribution, source snapshots and checksums, provenance, reproduction instructions and an independent verifier. SHA-256 manifests cover the outer artifacts and every archived evidence file. No fixture credentials or runtime certificates/keys are included.

Verify from this directory, then inspect the extracted source audit and reproduction instructions:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

The verifier exits successfully when evidence integrity and the captured failed-gate result agree; it does not pass the strict allocation gate. Add `--enforce-zero` to run that gate: it intentionally exits 1, as recorded in the archive. The recorded executable SHA-256 is `eb871819b77fd8cf1213f333cc3b299148867194a0baea2017f464bc4896ec5b`. Rebuilding requires the working-tree source versions identified by the archived source hashes, since this is an uncommitted v2.3 implementation rather than HEAD alone.

Scopes start immediately before `Db.query` and end at the start of its completion callback. The existing begin trace hook runs after connection execution and would miss synchronous writes. Counters cover malloc/calloc/realloc/non-null-free on the query worker thread, with direct glibc forwarding and an in-binary 63-byte self-test. They exclude other threads, direct mmap/aligned allocation APIs, result validation, output and teardown. Those limits do not negate the observed malloc calls, but zero in the control does not prove all-process zero allocation. Byte counts apply to this fixed cached query, and represent requested bytes rather than retained memory. Post-handshake KeyUpdate/tickets, errors, reconnects and larger/fragmented responses were not forced. No throughput or latency claim is made.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `eecb317c1f0f65de6106a95f2bd581746925317fd0dda4d7be5809a8d022bb3d`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
