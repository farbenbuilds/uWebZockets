# Independent HTTP/2 shutdown peer

The shutdown standalone driver now shares a bounded peer constructor for idle
and active shutdown. This prepares actual coordinator composition: the
coordinator still supports the preceding 38 cases and rejects shutdown/default
all40 in this checkpoint.

The [archive](evidence/m2_h2_combined_shutdown_peer/README.md) retains source,
raw checks, failing regressions and independent reviews. Its
[manifest](evidence/m2_h2_combined_shutdown_peer/manifest.json) binds all 39
current modules. Only `test_shutdown.py` changed; 38 modules remain unchanged.

`new_peer(case, *, app, prior, now, clock, fault=None)` validates supplied app
and prior state, then returns the seven-field synthetic connection and peer
state. Construction queues startup SETTINGS/ACK without client dispatch,
observation, clock consumption or application transitions. The standalone
driver uses this same peer, with the moved implementation removed.

Active upload metadata earns middleware, begin and active facts. Its validated
32-byte DATA earns the seven consumed prefix bytes, hash, chunk/span and pause
required by the immutable contract. The supplied signal boundary earns
cancellation. Serialized status/metrics responses use independently maintained
application records and counters. Retained output/binding values come from the
supplied app. Historical standalone prior scenarios remain supplied fixtures;
they do not establish actual preceding wire execution.

The parser is bounded at 8201 bytes, frame payload at 8192, pending packets at
two of at most 8192 bytes, and reads at 150. HPACK policy is finite. Pre-growth
checks, online order validation, scalar cursors and digests replace retained
request histories. Repeated oversized fragments and read-limit rejections
preserve the bounded state they test.

Independent review found DATA could be accepted before upload metadata. An
actual retained regression fails with `premature DATA accepted`; its production
AST matches the reviewed source apart from the new test and call. The fix
requires one SETTINGS ACK and the validated health/upload cursor before earning
DATA facts. Repeated rejection before health and before upload metadata preserves
application facts, counters, digest, queue and empty parser storage. The first
invalid frame can increase parser high-water; repeating it does not grow it.
The fix passes scoped spec/quality re-review with no new findings.

Four current shutdown/import checks pass in normal and optimized Python with
empty stderr. Idle observes 69 heads, 69 small responses and zero request DATA;
active observes 71, 70 and 32 bytes. Each has one SETTINGS and final collection.
The existing alternate units/TLS EOF, output/binding, alias and malformed-fact
controls remain. All 39 modules pass AST/guard and inert import checks; Root
verifies 5695 prior evidence files, a further 333 pre-fix unit files and the
119-entry immutable input authority with 42 codec sources.

Queue capacity is exercised once through serialized requests with deliberately
early response behavior. Repeated count/packet-size boundaries target the
shared enqueue helper directly; they do not promise whole-request rollback.
Its missing helper seam RED is separate from the actual read-limit and premature
DATA regressions. The initial constructor RED is missing API before effects.
The barrier guard's old-source diagnostic was recorded after its fix; baseline
and intermediate commands were not independently retained. Frozen sources and
raw results remain, with those chronology/receipt gaps explicit.

Transport, EOF, TLS and ownership facts remain synthetic. Shutdown coordinator
composition, actual default/all40 aggregation, broad review, runtime/native
validation, full project gates and production adoption remain required. M2
remains open.
