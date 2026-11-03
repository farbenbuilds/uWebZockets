# Shared pause/control peer evidence

[combined-pause-peer.tar.gz](combined-pause-peer.tar.gz) contains current source,
preceding source, immutable reference inputs, raw checks, source/evidence audits
and independent review. [manifest.json](manifest.json) binds archive size/SHA256
and the complete 40-module source map. `INVENTORY.json` inside the archive binds
every other member by size and SHA256. Members are regular UTF-8 text with safe
relative paths; compiled output is not included.

`source/current/` contains all 40 modules; `history/core-async-source/` preserves
the preceding accepted source. Only `test_pause.py` changed. `raw/pause-peer/`
retains the fresh pre-edit baseline, all failed/intermediate attempts, complete
per-check command/raw/exit/source/restoration records, guarded proof/recorder/
audit helpers, final source maps and evidence inventory. `evidence/` retains
Root's task brief, full report/diff, independent review, metadata audits,
publication helper and pinned source-only restorer. `reference/` retains the
unchanged contract/core/helper/codec source inputs and license metadata.

Current covering receipts are `cover-pause-normal`, `cover-pause-optimized`,
`cover-imports-normal`, and `cover-imports-optimized`. Direct proofs are
`final-direct-normal` and `final-direct-optimized`; strict audit receipts are
`cover-audit-normal` and `cover-audit-optimized`. All eight exit 0 with empty
stderr. Earlier successful checks remain historical and distinct from these
final bindings. Exact commands and environments are recorded per invocation.

The initial constructor RED is pre-effect absence; the initial timing RED is
an unfinished send hook. They are not wire-defect proofs. Later send-span RED
is a behavioral pre-fix proof. The report qualifies the corrected premature
diagnostic expectation against an actual frozen-baseline execution, additive
restoration-reference correction, audit cwd correction, and Root's failed
metadata invocation. Historical failures are retained rather than rewritten.

Input restoration copies only exact pinned source bytes from committed
archives and verifies all physical inputs plus the ordered codec aggregate
before the dependent operation in the same shell. It installs nothing and
restores no compiled binary. The actual four-case prior chain is earned from
traffic; the separate copied producer retention fixture remains explicitly
supplied synthetic state.

These are in-memory codec observations with synthetic peer/application facts.
The [report](../../m2_h2_combined_pause_peer.md) distinguishes standalone peer
preparation from actual all40 coordination, native correctness, production
adoption and milestone completion. Those broader gates remain open.
