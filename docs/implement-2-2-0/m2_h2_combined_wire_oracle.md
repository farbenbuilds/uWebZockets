# Combined HTTP/2 passive wire observer

This checkpoint prepares a private test observer for the combined request-streaming
matrix. It observes actual successful send/receive bytes with fresh pinned
hyperframe/hpack state. Immutable request expectations classify responses and
final observations; they earn no traffic or completion facts themselves.

The existing peers, coordinator, adapter, product sources and dependency pins
are unchanged. Factory binding, actual default/all40 execution, native acceptance
and production adoption remain required. M2 stays open.

## Change and boundaries

The source inventory grows from 41 to 43: new `test_wire_oracle.py` and
`test_wire_oracle_checks.py`, plus the exact two-name import-inventory addition.
Forty existing modules remain byte-identical. The observer exposes
`wrap_connection`, `failure` and `seal`; only send/receive are wrapped in the
existing seven-key connection. Construction invokes no operations.

Original operations execute exactly once and preserve their result object or
exception. Ambiguous sends, operation failures and observer failures permanently
poison completeness. The observer retains a bounded failure code and location,
then passes through later operations. Only an explicit healthy seal returns
detached immutable facts after the caller has completed its lifecycle hooks.
A later operation poisons subsequent seals.

Actual wire facts distinguish request heads/trailers, logical/padded DATA,
SETTINGS/ACK, informationals, reset direction/code and both credit scopes.
Streamed outputs remain separate from small responses even at 17 bytes. Refusal
END and its required reset have distinct completion facts. The 67 ordered final
status requests plus metrics require 68 delivered terminal responses to earn a
collection. Authorized disconnect/shutdown windows retain open streams and debt;
their seals do not prove native close correctness.

Storage bounds are parser 8201, frame payload 8192, encoded/decoded header sections
and HPACK table 4096, eight active streams and 802 retained stream summaries.
Counters are bounded unsigned 64-bit values. No full payload or frame/read history
is retained. Complete HEADERS sections support transport fragmentation and
coalescing; general CONTINUATION is explicitly unsupported in this experiment.

## Review-driven growth fix

Initial review found that the pinned HPACK decoder could materialize an oversized
Huffman literal before rejecting its decoded size. The regression measured 6075
charged decoded bytes before rejection. The fix preflights each representation's
remaining section budget, including field overhead, before materialization.
It uses pinned integer/table primitives and a count-only walk of the pinned
Huffman DFA; the pinned decoder still constructs fields and owns its table.

Regressions cover oversized names/values, cumulative literal/indexed fields,
exact 4096 encoded and decoded acceptance, raw/never-indexed fields, dynamic
references within/across blocks and whole-block table-update ordering. No byte
limit was lowered. Independent source and scoped fix reviews approved the
result, with no remaining actionable findings in this slice.

## Evidence

The [evidence record](evidence/m2_h2_combined_wire_oracle/README.md) links the
archive and manifest. It preserves the baseline 41, reviewed 43 and fixed 43 sources,
all failed/intermediate commands, both behavioral growth failures, four fresh
fixed-source covering checks and strict audits. Before/after sources, exact
argv/environment/cwd/interpreter, separate outputs/exits and same-shell pinned
input-restoration receipts bind each run.

Focused observer and import checks for all 43 modules pass in normal and optimized
Python. They cover original operation priority, sticky failures, framing bounds,
padding, informationals, reset order/direction, short output classification,
late grants, final ordering, transport abandonment and post-seal attempts.
Strict audits preserve 13,038 original historical files and 15,055 pre-fix files,
with 119 input-authority entries, 118 physical rows, 113 resolved files and 42
ordered codec files. Current helpers satisfy strict depth and inert-import/argv checks.

Root's initial metadata audits had path-base, test-argument and sibling-import
assumptions corrected with original helpers and failure records retained. These
were metadata-audit failures; implementation receipts remain unchanged.

## Remaining acceptance

This helper shares external codecs with existing tooling; independence is from
canonical client state and handlers, and does not establish codec correctness.
No actual factory aggregate, retained-client comparison, default/all40 execution,
native/build/server/socket/TLS-close/real-clock/process-ownership or platform
proof was performed here. Full project/native/adoption gates remain mandatory.
The required combined result remains two children, 41 connections, 802 heads,
789 small completions, 200091899 request-flow bytes, 46 client SETTINGS, two informationals, 13 incoming
resets and two final collections, with all original hashes, debt, deadlines,
selection behavior and traffic ceilings preserved.
