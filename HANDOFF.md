# 2.2.0 implementation handoff

Status snapshot: 2026-11-03. This records the main implementation task's saved
state. Preparing this handoff did not resume implementation or execute tests.

## Goal and delivery

Implement every milestone in [2.2.0-TODO.md](2.2.0-TODO.md), with scope,
changes, verification, review and remaining acceptance recorded under
[docs/implement-2-2-0](docs/implement-2-2-0/README.md).

All implementation belongs on `feat/implement-2-2-0`, branched from `main` at
`a96e41705ff24171039c0a6e486b19418bfe7e6e`.

The user ultimately accepted delivery through the existing
`kienfssc/uWebZockets` fork after upstream pushes returned 403. The saved
preference is to push each implementation commit to preserve work; the user
will handle the pull request and manual review. Do not create another fork.
The upstream target remains `farbenbuilds/uWebZockets`.

The feature branch tracks `fork/feat/implement-2-2-0`. Local HEAD and that
tracking ref both resolve to
`6bd6d0494ead541636c8ff23d465c7f78e897b38`. This comparison used local refs;
no fresh fetch or remote authentication probe was performed for this handoff.
No merge, release tag or release publication has been performed.

## Milestone counts

The counts below use the numbered subtasks in the plan, with partial work kept
open. M0 and M7 have checklist items rather than numbered subtasks, so their
counts use those checklists. These are conservative counts derived from the
milestone reports; the reports do not maintain a numeric completion counter.

| Milestone | Done / total | Detail |
| --- | --- | --- |
| M0 | 9/9 baseline checks | Complete. |
| M1 | 3/3 locally verified | Response streaming, static delivery and TLS echo. Follow-up acceptance remains open. |
| M2 | 0/2 fully closed | Both request streaming and multipart are partially implemented and verified. |
| M3 | 0/3 fully closed | All three have evidence; final dependency provenance and pin acceptance remain open. |
| M4 | 0/3 | Live WebTransport implementation and compliance remain gated. |
| M5 | 0/2 | Cluster extraction and timer/limiter split await stabilization. |
| M6 | 1/6 | M6-4 optional API decisions completed. Timer work is partial; other items remain open. |
| M7 | 0/11 final release checks | Final release acceptance has not been performed. |

M1's 3/3 means local implementation and verification, not final release
acceptance. Its TLS follow-up and external benchmark evidence remain open.
M2 remains the current focus; its combined HTTP/2 source tests do not establish
combined native execution or production adoption.

Sources: [original plan](2.2.0-TODO.md) and
[milestone reports](docs/implement-2-2-0/README.md).

## Current work: M2 combined native HTTP/2 acceptance

Completed checkpoints establish separate kinds of evidence:

- H1/TLS request-streaming checkpoints include exact 100,000,000-byte uploads.
  The strict TLS matrix records 37/37 cases through each of the cluster and
  configured single-App paths. Production adoption remains open.
- All 40 HTTP/2 case IDs have individual native proofs across historical
  checkpoints. This does not establish a combined native run on final sources.
- The combined coordinator passes all 40 cases using serialized in-memory
  peers, both with an explicit selection and with selection genuinely omitted.
  These are source tests with supplied process and transport facts.
- Exact candidate and isolated libxev source exports have been reconstructed
  and reviewed for native testing. The immutable pre-shutdown wire checkpoint
  is reviewed and pushed.
- The latest native receive-provenance and closing helper is implemented and
  source-tested locally. Independent review and publication remain outstanding.

Recent pushed commits:

| Commit | Checkpoint |
| --- | --- |
| `58bc6d6` | Explicit and omitted-default all40 source execution |
| `cbdadc8` | Combined contracts and native-input audit |
| `d559be4` | Exact-source preparation for combined native testing |
| `6bd6d04` | Immutable pre-shutdown wire checkpoint |

Read these committed reports before continuing:

