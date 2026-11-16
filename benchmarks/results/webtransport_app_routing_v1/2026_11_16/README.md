# App routing and deferred admission evidence, 2026-11-16

The unchanged production source at
`d9f3305313bc2bdc1bc92f4701cd7113b4042653` passes 18 Zig tests in Debug,
ReleaseSafe and ReleaseFast, 16/16 build steps per mode. These are 17
functional cases and one import-discovery anchor: the eight prior admission
cases plus nine routing, cancellation, capsule and cooldown cases. The fresh
published-dependency central suite passes 991/991 tests in 20/20 steps.

Real native DATAGRAM generation and production UDP reception prove callback
payloads, registered route identity after actual header-slot reuse, distinct
rings on two connections sharing session zero, ring overflow/recovery and
receive-ordinal gaps. Close clears queued data before client EOF; connection
abort/reuse clears the ring, invalidates the old handle and starts the new
generation's ordinal at zero. DRAIN still permits delivery.

Negative datagram assertions use an isolated known native DATAGRAM packet,
writer/output counts and actual server packet/decryption/error counters.
They do not rely only on waiting for a missing callback. This is a packet and
source-based arrival argument, without replacing the production callback or
claiming a dedicated native per-datagram receive counter.

The candidate's existing test observer holds and resumes the client's original
SETTINGS writer. Positive admission resumes once. Cancellation tests cover
RESET known before deferred notification and synchronous STOP, with actual
state observed before SETTINGS release. Two ordering cases stage genuine
encrypted packets into native input before one ordinary engine process call;
this narrow seam is documented separately from the normal UDP cases.

Fragmented invalid flow-control input is ignored in flow-off mode. Native DATA
remaining-length observations prove each payload byte is consumed before the
next fragment. DRAIN permits a further datagram; Close clears the session/ring
and sends server FIN while the client send half is still open. Client FIN is
sent separately afterward. Datagram-triggered cooldown is deferred during the
callback and reaches actual native GOING_AWAY state after unwinding.

Independent reviews found and resolved proof gaps in callback payload checks,
cancellation order, fragment consumption, native cooldown effects and
Close-before-FIN separation. The archive retains earlier outcomes with their
original limits. No production fix, dependency pin change or activation-policy
change was needed.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
`files.sha256` inside. `HANDOFF.md` records exact source inventories, commands,
profiles, reviews and scope. The scaffold includes the required libxev source;
the separately retained
[lsquic candidate](../../lsquic_webtransport_children_v1/2026_11_16/README.md)
supplies that source. Formatting, conventions and release metadata checks pass.

The published pin keeps live WT disabled. Early associations, positive typed
App children, multi-session flow accounting, independent draft-16 client
acceptance and fork publication/pins remain open. Smoke/security campaigns
remain deferred by the user. This evidence does not complete v2.3.0.
