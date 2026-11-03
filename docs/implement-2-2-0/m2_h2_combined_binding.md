# First combined HTTP/2 observer binding

The private provider now binds reviewed peer factories to the canonical
coordinator and passive wire observer. Four actual compositions complete through
the existing adapter, including disconnect replacement and both shutdown paths.
Independent source review approves this partial binding. M2 remains open.

## Scope and actual execution

Two new modules provide immutable descriptors, provider hooks and checks. The
only existing source edit adds their names to the import inventory: 43 modules
become 45, with 42 unchanged. Peers, observer, coordinator, adapter, product code,
dependency pins and capacities are unchanged.

The binding supports 12 IDs. Eight distinct IDs completed in the four runs
below. The two large-upload and two pressure IDs received descriptor validation;
the failing large refund-tail probe is not successful large-upload coverage.

| Actual dispatch order | Children | Connections | Heads | Small | Request flow | Client SETTINGS | Incoming resets | Final collections |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| idle shutdown, producer reuse, file, disconnect, active shutdown | 2 | 6 | 181 | 177 | 193 | 8 | 0 | 2 |
| producer reuse, file, disconnect | 1 | 4 | 109 | 106 | 161 | 6 | 0 | 1 |
| idle shutdown, delayed, buffered | 2 | 3 | 145 | 145 | 257 | 3 | 0 | 2 |
| early final | 1 | 1 | 75 | 74 | 32 | 2 | 1, code 0 | 1 |

All runs have zero informationals. Counts come from sealed wire receipts.
The primary child subtotals are idle 69 heads/69 small and main 112/108.
Its receive totals are 16,890,888 bytes and 2,240 calls. Shared disconnect facts
are compared once across its two connections; connection receipts count once.

The producer's 16,777,313 bytes and file's 24,593 bytes retain their exact hashes
and actual client diagnostics through replacement into active shutdown. The
early response remains an output at 17 bytes, excluding it from small counts.
Disconnect and active shutdown each retain their open stream and 32 bytes of
debt in both request scopes. Buffered ordinary teardown retains its actual
257-byte debt. No close hook invents END or refunds.

## Ownership and acceptance

`coordinator.run` remains the sole dispatcher. The provider creates existing
factories directly, wraps every connection once and preserves protocol, time,
ownership, TLS and ALPN values. Expectations use reviewed request order and
transmitted payload contracts; they grant no observations.

Each child owns a fresh application and bounded state. The actual retained
client output/binding and returned final observations are compared with detached
snapshots from the application updated by traffic. Pre-shutdown snapshots precede
the signal mutation; post snapshots follow the relevant hook. No extra diagnostic
GET or regenerated model observation substitutes for retained values.

Sealing occurs only after the successful canonical return and validated hooks.
Missing, duplicate or incorrect identities reject before sealing. A real failing
regression showed that repairing a rejected aggregate operand permitted resealing;
the fix consumes the finish boundary before the first seal. Rejected acceptance
can no longer be repaired and retried against those observations.

## Evidence and limits

The [evidence record](evidence/m2_h2_combined_binding/README.md) links the exact
archive and manifest. Four covering checks pass: binding and all-module imports,
each normal and optimized. Every receipt includes actual source/helper bytes
before and after, exact arguments/environment/cwd/interpreter, separate outputs
and exit, and a fresh pinned-input restoration in the same shell.

Negative checks cover selection before effects, dispatch order, operation counts,
receipt identities, poisoned observers, actual retained/returned output/binding
corruption, hook failures, partial reset/refund tails and finish reuse. Strict
audits preserve all 16,227 prior evidence files and validate the 45-source
inventory, current helpers, and 119 input entries/118 physical rows/113 resolved
files/42 ordered codecs. The original missing-path read is retained as a tool
transcript qualification rather than a fabricated test failure.

Application, transport, close, signal and process facts remain synthetic.
The binding does not prove native ownership, independent codec correctness,
default/all40 execution, production adoption or project/platform acceptance.
The remaining families and completed large/pressure traffic are still required.
Full combined acceptance remains two children, 41 connections, 802 heads,
789 small completions, 200091899 request-flow bytes, 46 client SETTINGS, two
informationals, 13 incoming resets and two collections, with all original
hashes, selection, deadlines, debt and traffic ceilings preserved.
