# Collection handoff evidence

The [manifest](manifest.json) binds a regular, non-executable UTF-8 archive.
`SOURCE_REVISION.json` and the direct `source/canonical/` / `baseline/canonical/`
members contain the exact two-file authority transition.

`PACKET_INDEX.json` maps every retained packet path to an `objects/` member,
original byte count, SHA-256 and mode. Identical contents are stored once. Read
the named object unchanged for `utf8`, or base64-decode it for `base64`, then
verify its original length and hash. This restores logical source/evidence
bytes without duplicating large immutable metadata for every proof snapshot.

`evidence/` retains requirements, architecture, both review verdicts, fix
reports/diffs, independent checks and the completed-snapshot deduplication
receipts. Every archive member has an exact internal inventory identity.
Initial and corrected source proofs remain distinguishable. The broader
provider implementation remains under integration; this checkpoint accepts
the collection-handoff source revision.

The opaque-context guard is identity-only for protocol/hash/callback objects.
Source compatibility and source-only native-entry refusal establish no real
process/TLS/closing/post acceptance. Four actual native full40 runs remain
required. C8 historical acceptance stays immutable; a separate reviewed
two-file override must authorize the revised harness.

The baseline unit SIGTERM interruption and exact-seed passing replay are both
retained with independent triage. No sender was identified. Local snapshot
hardlinks preserve file content/modes/ownership/paths; inode timestamp sharing
is explicitly recorded, with original modification times in the before receipt.
See the [checkpoint report](../../m2_h2_collection_handoff.md).
