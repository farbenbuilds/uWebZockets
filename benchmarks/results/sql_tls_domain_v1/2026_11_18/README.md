# Explicit native allocation domain and owned CBB, 2026-11-18

This isolated source proposal adds explicit allocation provenance to native
memory and growable CBB buffers. It is the first owned-memory leaf needed by
the [lifecycle allocation work](../../sql_tls_lifecycle_inventory_v1/2026_11_18/README.md).
It does not implement a complete TLS allocator, prove a total capacity bound,
or change production dependency pins.

## Contract and source

`OPENSSL_malloc_with_domain` and `CBB_init_with_domain` accept a borrowed,
immutable `OPENSSL_ALLOCATION_DOMAIN` descriptor with explicit context,
allocation and release callbacks. The descriptor must survive its last free.
Callbacks provide `max_align_t`-aligned raw storage and must not call BoringSSL.
Allocation and freeing must occur within one compatible native image.

Owned blocks retain the descriptor in an extended header. Generic free and
realloc preserve ownership, cleanse the complete raw extent before release,
and preserve the old allocation on failed realloc. Native object lifetimes are
explicitly begun with placement construction. Ordinary allocation retains its
8-byte prefix and existing weak-hook/sized-free behavior; hook-owned memory is
rejected before any provenance prefix is read.

Owned CBB supports zero capacity, growth, children, finish/transfer, Array
ownership and DER SET sorting scratch. Allocation failure remains sticky and
cleanup-safe, including zero-capacity initialization and partial scratch
allocation. It cannot silently fall back to the C heap. Fixed buffers retain
their existing contract and never undergo owned-prefix lookup.

Exactly five files differ from the complete unpublished parent
`f6176c03304e835d315cf4d9cbd86fc27e979f95`:

- `include/openssl/mem.h`
- `crypto/mem.cc`
- `crypto/mem_internal.h`
- `include/openssl/bytestring.h`
- `crypto/bytestring/cbb.cc`

The final diff SHA-256 is
`45e1ca6ea7e1ffa1b52262017f09b4ae5e80debbc0935f4a5cc9fcbaedb0e52b`.
All 8709 source files and modes were compared with the actual parent; there
are no added/deleted files or mode changes. Complete final/parent identities
and the five replacement files are retained. The parent's inherited producer
labels are historical; its byte/mode entries were freshly verified.

## Verification

The parent fails the retained public API compile probe because the new API is
absent. This is compile-time RED, not a claimed behavioral test. The final
native ReleaseSafe proof passes 26/26 build steps and 14 cases. Thirteen
measured owned/negative/fixed cases report zero malloc/calloc/realloc/free and
requested bytes after explicit ERR-queue warm-up. Ordinary allocating controls
also pass. The unchanged all-C counter's 63-byte self-test passes.

Coverage includes interleaved domains, 100 reuse cycles, opaque typed backing
storage, zero/overflow/OOM, failed realloc preservation, complete release
cleansing, DER sorting scratch failures, children, ownership transfers, Array
moves and replacement, full/partial weak hooks with guard pages, and ordinary
and owned sized-free paths. The sized-free variant compiles a complete second
native crypto image; it does not replace a single object in another image.

An independent reviewer found a C++ metadata object-lifetime defect in the
first generation. Placement construction fixes it; the complete source and
functional re-review found no remaining actionable issue. First-generation
sources, intermediate build failures and original reports remain historical
evidence. The canonical final identity is in `source_identity/`.

The isolated prepared SDK, using this complete native image and matching
headers/source lists, passes all **1189/1189** ordinary live PostgreSQL/SQLite
tests. SQL+SQLite ReleaseSafe `test-compile` and ReleaseFast `lib` each pass
24/24 steps. `test-compile` compiles the C API smoke executable without running
it. The production-pinned root unit run passes 1158/1182 tests with 24 live
PostgreSQL tests explicitly skipped. Formatting, conventions and release-version
checks pass. No dedicated smoke/security/sanitizer/fuzz campaign was run.

## Restore and replay

the original archive retained the proposal, contract, proof sources, exact
seven executed Linux x86-64 binaries, logs, reviews, a 497-file prepared SDK,
and a restoration helper. `files.sha256` hashes every other payload file.
`payload_identity.json` additionally records the copied input modes. No private
fixture credentials, generated PKI, build caches or stale installed libraries
are included.

After extracting into `$packet`, run `sha256sum -c files.sha256` there. The
seven executables in `bin/` can be rerun directly on a compatible Linux x86-64
glibc host. Each must exit zero. The retained complete parent is an explicit
external input available from the preceding
[readiness](../../sql_tls_readiness_v1/2026_11_17/README.md) and
[source proposal](../../sql_tls_source_proposal_v1/2026_11_17/README.md) artifacts;
it is not fetched from an unpublished remote.

```sh
python3 "$packet/restore.py" --parent "$complete_parent" \
  --output "$new_scratch_output" --zig "$zig_0_16_0"
```

Restoration verifies all 8709 parent files/modes, copies the full source tree,
replaces only the five recorded files, verifies all 8709 final files/modes,
and rebinds the retained SDK builder path to that complete image. It then
builds and runs the normal source-list proof with the exact Zig 0.16.0 binary
SHA-256 `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
Omit `--zig` to restore without building. Outputs must be outside the artifact.
This complete restoration and proof were rerun from the staged packet during
packaging; `restoration_evidence/` retains their result. Delivery review also
found that Python optimization could disable assertion-based identity checks,
and unusual path characters were not escaped for Zig. The final helper uses
explicit checks and encodes the native path as Zig string bytes. Negative
optimized-mode identity checks and a full optimized-mode rebuild pass;
`helper_regressions/` retains them. Output paths containing quotes, backslashes
or control characters are rejected before creating output. Zig 0.16 failed
native source lookup in the attempted unusual-path rebuilds; those attempts
and the rejection regressions are retained.
Python is a restoration tool,
not a native build dependency; compilation uses Zig's native toolchain.

Descriptor lifetime, raw alignment, exact-base-pointer use and same-image
freeing remain caller requirements. Cold ERR initialization, owner propagation
through SSL/BIO/X509/ASN1/EVP/RSA/BN/ERR and thread state, cross-target proofs,
consumer pressure/OOM integration, production publication/pins and the full
PostgreSQL zero-allocation gate remain open. No PostgreSQL allocation exception
has been granted; the approved SQLite exception remains SQL-ALLOC-001.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `cd56dff6e81d4111d41d9f06651b07c60853107806b69fa71d9ad9b59c0607b9`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