- [M2 request streaming](docs/implement-2-2-0/m2_request_streaming.md)
- [Combined all40 source execution](docs/implement-2-2-0/m2_h2_combined_all40.md)
- [Combined input audit](docs/implement-2-2-0/m2_h2_combined_input_audit.md)
- [Native source preparation](docs/implement-2-2-0/m2_h2_native_source_preparation.md)
- [Immutable wire checkpoint](docs/implement-2-2-0/m2_h2_wire_checkpoint.md)

## Local work awaiting review

Working directory: `.uwz-work/evidence/h2-streaming/combined-native/`.

| File in that directory | SHA-256 checked for this handoff |
| --- | --- |
| `native_closing.py` | `7c42cd04d5aba362b6b381b2d31e3feb07654de690159764dd0b7bae600d1007` |
| `test_native_closing.py` | `dd942f50e0b2c03c9ccf8fef5de11599849350fe388c75221d266005dc8e12c1` |
| `test_native_imports.py` | `6dcdc45b4b55ea1a3015c1ca7cb23d86ce3c3a598f7258377f6390ed9c32af06` |

The detailed local report is
[task-5e3c4-report.md](.superpowers/sdd/h2_streaming_plan/task-5e3c4-report.md),
SHA-256 `0315ff466be7edba466b793c14a1e447e46c9e8ffdc242c89988cf457808ee7c`.
Its status is `DONE_WITH_CONCERNS`: source-only implementation complete,
independent review still required. No commit or publication of this helper
is claimed.

Both `.uwz-work/` and `.superpowers/` paths above are Git-ignored. Their contents
remain local; pushing this handoff alone will not preserve them elsewhere.
Preserve the source, tests, reports and raw evidence before moving or cleaning
the Codespace. Do not treat these directories as disposable build caches.

The helper wraps the original receive callback once and binds it to the exact
observer object. Only an exception from the actual receive primitive qualifies
as receive provenance; preparation, clock, parser and passive-observer failures
cannot qualify. The original exception is retained and rethrown unchanged.

Signal-entry facts and counter baselines are frozen before activation. Terminal
receipts remain explicitly local: `complete_wire_proof=False` and
`authenticated_close_notify=not_established`. The retained 32/32 connection and
stream debt is reported honestly. No TLS EOF exception bypass or complete native
shutdown proof was added.

The accepted
[readiness scope ruling](.superpowers/sdd/h2_streaming_plan/task-5e3c4-ready-scope-report.md)
is child-scoped readiness, not a separate 15-second first-byte deadline for each
connection. Keep actual observed readiness timestamps and the original
case/whole/grace deadlines; do not reconstruct timestamps or restart budgets.

### Recorded verification and concerns

The local report records passing normal and optimized focused tests, inert
imports, structural checks, preservation checks and a final audit. These were
not rerun while preparing this handoff. No real server, socket, TLS context,
process termination or native all40 execution was performed by this slice.
The old S46/all40 suites were not repeated.

Raw commands, source snapshots, stdout, stderr, status and restoration receipts
are under the working directory's `evidence/`. Its
[run.sh](.uwz-work/evidence/h2-streaming/combined-native/evidence/run.sh)
records the exact six-part `PYTHONPATH` and pinned Python invocation
`/home/codespace/.python/current/bin/python3 -B -S`. The runner restores inputs
and creates evidence directories; it changes local state and is not a read-only
check. Use a fresh run name for any authorized rerun in the main thread.

The recorded preservation result is:

```text
c2=809; c3=6; closure=118; codecs=42; combined=19926; s46=46
```

The input closure retains 119 identity entries and 113 resolved files. The
initial successful preservation helper lacks a separately copied pre-run
filesystem snapshot. Directory membership was frozen later than the initial
file snapshot. Both limitations are disclosed in
`evidence/history-notes.md`; missing historical proof must not be reconstructed
or described as already established.

### Prepared native inputs

The reviewed source exports are under `/tmp/uwz-h2-combined-c2-fix1/`:
1,031 candidate files and 93 isolated libxev files, exported read-only.
The libxev test override is commit
`c223bd886c6a51d2cd60def39dd9a68d701fea73`, tree
`86c6944f53dc009d7503a9ab0bc873aef3cd7b79`. Production dependency pins have
not been changed by this preparation.

