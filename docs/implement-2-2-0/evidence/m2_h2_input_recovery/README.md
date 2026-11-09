# Qualified partial H2 input recovery evidence

The [checkpoint report](../../m2_h2_input_recovery.md) describes restored inputs
and historical receipts, followed by a rejected new Debug output. Full recovery
and the original preservation audit have not passed. No ReleaseSafe compilation
or native replay occurred. Historical binary references remain unsatisfied.

[manifest.json](manifest.json) binds [input_recovery.tar.gz](input_recovery.tar.gz)
by size and SHA-256 and records the qualified outcome. All tar members are safe,
regular, nonexecutable UTF-8 files. The archive is below 100 MB. `INVENTORY.json`
binds every other member's complete size and SHA-256.

Three content indices retain each logical path's original bytes, size, SHA-256
and permission mode:

- `RECOVERY_INDEX.json`: the complete frozen `native_environment_recovery`
  packet, including all snapshots, genuine RED, failed startups, fixed controls,
  materialization, Debug rejection and read-only diagnosis;
- `ROOT_RECORD_INDEX.json`: explicit full phase/review reports, original failed
  audit output and Root's component source/executed/hash/result/control records;
- `PUBLICATION_INDEX.json`: sealed publication helper source/executed copies,
  control source, bootstrap receipts, structural and inert-probe evidence.

Each row names an `objects/<sha256>.utf8` or `objects/<sha256>.base64` member.
UTF-8 objects contain the exact original bytes. For base64 objects, strip the
trailing newline and decode standard base64 strictly; verify the decoded bytes
against that row's size and SHA-256. Original modes are metadata in the index;
archive members themselves use mode 0444. Duplicate content shares one object.
Complete member equality and every decoded logical byte and mode were checked
against the scoped inputs. No extraction or replay of archived code is needed
to inspect this evidence.

The authenticated publication API chain is C9a to C8 to C1. Only the pure
object/archive APIs are used; old collectors and native recovery commands are
not invoked. Source/control copies were saved before execution. Pre-publication
controls are sealed inside the archive; build/audit outputs and the final
six-file hash audit remain in the ignored publication packet to avoid circular
self-inclusion.

No actual ELF bytes, generated certificate/key, private environment, or original
`environment.nul` file is included. Permission and hash checks preserve evidence
identity; they do not establish a missing historical host or rebuild cause.
The retained prior 852/852 tests are baseline evidence only. This checkpoint
adds archive/docs/helper verification, with no renewed platform, performance,
production-adoption or full-M2 acceptance claim. Version remains 2.1.6.
