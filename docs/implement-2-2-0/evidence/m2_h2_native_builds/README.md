# Native build evidence

The [manifest](manifest.json) binds the regular, non-executable UTF-8 archive
and its complete `INVENTORY.json`.

- `packet/`: all 1,411 frozen implementation, snapshot, control and result files,
  including original failures and the corrected prior-approval proof.
- `evidence/`: architecture, requirements, implementation reports, both review
  verdicts, scoped diffs, independent input/output audit and repository checks.
- `BUILD_REFERENCES.json`: accepted binary paths, sizes and hashes; toolchain
  and binary bytes are not embedded.

Only the corrected `/tmp/uwz-h2-native-c8-fix1/` runtime/build receipts establish
this checkpoint. The original `/tmp/uwz-h2-native-c8/` successful outputs remain
recorded with runtime acceptance unestablished. Actual compiler executions were
sequential in each attempt; wrapper pre/postflight lifetimes overlapped.

The final preflight is
`e78cbbc2f1665e6999a5502f2817be531909a80d72e1dbd0fd22055dc93bb53c`.
Both corrected compiler streams are empty and terminal statuses are zero.
The ELF-only inspection is
`334a4c9e27b9837f9aa65bd01ffcc01328e79fdc59e003f5236bcd23921b0cd5`.

Prior source versions, the P1 review and genuine construction regressions are
retained. Root's failed audit controls are preserved; the initial restoration
stdout was superseded, while its original JSON receipt remains. Final source,
bootstrap, tool and data controls precede the successful independent audit.
Private original environments are neither read nor included.

Historical SDK directory state, kernel/CPU/vDSO/anonymous-memory behavior and
concurrent check/open races remain outside this proof. AST maintenance does
not establish ignored-helper topology. Future imports require approved native
graphs; the current manifest is scoped to executed metadata. See the
[checkpoint report](../../m2_h2_native_builds.md) for native execution and
remaining milestone limits.
