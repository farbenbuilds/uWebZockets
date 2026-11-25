# WebTransport backend prerequisite: local lsquic proposal

The maintained-fork proposal implements real outgoing unidirectional QUIC
streams with bounded synchronous admission, peer credit, safe completion and
graceful shutdown. It is one prerequisite for accepted ADR 0001. It does not
implement reliable reset, draft-16 settings, session association, application
datagram routing, or live WebTransport.

The root dependency remains
`85bd081c9103c077a7cc98271d09334d0f1043d4`; no capability bit or build pin
changed. The proposed full candidate is
`0f7382b17b38d7fb0496a0b75b3c66ace79e49e8`, currently an unpublished local
commit. The incremental Git bundle, diff and source snapshots are review
evidence only. No root build reads or applies this archive.

## Verification

| Scope | Result |
| --- | --- |
| Eight real-engine integration groups, Debug | 12/12 build steps, all groups pass |
| Same groups, ReleaseSafe | 12/12 build steps, all groups pass |
| Same groups, strict ASan/UBSan/LSan | 12/12 build steps, all groups pass |
| Immediate TLS-only engine destruction | Strict sanitizer pass, without calling the new API or adding drain ticks |
| Existing upstream Linux Debug cases | All 83 exact cases pass; 165/165 build steps |
| Production libraries, Windows GNU and macOS ARM64 | ReleaseSafe cross-compilation, 9/9 steps each |
| Independent source, test and handoff review | No actionable findings; all ten source identities match the tested candidate |

The new integration executable exchanges encrypted packets between two real
production engines. It checks exact payload and FIN, stream IDs, peer credit
exhaustion and genuine MAX_STREAMS recovery, failure rollback, reentrancy,
explicit close, delayed HTTP/3 settings, critical stream credit, and graceful
drain. The client uses `SSL_VERIFY_NONE` for its in-memory test certificate;
this is transport/lifetime evidence, not certificate-verification coverage.
The clock and two failure hooks are documented test-only symbol seams.

Strict checks also exposed three pre-existing defects in the exact base:
incompatible ACK callback function types, zero-capacity QPACK stack storage,
and retired crypto streams missed by immediate destruction. Separate commits
fix them without disabling checks. Framing tests now enforce the existing
LSQ-001 stream-reset and application-owned length-validation policy, including
a healthy sibling and exactly-once header ownership. Bounds and explicit body
validator assertions remain intact. Earlier failing cohorts are retained.

The five unpublished commits are:

| Proposed ledger ID | Local commit | Change |
| --- | --- | --- |
| LSQ-003 | `f2c1329fd116fa7f6d40d142aeb55359c4ad8501` | Typed ACK callbacks |
| LSQ-004 | `f7bfd697c967f550bf59fc6a720f48a15d3191d7` | Physical QPACK storage with logical capacity zero preserved |
| LSQ-005 | `5accc8aea1d4a0fb2e02530686ab1ab42527f98f` | Retired crypto stream cleanup |
| LSQ-006 | `1aaac18c467e8b19a481dc6ef96db2b798e76edc` | Maintained framing-test contract |
| LSQ-007 | `0f7382b17b38d7fb0496a0b75b3c66ace79e49e8` | Uni-stream API, lifecycle, docs and integration test |

## Replay and integration

The original archive contained sources, exact commands, raw logs, failed predecessors,
both native Zig runners, four unchanged dependency pins, offline validation,
and the reviewed Git bundle. Runtime heaps, core dumps, generated keys,
compiler caches, dependency bodies and executables are excluded.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Root independently replayed that verifier and checked the complete diff
against the exact base. It also imported the retained base plus incremental
bundle offline, ran full Git checks and matched all ten committed source
files to their tested hashes.

Before integration, an authorized maintainer must import the bundle into a
scratch branch of `farbenbuilds/lsquic`, review the range, assign the PR owner,
apply an existing repository label, verify branch protections and merge
append-only into `uwz/main`. Only the resulting published integration commit
may supply a fresh full pin and package hash across all four manifest views.
Do not patch a fetched cache, use a local path pin, or replace the fork with
an alternate remote. See [the fork policy](../../../../docs/dependency_forks.md).

CMake compatibility registration was reviewed but not executed; actual
compilation used Zig 0.16.0 source lists. Cross-compilation does not prove
foreign runtime behavior. This evidence does not close WebTransport,
performance, allocation-exception, publication, or other release gates.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `49522d7588b11e6112f14a50c8452cd280f99b4a0b511985a53306a2d8cbb73c`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
