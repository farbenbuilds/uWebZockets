# Certificate allocation operation prerequisite, 2026-11-18

This experimental checkpoint adds a private BoringSSL allocation operation
for later certificate-path ownership. It tracks allocation failure across
error-queue changes and takes the destination owner explicitly. Resize and
final free retain the allocation’s original owner, including after the
operation ends. The native delta is one internal header,
`crypto/cert_alloc_internal.h`.

The unchanged all-C allocation counter recorded zero events and zero requested
bytes in five of six warm rows. The ordinary warm control recorded two mallocs,
two frees and 64 requested bytes. Cold full-hook refusal set the sticky failure
status before any domain or weak-hook callback. Cold error reporting recorded two
callocs and 984 requested bytes.

The producer build and a fresh restored build each passed all 71 ReleaseSafe
steps across `proof`, `wire-proof` and `cert-operation-proof`. All 17 malformed
inputs were refused in both ordinary and optimized Python, for 34 passing
checks. The archive retains the initial missing-header compile failure, the
first cold runtime failure caused by a malloc-only assertion, the revised proof,
and the passing logs with their commands.

Full certificate-path ownership, native capacity sizing, SDK integration and the
unchanged worker-wide lifecycle proof remain open under R3/R4. The strict
PostgreSQL zero-allocation gate remains RED.

## Evidence and identities

The archive contains the private header, 21 proof sources, the original Zig
proof builder, the operation contract, the external parent inventories, the
restore helper and raw evidence. Nineteen inherited proof inputs, including the
all-C counter, retain their parent bytes and modes. `files.sha256` covers all
archived payload files and their mode inventory, `payload_identity.json`.

| Input | SHA-256 |
|---|---|
| 8,710-file native parent identity | `6fb0396e4a2a2b29d95d109e12f9ce64a52cf708479062a39da245e981a1f766` |
| 503-file SDK parent identity | `5e2a5c8b807782fbfc095f944b9ac64ef2d48909ed1ad92683a4b88d9f9dfd5f` |
| 8,711-file native candidate inventory, canonical JSON | `b05901a94856106100ffdadf0e3021202ac95f6f813e86517406bafd3462686f` |
| Operation contract | `116002095ff97d6cc9399c30feeb43bc1342df73859a65e13b3611ffec0aeca1` |
| Private allocation header | `baf0ce713529bca462b04577b37a468b39fe7848c93438b547d19b714d193356` |
| Packaged input identity | `b9cf0bfaa9317013429520f6971cada58ddaadc491ed759cded88fe0d380ce15` |
| Zig 0.16.0 x86_64 Linux executable | `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |

## Reproduction

Use x86_64 Linux, Python 3.11 or newer and the pinned Zig 0.16.0 toolchain.
Restore the native parent using the preceding client wire-storage checkpoint.
Use that restore’s `boringssl/` directory and the preceding packet’s extracted
`sql_tls_client_wire_storage/sdk/` directory. The extracted SDK retains the
builder bytes and file set required by the parent identity.
[Client wire-storage checkpoint](../../sql_tls_client_wire_storage_v1/2026_11_18/README.md)

From this result directory, set absolute paths and preserve file permissions
on extraction. Choose absent extraction and replay paths in the workspace cache.

```sh
EXTRACT=/workspace/.zig-cache/absent_cert_operation_packet
REPLAY=/workspace/.zig-cache/absent_cert_operation_replay
PARENT_NATIVE=/workspace/.zig-cache/wire_parent_replay/boringssl
PARENT_SDK=/workspace/.zig-cache/wire_parent_packet/sql_tls_client_wire_storage/sdk
ZIG_016=/workspace/.zig-cache/toolchains/zig-x86_64-linux-0.16.0/zig

sha256sum -c manifest.sha256
mkdir "$EXTRACT"
tar --extract --gzip --file raw_evidence_archive.tgz --directory "$EXTRACT" --same-permissions --no-same-owner
PACKET="$EXTRACT/sql_tls_cert_operation"
(cd "$PACKET" && sha256sum -c files.sha256)
python3 "$PACKET/restore.py" --parent-native "$PARENT_NATIVE" --parent-sdk "$PARENT_SDK" --output "$REPLAY" --zig "$ZIG_016"
```

The restore checks the complete path, hash and mode sets of both parent trees
and of its packaged inputs before creating the replay directory. It copies
the parents, adds the one private header, and rebinds the SDK builder’s single
native source path. Zig builds the three original targets from their source
graph. `proof.log` and `restoration.json` record the result. Pass
`--global-cache /absolute/existing/zig_cache` to reuse an existing cache, as
in the recorded fresh replay. The proof runs with the compiler and pinned
parent sources alone.
