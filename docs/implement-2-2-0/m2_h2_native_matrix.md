# M2: combined native HTTP/2 matrix

Status: four actual Linux TLS/H2 runs pass independent review. M2 remains open.
This checkpoint tests the isolated candidate and dependency exports described
by the [build checkpoint](m2_h2_native_builds.md), with the reviewed
[collection handoff](m2_h2_collection_handoff.md). Production source and pins
have not been adopted.

## Actual execution

All four runs use the same frozen provider source, all 40 canonical case IDs,
41 ordered connection receipts and two fresh owned children. The omitted runs
call `coordinator.run(**keywords)` without a selection argument. Ready, case,
whole-run and cleanup deadlines remain unchanged.

| Run | Control | Acceptance JSON SHA-256 |
| --- | --- | --- |
| Debug explicit | 121 | `f1d98f696d6f9b9112813842714bca5493afbfbac0bdb58b1ad1f732fbd5e450` |
| Debug omitted | 122 | `84fc8bee65ad8a326c904717722284106adc41f0387742c4e4c6c156305842c6` |
| ReleaseSafe explicit | 123 | `15c6586347744d9b6dd36c772010cce171f9d161b5ac7c35197ab4d70fbf9319` |
| ReleaseSafe omitted | 124 | `00590fe1915efe8a2e3328e14f63bff5db326d52b692bdacb2aea8d4f77a73bf` |

Each run completes declared and undeclared 100000000-byte uploads with SHA-256
`190f6457d88258809df90a042b0226dab5537a1984f708cfd5bb90005835cea2`.
It also validates three 16777313-byte responses, the 24593-byte file range,
callback generations, credit, trailers, refusals, cancellation, reuse and
shutdown against actual capture and independent client facts. Scheduling
counts vary across runs; generation identities and semantic invariants agree.

All eight children exit zero and are reaped, with listeners gone, collector joins
and capture-pipe closure complete. Each idle/main pair closes all 2+80
registered handles successfully, leaves zero open handles and records zero
cleanup errors. All 24 certificate/key/transfer paths are absent afterward.
TLS 1.3, ALPN `h2`, verified localhost identity, strict EOF handling and public
TLS unwrap/returned-handle closure remain required. No private key or ambient
environment bytes are published.

## Fixes and evidence limits

The provider now handles interleaved startup diagnostics and owns normal
transfer cleanup. Operational review fixes reject stale bytecode before helper
imports, preserve primary failures and close one-shot cleanup gaps. A bounded
Linux listener-prefix reader reads every leading LISTEN row with fresh process
and descriptor ownership checks. It relies on the documented kernel ordering;
it does not validate the unread established-connection tail or cache results.
Focused normal and optimized checks and scoped independent reviews pass.

Earlier failures remain preserved, including a large-upload deadline failure
before the bounded reader. Its cause is not a demonstrated target defect.
The successful large-upload connection-entry intervals include transition
overhead; they are not isolated handler timings, server throughput or measured
resident-memory evidence. Internal EOF/closing observations retain their
documented limits, including separate closing debt.

## Preservation after execution

The original receipts, captures and binaries were independently checked after
the runs. Later, the unchanged Root preservation audit failed at the missing
candidate tree: all four temporary source/build/execution/cache roots were
absent. The temporary volume observation also changed; the disappearance cause
is undetermined. The failed audit and agent observations are retained.

The workspace's 34-file final evidence index and its four acceptance JSONs and
eight captures still verify. This publication preserves historical execution;
it does not claim a passing current physical-input audit or a new native run.
Exact source/input/binary recovery is being reviewed separately and is excluded
from this artifact. Historical build recipes remain available in the build
checkpoint; ELF bytes are not included here.

## Verification and remaining work

The retained repository verification reports 852/852 tests and 22/22 build
steps, using a fresh runtime seed and warm compiler cache. Negative-path TLS,
accept and worker diagnostics remain in the raw output. Formatting, conventions,
version, documentation, dependency policy and AST graph checks also passed.
The version remains 2.1.6. These checks do not test a production adoption of the
isolated candidate.

The [lossless evidence packet](evidence/m2_h2_native_matrix/README.md) includes
the provider, exercised source snapshots, exact commands, successful and failed
receipts, raw captures, full independent verdicts and failed preservation audit.
Temporary recovery, production source/dependency adoption, H3 uploads, real
multipart integration, early data and the remaining ownership/platform/release
gates remain required. No whole-M2, cross-platform or performance acceptance is
claimed.
