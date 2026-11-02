# Combined HTTP/2 disconnect and reuse evidence

[combined-disconnect-reuse.tar.gz](combined-disconnect-reuse.tar.gz) contains
reviewed source and pure in-memory public-codec evidence for two schedules.
The [manifest](manifest.json) binds the archive and all 33 current module
hashes. `INVENTORY.json` records every other member's size and SHA-256; members
are regular UTF-8 files with safe relative paths.

The archive preserves the pushed 31-module B6b baseline, current/failure
snapshots, initial selection-only RED, intermediate corrections, 40 current
normal/optimized command receipts, the earlier matrix, immutable references,
source review and Root audits. Paused-session source restoration and preserved
history are recorded separately from test execution. Some initial historical
commands were not retained; their raw outcomes remain qualified in the report.

Exact J/C/R is 25/24/64 for disconnect over two connections and 389/389/288
for nine-upload reuse. Eleven body records change. Each new-suite mode has
four positive case executions and 41 named synthetic rejections plus focused
seam checks. Shared and standalone final collections validate all 67 statuses
plus metrics. Source coverage is 38/40; both shutdown selections remain
unsupported before effects.

The identity audit distinguishes 119 retained rows from 114 unique entries
and checks all 42 codec files. Pinned commands, inputs, raw receipts and exact
history qualifications are in the archived report. Source/licenses are
included; native binaries and caches are excluded. Supplied app/TLS/EOF facts
prove source ordering only. Native ownership/close/callback/body-slot reuse,
full40/default/aggregate acceptance, runtime closure, full gates and production
adoption remain open. See the
[focused report](../../m2_h2_combined_disconnect_reuse.md).
