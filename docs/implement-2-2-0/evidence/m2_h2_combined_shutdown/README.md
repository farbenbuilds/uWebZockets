# Combined HTTP/2 shutdown evidence

[combined-shutdown.tar.gz](combined-shutdown.tar.gz) contains reviewed source
and pure in-memory public-codec evidence for active and idle shutdown. The
[manifest](manifest.json) binds the archive and all 35 current module hashes.
`INVENTORY.json` records each other member's size and SHA-256; all members are
regular UTF-8 files with safe relative paths.

The archive preserves the 33-module B6c baseline, current and failed-review
snapshots, initial selection-only RED, intermediate corrections, source review
and both fix rounds. The initial 42-command matrix, first-fix six checks and
current six covering checks remain distinct. Three actual alias REDs precede
the private-snapshot correction. Each current shutdown mode records five
positive executions and 78 synthetic rejections. Ordinary collection retains
parsed wildcard diagnostics without extra requests; shutdown publishes its
capture after teardown validation.

Exact J/C/R is 71/70/32 for active shutdown and 69/69/0 for idle. All 67 statuses
plus metrics are collected once per case; active holds the primary throughout
collection, while idle uses fresh synthetic zero state. Source coverage is
40/40 IDs, with no unsupported handler remaining. This does not establish
combined default/subset/aggregate execution or native acceptance.

The audit distinguishes 119 retained rows from 114 unique entries and checks
all 42 codec files. Commands, raw results, source identities and complete failure
history are in the archived report. Source/licenses are included; binaries and
caches are excluded. Supplied facts do not prove native processes, TLS/EOF,
callbacks, ownership or post-deinit behavior. Runtime closure, full gates and
production adoption remain open. See the
[focused report](../../m2_h2_combined_shutdown.md).
