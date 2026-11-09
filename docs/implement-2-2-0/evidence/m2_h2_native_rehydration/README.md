# Source rehydration evidence

The [manifest](manifest.json) binds a regular, non-executable UTF-8 delta archive
and its internal `INVENTORY.json`.

- `packet/`: all 190 reviewed helper, snapshot, control and evidence files.
  Two binary Git receipts use lossless `.base64` members; `BINARY_ENCODING.json`
  binds their original paths, lengths and hashes. Every archive member is UTF-8.
- `evidence/`: full plan, implementation/review records, scoped diff and Root
  live-export/protection audit controls and results.
- `EXPORT_REFERENCES.json`: per-member source identities and observed modes
  for the local candidate and libxev exports. Exported file bytes are not
  embedded again.

The packet authenticates four existing source authorities: native source
preparation, combined input audit, metadata-live and combined fixture. It reads
the nine supplements from archived members and immutable base blobs from Git.
The [C6c parent](../m2_h2_native_active/README.md) authenticates the preserved
native helpers and accepted coordinator; its archive SHA-256 is
`6fda8cfaac4b8c866ff352848c12397a9775a7bd09397f1db7c9740707c50b14`.

The sole actual export is `/tmp/uwz-h2-native-rehydration-c7/`. Candidate and
dependency contents, read-only modes and exact inferred directories were
independently checked. The Git object store intentionally has no refs/remotes;
unborn-HEAD notices are retained separately from successful integrity checks.
Existing/partial destinations are refused without repair or deletion.

Forward preservation includes actual roots, empty directories and absence
observations. The original historical directory state remains unproved. The
25 private environment originals are neither read nor published. No Graphify
closure was recopied, and AST maintenance does not prove ignored-helper
topology. Source snapshots precede execution; the final preflight import-only
cleanup is qualified in the report. Runs 02–08 started with `env -i` and
explicit settings; the initial interface-absence run used the recorded
variables in an inherited shell.

The artifact is source evidence and retained operational controls. Full runtime
bootstrap, fresh Debug/ReleaseSafe binaries, real ownership/process/capture
and cleanup proof, native all40 and release gates remain required. See the
[checkpoint report](../../m2_h2_native_rehydration.md).

Root's initial archive attempt rejected the binary receipts before writing an
archive. Its control and failure remain recorded. The final audit checks both
decoded receipts against the reviewed originals. Repository unit checks pass
852/852 on the tracked baseline; they do not test the reconstructed candidate.
