# CONNECT-owned WebTransport session checkpoint

Source: `eebd42ee8dc618434f9d9025159c9d8885576861`.
Date: 2026-11-17, Asia/Bangkok. Production dependency pins are unchanged.
This checkpoint does not complete v2.3.0 or activate positive session flow.

CONNECT stream slots now own the session route, phase and callback identity.
A startup-sized worker index maps connection generation and full session ID
to global slot/generation. Child guards use direct parent resolution;
association and datagrams use the index. Closing removes records and mappings
before callbacks. Storage is O(N), and the index is allocated only for a
capable WebTransport binding. The flow-off one-session restriction remains.

The index allocates nothing during insertion, lookup, removal or tombstone
cleanup. Its six tests cover namespace separation, stale removal, capacity and
startup allocation failures, and 1024 replacement cycles with allocation
failure armed. The strengthened empty-bucket headroom test fails before the
spare-margin rehash refinement and passes afterward. A separate x86 build is
compile-only, not foreign-runtime evidence.

Final functional drivers pass separately in every optimization mode:

| Driver | Debug | ReleaseSafe | ReleaseFast |
| --- | --- | --- | --- |
| Retained stream/child cases | 67/67 | 67/67 | 67/67 |
| Existing N4 datagram cases | 33/33 | 33/33 | 33/33 |

Each run passes 16/16 build steps on the same frozen source. Private fixture
observation helpers now validate global CONNECT ownership. C/build/wire inputs
and logical assertions remain unchanged. Session-close observers additionally
check index and record invalidation before notification.

The N4 driver exposed a migration regression that cleared queued datagrams
during cooldown and a pre-existing established-CONNECT shutdown bug. The exact
old baseline passes 32/33; the migration initially passes 31/33. The final
publication-aware cooldown policy retains unpublished established/draining
sessions while aborting accepting, published or record-null contexts. It
preserves all queue, going-away traffic, callback and public drain assertions.
Historical failed snapshots, the isolated trace and all fix diffs are retained.

Root passes 1073/1073 ordinary functional tests, ReleaseSafe test compilation,
ReleaseFast library and downstream consumer checks. Formatting, conventions,
version, diff and graph-update checks pass. Independent lifecycle and structural
reviews are clear.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
internal `files.sha256`. The archive retains 40 final fixture inputs, four
258-input Root snapshots, exact regression inputs, six final driver logs,
index RED/GREEN sources and a script-relative replay accepting `streams` or
`datagrams`. Both relocated Debug drivers pass; a quota-interrupted datagram
compile is retained separately from its successful retry.

Native005 and XEV5b2c remain the unchanged local proposals documented in the
[lifecycle artifact](../../webtransport_child_lifecycle_v1/2026_11_16/README.md).
Two inherited N4 reset-credit cases stage private Native receiver-window
growth before real wire updates; the separate 67-case public credit-recovery
proof is not that staging. No blanket Native-mutation-free or upstream
allocation-free claim is made.

Positive stream/data accounting, bounded early debt, scoped multi-session
cleanup, independent-client acceptance and fork publication remain open.
The new receive-observer prerequisite is verified separately. Dedicated
smoke/security/sanitizer/fuzz campaigns remain user-deferred.
