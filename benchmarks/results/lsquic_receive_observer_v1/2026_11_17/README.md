# Native WebTransport receive-observer prerequisite

Local proposal: `c8cf3fbc201a5d6f6acb6ae45af476cfcd5d7840`, directly atop
`005ab244169f269689e511d6b77dd2187e318df1`.
Date: 2026-11-17, Asia/Bangkok. The fork is not pushed and production pins are
unchanged. Positive Root flow control is not activated.

The receive snapshot exposes monotonic `received_end`, including out-of-order
offsets and reset final sizes. An optional receive observer reports deduplicated
body deltas excluding association prefixes, including NULL application contexts.
Native commits its cursor before callbacks. Zero delta can report a newly
coalesced metadata transition. Work uses existing service flags rather than a
new event queue or per-event allocation.

Native publishes typed state before the observer, then invokes the typed
notification and later callbacks for published children. This provides a debit
point before payload delivery; pre-publication classifier callbacks remain
permitted and must consume no child body.
Consumers must still gate admission on cancellation/session state; stream-only
cancellation preserves typed classification. Before publication, classifier
probes must consume no child body. The HTTP classifier now stops when a child
is classified, preserving the next buffered raw payload frame.

Independent review found two lifecycle defects in the initial proposal:
never-published receive self-ownership could prevent stream reclamation after
incompatible SETTINGS, and early STOP could notify before publication. Actual
TLS regressions reproduce both; readiness-gated staging and STOP publication
guards correct them. Exact runtime RED sources and final GREEN logs are retained.

Verification passes:

- Eight receive-observer groups in Debug, ReleaseSafe and ReleaseFast.
- Existing native WebTransport stream, reset and reset-metadata fixtures.
- 83 existing Linux Debug native assertion run cases.
- The frozen earlier Root 67-case cohort in all three modes, observer unset.
- Final CONNECT-record Root compatibility in Debug: stream driver 67/67 and
  datagram driver 33/33, each 16/16 steps. These driver counts share helpers.

Ingress unit cases use real native frame/packet structures. Reordered payload,
delayed SETTINGS, early STOP and credit recovery use actual TLS engines. Native
allocation freedom, independent-client acceptance, non-Linux runtime and safe
engine destruction from callbacks are not claimed. Two inherited datagram cases
retain private receiver-window staging, as documented in their fixture.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify the
internal `evidence_manifest.sha256`. The original archive retained full Native source,
patch, an incremental Git bundle requiring Native005, exact regression inputs,
replay harnesses, frozen Root inputs, raw logs and independent review records.
Its README documents explicit source/compiler/package/cache overrides.

The reviewed production diff SHA-256 is
`f044d1257e6e7cbca1f4e43db6a010dbc76f0e791ff83dc6677016c8780f99e4`.
The AST update completed separately; parser limits are recorded as navigation
limits rather than compilation proof. Initial scratch-quota and fixture setup
failures remain labeled separately from the runtime defects.

Root still needs positive budgets, early-debt accounting, capsule credit output,
multi-session isolation, independent draft-16 acceptance and reviewed fork
publication. Dedicated smoke/security/sanitizer/fuzz campaigns remain deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `9f3c9d3745b7bb65cbe25be0d4c54b1cc363f0eee0d323616f8aa0b67d8b98fd`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
