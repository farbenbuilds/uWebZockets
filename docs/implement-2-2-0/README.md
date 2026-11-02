# 2.2.0 implementation record

The implementation follows [the milestone plan](../../2.2.0-TODO.md) on
`feat/implement-2-2-0`, branched from `main` at
`a96e41705ff24171039c0a6e486b19418bfe7e6e`.

Each milestone report records scope, architectural decisions, changes, raw
verification evidence, independent review, and remaining acceptance criteria.
A milestone stays open until its required evidence is present. External
results and release actions are recorded only when actually performed.

| Milestone | Scope | State | Report |
| --- | --- | --- | --- |
| M0 | Freeze the 2.1.6 baseline | Complete | [Baseline](m0_baseline.md) |
| M1 | Response streaming, static delivery, TLS payloads | TLS closure successor verified; adoption and external profiles open | [Streaming, static, TLS](m1_streaming_static_tls.md) |
| M2 | Request streaming and incremental multipart | H1/TLS and 40 H2 case IDs proved across checkpoints; combined matrix, H3 and adoption remain open | [Request streaming](m2_request_streaming.md) |
| M3 | Dependency provenance gates and archives | In progress | [Dependency provenance](m3_dependency_provenance.md) |
| M4 | Live WebTransport and compliance | Delivery re-declared; activation gated | [WebTransport](m4_webtransport.md) |
| M5 | Cluster, timer, and limiter ownership | Awaiting feature stabilization | [Structural ownership](m5_structural_ownership.md) |
| M6 | Performance, platform, GRO, and API decisions | API decisions and timer overflow fix recorded; other work open | [Evidence and platform](m6_evidence_platform.md) |
| M7 | Release metadata and final verification | Awaiting M1 through M6 | [Release acceptance](m7_release.md) |

M1 slice reports: [response transport matrix](m1_response_matrix.md) and
[content-coding evidence](evidence/m1_e/README.md), plus the
[100 KiB socket response proof](m1_tls_payload.md) and
[true POST echo](m1_tls_echo.md).
The next slice records [bounded file streaming](m1_file_streaming.md).
Its [HTTP/2 backend](m1_file_http2.md) includes real TLS pressure isolation.
The [HTTP/3 backend](m1_file_http3.md) records copied partial-write ownership.
[Complete-field coding negotiation](m1_encoding_fields.md) prepares sidecar selection.
[Static delivery](m1_static_streaming.md) records real 100 MiB TLS/H2 downloads.
[Opt-in sidecars](m1_static_sidecars.md) record fresh representation selection and 752/752 native tests.
[The public interop matrix](m1_static_interop.md) records its harness and live-result boundary.

