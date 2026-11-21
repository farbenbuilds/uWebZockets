# App WebTransport admission checkpoint, 2026-11-16

The private runtime now binds App admission and registered datagram route
identity to generation-checked connection sessions. Explicit synchronous
CONNECT handlers approve credentials and Origin at completed headers. A
successful response keeps both stream directions open, flushes after native
header completion, and releases request-header storage. Capsule parsing uses
bounded carry; blocked resets retry after header completion and delayed FIN.

The configured application also exposes `enable_http3` and
`enable_http3_ephemeral`, preserving builder capacities and installing separate
TCP and QUIC TLS contexts atomically. The initial candidate profile permits
one session per connection with session flow control off.

All 991 centralized tests pass with published dependencies, 20/20 build steps.
ReleaseSafe test compilation and the ReleaseFast library each pass 21/21 steps.
Formatting, conventions and release metadata checks pass. Sixteen pure capsule
decoder cases pass in Debug, ReleaseSafe and ReleaseFast.

Eight actual App/TLS cases pass in all three optimization modes, 16/16 steps
each. They cover nonterminal success before request EOF, Origin/auth refusals,
explicit CONNECT and middleware policy, independent session zero on two
connections, excess-session and incompatible-peer resets, cooldown reentry,
credit-blocked reset recovery and delayed FIN. The server uses production App,
UDP and native callbacks. Narrow encrypted-packet staging and native client
credit adjustment are documented in the retained scaffold.

The original failures remain in the archive. Native state exposed a missing
CONNECT flush. The zero-credit stress fixture failed TLS under the native
transport-parameter sanity policy; its replacement uses a real 4096-byte
credit limit and a larger serialized response head. Neither native policy nor
the reset, response and pool-drain assertions were weakened. Independent
source and scaffold review has no remaining required findings.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` records matching project sources, commands,
reviews, failures and scope. The archive includes the exact required libxev
candidate sources; the separately retained
[lsquic candidate](../../lsquic_webtransport_children_v1/2026_11_16/README.md)
supplies that native source. Both production dependency pins remain unchanged.

Live WT remains disabled on the published lsquic pin. Wire datagram/ring-clear
verification, pending-SETTINGS cancellation execution, early associations,
typed children, multi-session flow accounting and independent draft-16 client
acceptance remain open. Smoke/security runs are deferred by the user; compiled
smoke targets were not executed. This checkpoint does not complete v2.3.0.
