# Shared terminal peer evidence

[combined-terminal-peer.tar.gz](combined-terminal-peer.tar.gz) retains current
source, preceding metadata/concurrency source, immutable reference inputs,
guarded evidence helpers, raw checks and independent source review.
[manifest.json](manifest.json) binds archive size/SHA256 and all 41 current
module hashes. Internal `INVENTORY.json` binds every other safe, regular UTF-8
member by size/SHA256. Compiled output is not included.

`source/current/` contains 41 modules. New test_terminal_peer replaces both
nested peers; the two drivers and import inventory change, 37 modules remain
identical. `history/metadata-source/` preserves 40 preceding sources.
`raw/terminal-peer/` retains the fresh baseline/input/history freeze, every
failed/intermediate version, three current helpers, exact per-command sources,
stdout/stderr/exits and restoration records. `evidence/` retains brief/report/
diff/review, Root audits/publication helpers and pinned source-only restorer.
`reference/` retains unchanged model/core/helper/codec sources and license data.

Current six covering receipts are `cover-v3-{control,application,imports}-`
`{normal,optimized}`. Direct proofs are `final-direct-v3-{normal,optimized}`;
strict captured audits are `strict-audit-v3-{normal,optimized}` with generated
maps under `audit-v3-normal`/`audit-v3-optimized`. All ten exit 0, empty stderr,
and bind current 41 source/check/argv/env/cwd/restoration identities. Earlier
successful v1/v2 versions remain distinct history.

The report distinguishes constructor absence from real HEADERS/DATA/high-water
REDs and the wrong initial retirement seam. Original command metadata remains
as `command-initial.json` where a restoration reference was corrected. Actual
same-shell receipts support the corrected reference; raw/source bytes remain.

The actual mixed six-case chain earns 67 ordinary heads plus final68=135.
Original three-case chains and all negatives remain covered. Fourteen boundary
corruption controls prove driver snapshots; peer facts remain independent.
Restoration copies exact pinned source bytes and verifies physical inputs and
ordered codecs in the same shell; it installs nothing and restores no binary.

The [report](../../m2_h2_combined_terminal_peer.md) separates standalone source
preparation from actual all40, native correctness, adoption and full milestone
acceptance. Those broader gates remain open.