M2 slice reports: [common contract](m2_common_contract.md),
[response guards](m2_response_guards.md), and the standalone
[incremental multipart utility](m2_incremental_multipart.md).
The [part-sink adapter](m2_multipart_sink.md) records the next integration slice.
The [HTTP/1 head/body decoder](m2_body_decoder.md) records pure framing and
buffered compatibility before transport activation.
[Transport preparation](m2_transport_preparation.md) preserves separate reviewed
components, lifetime proposals, and interrupted header-refusal drafts.
The [HTTP/2 refusal checkpoint](m2_h2_refusal.md) extends its isolated draft with
framing, output pressure, sibling, capacity and Linux32 verification.
Its [live TLS follow-up](evidence/m2_h2_refusal_live/README.md) records header-only
503 and same-connection health with curl/nghttp2 on an owned io_uring server.
The [HTTP/3 checkpoint](m2_h3_refusal.md) adds source compatibility, canonical
selection, queued-trailer, sibling and Linux32 verification to its saved draft.
Its [live HTTP/3 follow-up](evidence/m2_h3_refusal_live/README.md) records normal
refusal, a healthy sibling and reuse with a reviewed test-only libxev override.
The [HTTP/3 source checkpoint](m2_h3_source_authentication.md) authenticates the
cached QPACK file against the retained exact-pin Git bundle; upload work remains open.
The [pure HTTP/1 admission checkpoint](m2_h1_admission.md) verifies physical
ingress bounds and the atomic router-to-common-state reservation handoff.
The [typed loop-callback adapter](m2_loop_callback_adapter.md) prepares backend
ACK classification and fixed failure fencing without activating H1 retirement.
The [platform setup guard](m2_upload_platform.md) records the confirmed BSD
restriction, eligible-target compilation and refusal-before-mutation proofs.
The [coherent H1 baseline](m2_h1_baseline.md) combines the reviewed preparation
with current Root, preserving multipart/timer changes and exact layout evidence.
The [cold-state successor](m2_h1_cold_state.md) adds the head target, delivery
pin and payload accounting with pure reset/drain proof and unchanged disabled slabs.
The [pure retirement policy](m2_h1_retirement_policy.md) prepares coalesced timer
boundaries and one-shot close eligibility without native callback effects.
Its [typed invariant follow-up](evidence/m2_h1_invariant_failure/README.md)
preserves failure-latch ordering before the new fixed inactive-phase diagnostic.
The [plaintext implementation checkpoint](m2_h1_plaintext.md) preserves reviewed
App/driver code, both exact 100000000-byte live uploads, real-file ordering and
two initial client failures. Its [corrected client follow-up](evidence/m2_h1_plaintext_corrected/README.md)
passes 21/21 against the identical server. Production integration remains open.
The [producer/lifecycle follow-up](evidence/m2_h1_plaintext_lifecycle/README.md)
passes 26/26, including metadata after slot reuse and active-upload shutdown.
The [TLS capacity clarification](m2_tls_capacity.md) records the reviewed
encrypted-receive/BIO boundary before TLS driver implementation.
The [TLS driver checkpoint](m2_tls_driver.md) preserves reviewed code and 27
focused tests. Its [shutdown successor](m1_tls_shutdown.md) corrects the inherited
close-notify retry finding. The [configured HTTPS constructors](m2_configured_https.md)
preserve single-App streaming configuration. The [strict live TLS matrix](m2_tls_live.md)
passes 37/37 through the cluster and 37/37 through the configured single App,
including both exact 100000000-byte framings. Production adoption remains open.
The [HTTP/2 receive queue core](m2_h2_body_queue.md) passes its nine focused
tests in both modes. Its [Session/registered-sink successor](m2_h2_session_delivery.md)
passes173 selected tests per mode after four independently reviewed fixes;
native App/TCP activation and actual H2/TLS upload proof remain open.
The [three-target layout checkpoint](m2_h2_layout.md) measures its bounded warm
growth and records the corrected observation/Continue gate before delivery code.
The [native startup checkpoint](m2_h2_native_startup.md) adds enabled-only carving
and stable late owner binding, with140 selected tests per mode and unchanged
disabled totals. Native body callbacks and TCP lifetime composition remain gated.
The [terminal-input successor](m2_h2_terminal_inputs.md) preserves no-output
teardown, ordinary GOAWAY credit/output and drained generation-safe reset;
190 selected tests pass per mode after the reviewed nesting correction.
The [native admission fact](m2_h2_native_admission.md) propagates early-data policy
through the existing Router boundary; its encoded425 regression and47 selected
tests per mode pass. Native policy derivation remains part of TCP integration.
The [native TCP composition](m2_h2_native_tcp.md) wires events, controls, response
hooks and release pins. Independent review and the scoped first-cause fix pass;
the [core live successor](m2_h2_core_live.md) now passes five owned H2/TLS cases,
including both actual 100000000-byte uploads. Broader H2 and full native
acceptance remain open.
The [pause/control successor](m2_h2_pause_control_live.md) passes partial/final/
empty pauses and public token validation, retaining all five result records
through deinit. The [admission successor](m2_h2_admission_live.md) passes 13 cases
for empty/limited bodies, Continue, quota and failed-begin recovery, with retained
headers and ordered refusal resets. The [credit successor](m2_h2_credit_live.md)
passes padded trailers, legitimate credit exhaustion and concurrent route
isolation. It preserves a failed restricted startup and the completed host run.
The [metadata successor](m2_h2_metadata_live.md) passes overflow headers/captures,
helper refusals and trailer retention through deinit. The
[control successor](m2_h2_control_live.md) passes ready/paused cancellation and
peer reset with independent credit and recovery checks. The
[application-error successor](m2_h2_application_error_live.md) passes chunk,
progress and end failures without duplicate cancellation. The
[lifecycle-close successor](m2_h2_lifecycle_close_live.md) passes clean disconnect,
nine-request reuse and active-upload shutdown. The output successor below adds
the remaining five IDs; the combined matrix remains required.
The [bounded output observer](m2_h2_output_observer.md) prepares hash-only binary
responses and manual credit, with pure codec regression evidence.
Its [client-core successor](m2_h2_output_client_core.md) adds separate credit
ledgers, ordered late refunds and bounded output stages with pure codec proof.
The [output fixture preparation](m2_h2_output_fixture.md) adds reviewed fixture
sources, actual Debug/ReleaseSafe compilation and current function-based checks.
That preparation checkpoint did not execute the fixture.
The [output driver preparation](m2_h2_output_driver.md) adds reviewed schedules,
public-codec integration checks, owned-process cleanup and an authenticated
runtime input closure. The [native output proof](m2_h2_output_live.md) then passes
all five output cases, giving 40 proved IDs across checkpoints. The actual
combined 40-case run and full quality/platform/adoption gates remain required.
The [combined acceptance contract](m2_h2_combined_contract.md) now prepares all
40 IDs and 67 independent body records, with reviewed subset/default, shutdown,
family-evidence and work-bound contracts. The
[combined fixture preparation](m2_h2_combined_fixture.md) now adds the shared
records/slots, canonical formatters, verified capture bounds and actual
Debug/ReleaseSafe compilation. The
[combined client core](m2_h2_combined_client_core.md) now adds reviewed per-case
credit, stages, retirement and one bound public-codec path, including actual
pure startup proof and the reviewed small-response limit fix. The
[public and large upload schedules](m2_h2_combined_public_cases.md) add the
first four cases, fresh caller-time checks and shared-state/final-debt proof.
The [pause/control schedules](m2_h2_combined_pause_cases.md) add four more
reviewed cases with exact serialized actions and retained-record checks.
The [admission schedules](m2_h2_combined_admission_cases.md) add nine empty,
limited and refusal/recovery cases, bringing reviewed source schedules to 17.
The [Continue/quota schedules](m2_h2_combined_continue_quota.md) add four more
reviewed cases, reaching 21, with exact Continue, active-barrier and recovery
sequences. The [credit/trailer schedules](m2_h2_combined_credit_cases.md) add
two more reviewed cases, reaching 23, with independent credit scopes and exact
padding/trailer order. The
[metadata/concurrent-route schedules](m2_h2_combined_metadata_concurrency.md)
add two more, reaching 25, with exact metadata/helper contracts, route isolation
and retained-refusal retirement. The
[cancellation/reset schedules](m2_h2_combined_cancel_reset.md) add three more,
reaching 28, with policy-aware terminal completion, credit reclamation and
sibling/recovery isolation. The
[application-error schedules](m2_h2_combined_application_errors.md) add three
more, reaching 31, with precise failing-callback diagnostics and INTERNAL_ERROR
completion. The [producer/pressure schedules](m2_h2_combined_producer_pressure.md)
add three more, reaching 34, with exact hash-only output, canonical grants,
paired completion and retained binding diagnostics. The
[file/early-final schedules](m2_h2_combined_file_early.md) add two more, reaching
36, with exact range generation, retained file diagnostics and END-before-reset
ordering. The [disconnect/reuse schedules](m2_h2_combined_disconnect_reuse.md)
add two more, reaching 38, with staged supplied-close replacement, independent
connection credit and stale-control isolation across nine uploads. The
[shutdown schedules](m2_h2_combined_shutdown.md) complete all 40 source IDs,
including held final collection, private comparison snapshots and fresh idle
state. Default/subset/aggregate orchestration, case/close/runner integration,
runtime closure and the actual combined run remain open.
The [first coordinator lifecycle](m2_h2_combined_coordinator_ready.md) executes
explicit empty selection or one buffered-request child through final capture
and supplied teardown facts. It rejects other selections and default all40
before effects; this checkpoint does not close combined acceptance.
The [shared buffered/large peer](m2_h2_combined_core_peer.md) removes duplicate
serialization from the coordinator test and upload driver, preserving exact
large-body, carried-credit and lifecycle checks. Its caller-order driver
proofs prepare composition without expanding coordinator acceptance.
The [disconnect/reuse peer constructors](m2_h2_combined_lifecycle_peer.md) keep
replacement orchestration in the driver and validate intermediate state with
strict types. Review-driven regressions enforce the lifecycle parser's storage
cap before mutation. The
[shared-peer capacity correction](m2_h2_combined_core_capacity.md) closes the
separate follow-up, preserving exact retained bytes and high-water mark across
repeated rejected sends.
The [independent producer/pressure peers](m2_h2_combined_producer_peer.md) earn
diagnostic and binding facts from serialized peer progress, with separate client
observations. Review fixes bound unsolicited grants and preserve receive callback
results/errors; coordinator composition remains open.
The [independent file/early peers](m2_h2_combined_file_peer.md) retain producer
facts while checking bounded file generation, close ownership and END-before-
reset order. All four peer preparation slices are recorded and provide the
reviewed factories used by the coordinator integration below.
The [ordinary coordinator composition](m2_h2_combined_coordinator_ordinary.md)
now supports caller-ordered subsets of all 37 ordinary handlers with fresh
connections, retained observations and one final collection. Representative
actual runs pass after a private deadline fix; disconnect/shutdown, default/all40
and native acceptance remain open.
The [independent H2 client preparation](evidence/m2_h2_client/README.md) preserves
pinned tools and reviewed bounded helpers; its checks are pure and provide no
uWebZockets, socket or live-upload evidence.

