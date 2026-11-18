# Next-version work

Optional additions discovered while closing v2.3.0 belong here. They do not
change the frozen v2.3.0 checklist or defer any of its current requirements.
The version and priority can be assigned after the current release closes.

- [ ] Broaden optional native certificate-storage admission beyond the existing
  SQL configuration: custom native buffer pools, lookup providers, policy
  settings and callbacks, or explicit multi-generation quota APIs. Current
  allocation ownership and final-reference safety remain v2.3.0 obligations.
- [ ] Consider policy-history or forward-reachability optimizations for broader
  native verification configurations. The minimum storage work required for
  the existing SQL allocation and throughput requirements stays in v2.3.0.
