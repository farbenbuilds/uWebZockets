# Reliable reset commit checkpoint, 2026-11-13

This preserves the work completed after the main implementation checkpoint
`6e0cb811b78df225d889f113d2b591eeaa23ec11`. The unpublished local proposal
is `c434c4ae3a2ad9f584d2c17536f800623ef36df6`; its Git bundle requires the
earlier uni-stream proposal `0f7382b17b38d7fb0496a0b75b3c66ace79e49e8`.
It is review material, not a production dependency or build overlay.

Focused Debug regressions pass for receive metadata, frame levels, reset
delivery, resumption, partial headers, STOP_SENDING, API behavior, frozen
flow credit, and obsolete ACK recovery. The native lsquic peer also passes
both directions against the pinned independent quic-go client with verified
TLS. Full WebTransport remains unfinished.

The broad upstream Debug run failed six standalone links and one
`send_headers` assertion. The link-selection scaffold correction is saved;
its rerun and the assertion fix remain pending. The ACK batch case is also
pending. No release-completion claim is made. Remaining smoke and security
runs are deferred to the user; no tests or thresholds were disabled.

The original archive retained the proposal Git history, native scaffold, source hashes,
raw functional logs and interoperability results. `HANDOFF.md` records
recovery, evidence limits and remaining work. Dependency caches, binaries and
fixture private keys are excluded. Existing vendor checkout changes remain
untouched. No dependency pin, push, release tag or remote publication changed.

Verify the outer files with `sha256sum -c manifest.sha256`. After extracting
the archive, verify its contents with `sha256sum -c files.sha256`.

Fresh checks of the unchanged main implementation pass: formatting,
conventions, release-version consistency, and all 958 default unit tests
(23/23 build steps). These use the existing published dependency pin and do
not replace the proposal's outstanding upstream-suite validation. The unit
log and root check record are retained in the archive.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `06a47c970601cae49ff6114b69ae5b286d9d3b487850607e51dc9b6f7f5ad1dc`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
