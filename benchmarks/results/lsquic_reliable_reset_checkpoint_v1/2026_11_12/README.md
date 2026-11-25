# Paused reliable-reset checkpoint

The user paused implementation and requested a commit on 2026-11-12.
Remaining smoke and security runs are deferred to their follow-up.

The original archive preserved local proposal commit
`3e6c31890cb7c48d933b5114136324c5113fb0a8`, requiring the earlier uni-stream
proposal `0f7382b17b38d7fb0496a0b75b3c66ace79e49e8`. Its Git bundle is review
material and is not a production dependency or build overlay.

Recorded functional evidence includes four wire/parameter Debug checks and
the eight existing encrypted-engine groups after the corrected core. Two
targeted receive regressions failed against the saved earlier source. Their
corrections are present; targeted GREEN checks and the new end-to-end reset
delivery checks remain unrun. Receive advertisement remains held.

Sources and Go-to-Go control results for the pinned reset and draft-16 clients
are retained. They do not establish native product interoperability.

`HANDOFF.md` inside the archive records recovery and remaining work.
`files.sha256` covers retained source, manifests and logs. Binaries, module
caches and private keys are excluded. Earlier dependency and uni-stream
artifacts retain the prerequisite history. Release completion remains open
in `tasks/todo.md`.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `93df62cf1b221b9f25f1b9410e483420fe6d3e3d0417b534380f97457d704509`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
