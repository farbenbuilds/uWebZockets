# Native fixture capture and canonical post-shutdown facts

The private combined HTTP/2 harness can now parse complete fixture captures
and compare post-shutdown facts with the existing canonical model. Source
review and a separate privacy-preparation review approve this slice. Native
provider integration, real process/TLS execution and M2 acceptance remain open.

`parse_capture` requires a completed collector without overflow or error,
bounded immutable bytes, strict UTF-8 and complete LF lines. It checks the
ordered 75 fixture markers: capacity, readiness, binding, 67 body records,
four outputs and deinit metrics. Capacity must match an independently supplied
expectation. Duplicate keys/tags, invalid types, floats, nonfinite numbers,
unsigned integer violations, malformed markers and exceeded allowances fail.

`validate_post` reuses canonical pre/post, metrics and output validators. It
retains actual scheduling-dependent producer counters and relative binding
generations. Selected active shutdown changes only the permitted cancellation
and active/paused state; other fields remain exact. Neither function proves
process identity, actual deinitialization, exit/reaping or cleanup.

The capture ceiling remains 65,536 bytes, with a conservative 62,144-byte
fixture allowance, 768-byte body JSON, 1,024-byte output/deinit JSON and the
shared 2,048-byte overhead allowance. Test capacity values and component-maxima
vectors are synthetic source inputs, not native measurements.

## Verification and review

Saved normal and optimized runs pass nine focused groups, including 1,485
semantic-field mutations. Checks cover all marker positions/order/counts,
nonce, capture flags, UTF-8/JSON/types, binding, producer algebra and exact
post-shutdown deltas. Native import-inert checks also pass.

The initial review found that unrelated diagnostics containing `H2_stream`
were rejected. The retained regression fails against that classifier. The
reviewed fix accepts five diagnostic forms at all 76 insertion positions
(380 captures), while rejecting reserved, malformed and embedded markers.
Both the initial finding and scoped approval are preserved. The API-absence
RED, real overflow/shared-allowance REDs, an intermediate regex failure and
passing corrections remain separate records; two exploratory passing probes
are not presented as REDs.

Independent audits preserve the prior 464 native packet files alongside the
authorized import-inventory edit, all 46 pure modules and 19,926 source/evidence
files, 809 preparation files, the input closure and prior publication files.
The parser fix leaves the approved five-source native inventory unchanged
during privacy preparation. Old C4/S46/all40 suites were not repeated.

## Public evidence boundary

The [evidence record](evidence/m2_h2_native_post/README.md) deliberately replaces
25 historical full-environment records with validated public projections.
Private originals remain local and are not embedded. Sixteen projections
retain three recorded Python controls; nine preserve the genuine absence of
the early hash seed. No missing setting is fabricated. The manifest identifies
every substitution; all other evidence bytes remain exact.

The current runner captures only its three explicit controls. Synthetic
leakage RED evidence uses an empty inherited environment and fake sentinels.
Privacy tests, a harmless runner proof and independent preparation review pass.
Known captured authentication values are excluded from publication inputs;
this is not a comprehensive historical secret audit or a fresh runtime closure.

The first exploratory Graphify query lacks a transitive-tool snapshot and is
qualified as navigation only. AST maintenance adds no ignored-helper topology
proof. Fresh provider/runtime closure, builds, actual combined native all40,
full project/platform gates, adoption and the remaining milestones are required.
