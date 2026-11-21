# Reviewed SQL TLS source proposal

SDK base: `8ba96369f9f9492cd23c59b9e934ecaf7d241759`.
The reviewed native changes are retained as unpublished Git commit
`33406dd2383eff3e84059a763933b010cc5a663d`, with official parent
`d3bf4795ad5b79d646cddf2fec687da5b9b502db` and tree
`9bba91e966828b1d5e8ab51f9721a39446febc04`. This is one cumulative proposal
containing fifteen reviewed paths, rather than fabricated experimental history.
It does not change production pins or integrate the candidate into SQL.

All 8,709 original files match the official Git tree by content and type, with
no extra or missing paths. All proposal contents match the frozen candidate.
The extracted package differs from official Git executable modes on 59 paths;
none intersects the 407 native source inputs, 167 generated entries or fifteen
changed paths. The proposal preserves official Git modes. Generated inputs,
licenses and notices remain unchanged.

The archive includes a 17,000-byte prerequisite Git bundle, SHA256
`fcd2eef3395e42b4198abe7d055038031b7438dbbfa40f44a4ef8fd731918da6`.
**Complete official base history is external and is not embedded.** Restoration
requires an existing complete-history local repository with HEAD at the exact
official parent. The separate 253,386,995-byte full-history bundle remains an
external local artifact; its identity is recorded without claiming to ship it.
No Git database, full source checkout, compiler or native library is embedded.

The producer and independent reviewer checked every source content and Git mode,
the exact commit/parent/tree, compact bundle identity and all retained payload
hashes. Root independently restored from a base-only repository, proved the
proposal object absent before bundle import, ran full Git integrity checks and
verified all 8,709 restored files. Three refusal controls preserve existing
output or create no output for wrong-base and wrong-bundle inputs. The ordinary
production-pin unit suite passed 1,158 of 1,182 tests; 24 live PostgreSQL tests
were skipped without fixture credentials. Native runtime tests were not rerun
for this source-packaging step; their existing evidence is identified explicitly.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify
its top-level `files.sha256`. The unchanged producer payload and manifest are
under `source_proposal/`; Root verification and independent review are under
`root_checks/`. From the extracted directory, restore into an absent directory:

```sh
python3 source_proposal/restore_prerequisite_bundle.py \
  source_proposal/boringssl_sql_client_tls_prerequisite.bundle \
  /absolute/path/to/exact-official-base-repository \
  /absolute/absent/output
python3 source_proposal/verify_restored_source.py /absolute/absent/output
```

These commands use local Git objects and perform no network fetch. The helper
rejects existing output, wrong bundle identity, unexpected refs/prerequisite,
wrong base HEAD/tree or shallow base before creating output. Git and Python are
evidence tools, with no new library build requirement.

Publication destination, maintained-fork policy, production pin adoption,
fragment-safe SQL preparation, error/reconnect/cancel allocation work and the
whole PostgreSQL allocation proof remain open. SQLite's approved exception does
not cover PostgreSQL. Dedicated smoke/security/sanitizer/fuzz/scan campaigns
remain user-deferred; configured gates are unchanged.
