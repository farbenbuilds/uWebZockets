# Next-version work

Optional additions and explicit user deferrals discovered while closing v2.3.0
belong here. Optional additions do not change the frozen v2.3.0 checklist.
The version and priority can be assigned after the current release closes.

- [ ] Broaden optional native certificate-storage admission beyond the existing
  SQL configuration: custom native buffer pools, lookup providers, policy
  settings and callbacks, or explicit multi-generation quota APIs. Current
  allocation ownership and final-reference safety remain v2.3.0 obligations.
- [ ] Consider policy-history or forward-reachability optimizations for broader
  native verification configurations. The minimum storage work required for
  the existing SQL allocation and throughput requirements stays in v2.3.0.

## User-deferred Daybreak work, 2026-11-18

The user instructed: "for the task require daybreak skip it for next version".
Defer tasks actually blocked by that safeguard; continue permitted work without
retrying the blocked campaign or claiming its missing evidence as a pass.
The user reiterated that this applies to every task requiring Daybreak.
The user will handle these tasks later. Do not resume them automatically or
start another dependent allocation-ownership task as a substitute.

- [ ] Complete the X.509 name-cache allocation-failure regression campaign.
  The isolated parent control passes, and the first cache-allocation failure
  reproduces a crash. A three-line null guard has source review and a passing
  74-step native build, but the corrected regression campaign is unverified.
  Keep this candidate separate from the verified allocation-operation packet.
  Local work is under
  `.zig-cache/tls-residual-ownership-20261118/name_cache_oom/`; the candidate is
  in `deferred_candidate/crypto/x509/x_name.cc` and the working native file
  is restored to its parent bytes. Scratch retention is not a published fix.
  Resume only when this deferred work is authorized and its environment permits
  it. The strict PostgreSQL allocation gate still has no passing result.
- [ ] Complete the owned ASN.1/X.509 certificate-decoder integration and its
  dependent verification. The primitive-leaf and template-engine assignments
  also stopped at the safeguard. They left their native files at the recorded
  parent hashes; no working decoder or zero-allocation decoder result exists.
  The deferred scope includes explicit allocation targets through primitive
  and template decoding, X.509 names/public keys/extensions, dependent key and
  diagnostic ownership, and the TLS cache/capacity/SDK integration needed to
  close the certificate allocation family. The private-entry compile RED and
  unrun functional proof draft remain under
  `.zig-cache/tls-certificate-decoder-20261118/decoder_evidence/` and `proof/`.
  These are next-version starting points, not release acceptance evidence.
- [ ] Complete the reserved TLS error-snapshot ownership change and its
  dependent probes. This work also stopped at the safeguard and is deferred
  for the user. The missing-interface compile RED and unrun proof draft are
  under `.zig-cache/tls-reserved-error-ownership-20261118/`.
  The three unverified native edits were saved under `deferred_candidate/`
  and the working native files restored to their recorded parent bytes.
  No candidate build, runtime ownership result, allocation reduction or SSL
  reservation result is established. Resume only on the user's explicit request.