The [reviewed libxev duplicate-cleanup candidate](evidence/m3_libxev_dup_verified/README.md)
adds independent source review, pure decisions, healthy-suite verification and
a complete recovery bundle without changing maintained refs or root pins.
The [reviewed IOCP cancellation-result candidate](evidence/m3_libxev_iocp_cancel/README.md)
adds missing-request classification, portable policy tests, healthy-suite and
foreign Windows compilation evidence, preserving public errors and layouts.

The original plan remains the acceptance contract. Reports supplement it;
they do not reduce its scope. The maintainer owns the final reviewed merge,
release tag, and publication.

On 2026-10-27 the user authorized delivery to the existing
[kienfssc/uWebZockets feature branch](https://github.com/kienfssc/uWebZockets/tree/feat/implement-2-2-0)
and will open the pull request manually. This supersedes the earlier
original-repository-only instruction and the plan's per-milestone PR workflow.
The fork's parent is `farbenbuilds/uWebZockets`; its feature branch was
fast-forwarded from `4e49d2697a5ade22cc95d4d3b43e125c37366d1d` to
`00c85640de26823f02a9c5d1fb82ccecb832aea4`, then verified with `git ls-remote`.

Push each subsequent commit to the `fork` remote. The local branch tracks
`fork/feat/implement-2-2-0`; `origin` and `upstream` retain the original
repository URL. The Codespace account has write access to the fork and read
access to the original repository. Earlier original-repository HTTP 403
results remain historical evidence; remote delivery is now available.
