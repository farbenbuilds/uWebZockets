# Native receive publication snapshot checkpoint

Local candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`, directly atop
`c8cf3fbc201a5d6f6acb6ae45af476cfcd5d7840`.
Date: 2026-11-17, Asia/Bangkok. This candidate is not fork-pushed or pinned.

The receive snapshot adds `LSQUIC_SRS_WEBTRANSPORT_PUBLISHED` at bit 128,
reflecting the existing native publication flag without changing structure
layout, callback scheduling or lifetime. The flag means typed state has been
published; its typed callback may still be pending. Root uses it during normal
child close to distinguish published NULL-context children from streams that
never published. It is not evidence of typed-callback completion inside the
initial receive observer. Connection teardown abandons its accounting.

The strengthened native receive fixture checks false before publication and
during delayed SETTINGS, true in receive/typed notifications, and consistent
close snapshots including NULL contexts and observer-triggered connection abort.
The pre-change getter fails the actual observer assertion; the final getter
passes all eight receive groups in Debug, ReleaseSafe and ReleaseFast. Three
inherited WebTransport/reset fixtures and 83 Linux assertion run cases also
pass. Independent source review is clear.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
internal `evidence_manifest.sha256`. The original archive retained exact source, the
incremental Git bundle requiring c8, patches, replay scripts, raw RED/GREEN
logs and individual log hashes. The parent source and history are retained in
the [receive-observer checkpoint](../../lsquic_receive_observer_v1/2026_11_17/README.md).

Positive Root flow enforcement, multi-session activation, independent-client
acceptance and maintained-fork publication remain open. Dedicated smoke/security
campaigns remain user-deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `753083ac2454662c5a1a55717811899cfd682dd3cf45c4fb47b0081ad2da360c`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
