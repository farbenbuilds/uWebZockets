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

- [ ] Complete the X.509 name-cache allocation-failure regression campaign.
  The isolated parent control passes, and the first cache-allocation failure
  reproduces a crash. A three-line null guard has source review and a passing
  74-step native build, but the corrected regression campaign is unverified.
  Keep this candidate separate from the verified allocation-operation packet.
  Local work is under
  `.zig-cache/tls-residual-ownership-20261118/name_cache_oom/` and its sibling
  `boringssl/crypto/x509/x_name.cc`; scratch retention is not a published fix.
  Resume only when this deferred work is authorized and its environment permits
  it. The strict PostgreSQL allocation gate still has no passing result.
