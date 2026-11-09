# Connection construction source evidence

The [manifest](manifest.json) binds this source-only delta archive. Its internal
`INVENTORY.json` records every public regular, non-executable UTF-8 member.

- `source/current/`: seven current native helper/test modules.
- `baseline/`: the parent checkpoint's five native sources.
- `reference/`: authenticated canonical and combined source references.
- `raw/native-transport/`: new control/code snapshots, safe environment
  settings, commands, restored-input receipts, failures and final results.
- `evidence/`: full reports, original finding, approved fix, review packages
  and Root verification controls.

`TOOL_SNAPSHOT_REFERENCES.json` explicitly indexes omitted Graphify-tool source
and binary snapshots by size and SHA-256, checked against their captured
`source.sha256` records. Originals remain local. These tooling-only bytes are
not embedded, native authority or promised portable inputs. Other new raw
evidence is retained exactly.

The parent public packet remains in the repository's
[native-post checkpoint](../m2_h2_native_post/README.md), archive SHA-256
`d19281da19d04c3afbc3bb97ef614b21efa3746f0dc405dfb982d7cc959fbe92`.
The 6,482-path public view and its explicit environment projections were
preserved; private originals are outside this delta. New runners use an empty
inherited environment and explicit safe controls.

The intermediate-close regression reaches the real coordinator's second
connection before an expected sentinel; it does not prove a completed two-case
or native run. Strict disconnect, active hooks, provider authenticity, cleanup,
runtime/build/native all40 and final project gates remain open. See the
[checkpoint report](../../m2_h2_native_connection.md).
