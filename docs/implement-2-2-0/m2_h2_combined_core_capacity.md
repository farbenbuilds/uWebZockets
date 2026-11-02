# Shared HTTP/2 peer capacity correction

The shared buffered/large-upload peer now checks remaining parser capacity
before extending its buffer. This closes the shared-peer finding recorded during
lifecycle review. The existing 8201-byte cap, error, valid schedules and other
storage limits are preserved.

The [archive](evidence/m2_h2_combined_core_capacity/README.md) preserves the
38-module source, preceding source, real regression and raw checks. Its
[manifest](evidence/m2_h2_combined_core_capacity/manifest.json) binds exact
identities. Only the shared peer and its driver changed; 36 modules are unchanged.

The regression constructs an actual incomplete serialized frame in allowed send
spans, retaining 8200 bytes. Before the fix, an additional 8192-byte send failed
but left 16392 bytes and an oversized high-water mark. With the guard, two
rejected continuations preserve the exact buffered bytes and high-water mark.
This checks retained Python fixture state, not native allocator behavior or
valid-stream completion.

All six shared/coordinator/import checks pass in normal and optimized Python
with empty stderr. Both actual 100000000-byte upload framings, their incremental
hash and 12208-frame count, the split late refund and existing negative controls
remain intact. Buffered coordinator counts remain 73 heads, 73 small responses,
257 request bytes and 74 supplied reads/29903 received bytes. These read and
byte figures describe the synthetic peer.

All 38 modules pass AST/main-guard and actual inert-import checks. Earlier 4412
recorded evidence hashes and 308 files from the latest published lifecycle
archive match; the new archive retains their maps and provenance without
claiming to duplicate every earlier raw file. Pinned input identity checks cover
118 physical rows and the ordered 42-codec aggregate.

Independent spec and quality review found no actionable issues. The separate
shared-peer capacity finding is closed for this source fixture. Producer/file
peer construction, arbitrary ordinary coordinator composition, disconnect/
shutdown children, actual default/all40 aggregation, broad review, native/runtime
verification, full project gates and production adoption remain required.
M2 remains open.
