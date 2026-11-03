# Passive wire observer evidence

This source-only checkpoint adds a private passive HTTP/2 test observer and
focused checks. It prepares independent receipts for later aggregate binding.
It does not execute the default/all40 matrix or close M2 acceptance.

- [Focused report](../../m2_h2_combined_wire_oracle.md)
- [Exact archive](combined-wire-oracle.tar.gz)
- [Machine-readable manifest](manifest.json)

The archive contains all 43 current source modules, the preceding 41-module
baseline, immutable reference sources and licenses, the new unit's raw evidence,
the interface/design contracts, implementation report, independent reviews and
Root audit helpers/results. Every regular UTF-8 member except the inventory is
size/hash indexed. Historical source and failed attempts remain distinct from
current passing evidence.

The current covering receipts are under `raw/wire-oracle/fix1/`:

- `final-01-focused`: `python3 -B -S test_wire_oracle_checks.py`
- `final-02-focused-optimized`: `python3 -B -S -O test_wire_oracle_checks.py`
- `final-03-imports`: `python3 -B -S test_imports.py`
- `final-04-imports-optimized`: `python3 -B -S -O test_imports.py`

Each uses the exact pinned interpreter and environment recorded in its metadata,
separate stdout/stderr/exit, matching source/helper bytes before and after, and a
fresh pinned-input restoration in the same shell. All four exit zero with empty
stderr. Two normal/optimized strict audits cover the current helpers and these
receipts. The helper shell's inert-argv proof is preserved by unchanged bytes.

The initial implementation and four earlier passing receipts remain historical:
independent review then found decoded HPACK growth before rejection. Two real
regressions reproduce 6075 charged bytes and remaining-budget-plus-one growth.
The fixed preflight rejects oversized names, values and cumulative indexed or
literal fields before materialization while preserving exact 4096-byte limits
and dynamic-table semantics. Scoped independent fix review approves the result.

Fresh integrity audits preserve 13,038 initial historical files and 15,055
pre-fix files. Pinned inputs comprise 119 authority entries, 118 physical rows,
113 resolved sources and 42 ordered codec files. Root's metadata path/argument/
import-context corrections retain their original helper bytes and failure
records; they do not replace the implementation's test results.

The known missing generic Definition of Done reference is documented in the
implementation report; explicit project gates remain binding. No vendored skill
or dependency was edited. No native build, server, socket, TLS-close, real-clock,
process-ownership, actual factory aggregate or retained-client proof ran here.
The observer shares pinned codec implementations with existing tests, so it
does not independently prove those codecs correct. Factory binding, actual
default/all40, full project/native/platform gates and production adoption remain
mandatory.
