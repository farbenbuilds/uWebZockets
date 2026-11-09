# Combined native HTTP/2 evidence

See the [checkpoint report](../../m2_h2_native_matrix.md) and
[manifest](manifest.json). `native_matrix.tar.gz` preserves the reviewed
provider packet plus Root source, review, verification and failure records.
The final evidence index covers four actual accepted runs and their eight raw
captures. The later failed physical-input audit is retained; temporary recovery
is pending and excluded.

Every archive member is regular UTF-8 text. `INVENTORY.json` records member
sizes and hashes. `PACKET_INDEX.json` maps each original provider-relative path to a
content object, its UTF-8/base64 encoding, original byte count, SHA-256 and mode.
Repeated snapshots share objects without losing paths or bytes. To reconstruct
one logical file, read the named object, decode base64 only when requested by
its index row, then verify its original size and SHA-256. Apply the recorded
mode only when materializing a reviewed destination. Root records are under
`evidence/`.

Useful logical paths are `native-final/<run>/acceptance.json`,
`native-final/<run>/child_0.capture.bin`, `child_1.capture.bin`, the four derived
`native-final/<run>.json` reports, and `snapshots/119_listener_preflight/`.
Run names and accepted JSON hashes appear in the checkpoint report. Raw capture
objects are losslessly encoded, not replaced by summaries.

The archive contains no generated certificate/private-key files, private
environment captures or executable fixture binaries. The historical source
reconstruction and compiler recipes are in the preceding
[rehydration](../m2_h2_native_rehydration/README.md) and
[build](../m2_h2_native_builds/README.md) packets. A fresh machine still needs
the documented tool/runtime prerequisites; this artifact is not a self-contained
bootstrap or a fresh execution receipt.