The preparation report records an absolute-path limitation: nine supplemental
source snapshots are archived, but the current reconstruction helper still
reads original absolute snapshot paths. If those paths disappear, an adapted
and reviewed reconstruction recipe is required. Do not claim the current
command is portable merely because archived bytes exist.

At handoff inspection the workspace filesystem had approximately 3.0 GiB free
(90% used); `/tmp` had approximately 38 GiB free. Recheck capacity before large
builds and retain the source and evidence described above.

## Next steps in the main implementation thread

1. Independently review the saved closing helper, its tests, raw evidence and
   disclosed concerns. Resolve findings and re-review any changes before
   integration. Do not mark this slice reviewed based on its own report.
2. Publish the reviewed source and evidence using the existing milestone-record
   format, update the M2 reports, then commit and push the reviewed checkpoint
   through the saved branch workflow.
3. Finish native provider/runtime integration and fresh interpreter, loader and
   SSL input closure. Build the exact prepared candidate in Debug and ReleaseSafe
   with explicit source remapping; preserve production pins and source exports.
4. Run the actual combined native all40 matrix, including explicit and omitted
   default selection, owned process/listener lifecycle, TLS and cleanup proof.
   Source tests and individual historical cases do not substitute for this run.
5. Complete current-source project/platform gates and reviewed production
   adoption. Finish H3 uploads, incremental multipart transport integration,
   genuine early-data proof and the remaining original M2 acceptance criteria.
6. Continue the remaining milestones below, preserving their original scope.

## Remaining work across the original milestones

- M1: production adoption of the TLS shutdown successor, authenticated graceful
  early-data closure and official external static/8gbit evidence or the plan's
  permitted dated re-declarations.
- M3: final maintained-fork publication and pin acceptance, exact mirror proof,
  HPACK child-pin synchronization, h1spec permission/attribution resolution and
  fresh final-pin package/protocol proofs. Local candidates are not accepted
  production pins.
- M4: maintained backend server APIs, connection/session/datagram binding and
  WebTransport compliance. Live activation and capability advertisement remain
  gated; wire helpers do not constitute live WebTransport support.
- M5: cluster runtime extraction and timer/parking/limiter ownership extraction
  after the feature boundaries stabilize.
- M6: quiet-host performance evidence, receive-side UDP GRO, the external
  HttpArena async adapter, remaining timer/token/native parked-reset checks,
  final-pin archives, second-machine resolution and native Windows runtime.
  Optional API decisions are already recorded. Existing 2026-11-02 external
  reassessment dates have passed; a later continuation must reassess them.
- M7: keep the existing 2.1.6 metadata until final release preparation; reconcile
  versions, changelog, documentation, ADRs and final pins, then run all final
  release checks. Merge, tagging and publication remain maintainer actions.

## Constraints and completion checks

Follow `AGENTS.md`, `CODING_CONVENTION.md` and the milestone acceptance contract.
Use Zig 0.16.0; keep hot-path I/O and parsing allocation-free, preserve buffered
defaults, use explicit named types and shallow control flow, and do not weaken
tests or lints. The user explicitly chose to gate request streaming on community
BSD targets until worker wakeups are supported. Linux/macOS and the existing
Windows release gate remain in scope; compilation alone is not runtime proof.

Maintained dependency publication follows `docs/dependency_forks.md`. Do not
push or submit changes to fetch-only upstream dependency repositories, introduce
local patches/overlays, force-push integration branches or replace full commit
pins with branches or tags.

Before declaring implementation complete in the main thread, run the required
project checks and any additional gates required by the affected milestone:

```sh
zig fmt src builds examples tests fuzz
sh scripts/check_conventions.sh
sh scripts/check_release_version.sh
zig build test
```

After code changes, keep the ignored graph current with `graphify update .`.
Final acceptance also requires the applicable sanitizer, fuzz, package-consumer,
protocol, performance and platform evidence on the exact final sources.

For this handoff request only `HANDOFF.md` was created and expanded. It is
uncommitted at this snapshot; no implementation changes, test runs, commits or
pushes were performed while preparing it.
