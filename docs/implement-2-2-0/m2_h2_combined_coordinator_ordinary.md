# Ordered ordinary HTTP/2 coordinator composition

The coordinator now accepts valid caller-ordered subsets of all 37 ordinary
cases, dispatching through the concrete adapter with a fresh connection per
case. Empty selection remains without effects. Disconnect, idle shutdown and
active shutdown remain unsupported here; omitted/default all40 still rejects
before callbacks. This checkpoint does not establish actual all37/default/all40
execution or native activation.

The [archive](evidence/m2_h2_combined_coordinator_ordinary/README.md) preserves
all 39 current modules, preceding source, raw checks and independent review.
Its [manifest](evidence/m2_h2_combined_coordinator_ordinary/manifest.json) binds
exact source identities and scope. One composition test was added; coordinator,
ready tests and import inventory changed; 35 prior modules are unchanged.

Each successful intermediate case completes, copies its actual counts and
earned output/binding facts, and closes within its original case/whole deadline.
Only the final case performs the 68 status/metrics requests and supplied child
teardown. Positive request debt may remain on a closed connection. The next
connection receives independent protocol, parser and credit state, with copied
application observations retained across cases.

Actual coordinator proofs use the reviewed peer constructors, not standalone
test drivers or model-generated completion. They cover buffered/large uploads
in both orders, undeclared upload, reuse before/after ordinary work, each
producer/pressure variant, and file/early-final followed by buffered completion.

| Observed selection | Heads | Small responses | Request DATA bytes |
| --- | ---: | ---: | ---: |
| Buffered and declared upload, either order | 78 | 78 | 100000257 |
| Reuse then buffered | 462 | 462 | 545 |

Producer reuse followed by buffered completion observes 82 heads and 81 small
responses. All 37 singletons and forward/reverse ordinary selections also reach
the factory boundary; that static acceptance is separate from actual execution.

Results now retain bounded per-connection summaries: case, case-local index,
child ordinal, deadline, SETTINGS/informationals, local received bytes/reads,
connection/stream debt and copied release facts. Intermediate closes cannot
rewrite saved counts or observations. Final records/metrics form the existing
private comparison baseline; returned facts remain independent of hook-owned
dictionaries.

Named proofs check connection independence, final parser/ledger identity,
257-byte buffered debt, actual pre-close summaries, missing producer/file output
and required binding rejection, and callback mutation. A receiver advancing
time from 2 to 3 gives the next case deadline 183, unchanged whole deadline 901
and final grace 18. Rollback and equality expiry stop the next connection.

Independent review found an intermediate-close deadline defect. A hook could
widen its exposed stage deadline and advance time to the original deadline 32;
the old run incorrectly continued with deadlines `[32, 212]`. The retained
failing source and result demonstrate that defect. The fix captures the newest
checked timestamp and original local deadline privately, then checks the original
caller clock after close. Deadline/time/clock rewrites cannot evade the boundary;
valid within-bound handoffs preserve the original limits.

Six current composition/coordinator/import checks pass in normal and optimized
Python with empty stderr. All 39 modules pass AST/main-guard and actual inert
imports; the fresh pre-edit map verifies 5111 earlier evidence files. Earlier
candidate/completion results remain distinct from the final fix results.
The initial unsupported-selection RED is before wire execution. An earlier
dispatch-failure source was not frozen and one intermediate structure JSON was
overwritten; these gaps remain explicit. Current and reviewed source plus the
deadline regression are frozen separately.

Spec, quality and structural review approve this source composition after the
deadline fix. Transport, ownership, TLS and process facts remain synthetic.
Disconnect replacement, shutdown children, actual default/all40 aggregation,
broad review, native/runtime verification, full project gates and production
adoption remain required. M2 remains open.
