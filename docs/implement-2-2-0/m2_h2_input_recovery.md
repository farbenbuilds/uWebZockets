# M2: qualified partial H2 input recovery

This checkpoint preserves the reviewed, stopped recovery of temporary inputs.
Exact source and historical data were restored. A new Debug compilation returned
zero, but its output failed the required historical binary-equality guard.
Full recovery is incomplete; the unchanged original preservation audit remains
failed. No new native execution or M2 completion is claimed. Version stays 2.1.6.

The four historical Linux TLS/H2 runs remain recorded in the
[native matrix checkpoint](m2_h2_native_matrix.md), committed as `7eff98b`.
Its archive SHA-256 is
`3fd73226474f685d4813033ba3cdee2c3cfff17f1d2906310e4680eafbeabba6`.
The later temporary loss remains unexplained. Recovery does not replace those
historical acceptance results with a new run.

## Restored inputs and narrower component proof

Materialization returned zero after the reviewed launcher authenticated the
21-row source/control inventory and its entries. The inventory SHA-256 is
`e2a83e86e23aed670bb16632f98d4393dbf67e7ddea127c9ae245f07007a0a6c`;
the separate launcher SHA-256 is
`4e6faf371c940f322c5221eb48cd165c09fdd2044adc010c82e5a9d6c3d7edaa`.
The independently bound launcher avoids trusting a changed source together
with an updated inventory row.

The restored C7 candidate and isolated libxev exports match their authenticated
origins. Fixture inputs include 25 files and the generated C input. Four
historical acceptance JSONs and eight captures were restored byte for byte.
The historical Debug and ReleaseSafe receipt bytes were restored; command JSON
is semantic reconstruction, with historical serialization unproved. The
original test cache was newly empty.

Root's separate component audit returned zero and checked:

- 5,036 unchanged C8 paths and eight direct inputs;
- candidate 1,031 files/208 directories and libxev 93 files/20 directories;
- 19,542 SDK files, 14 zslay files, required modes and absence checks;
- historical receipt/capture bytes and the 34-file safe evidence index.

The component proof uses archived historical binary declarations. It does not
verify current historical ELF identity or pass the full original preservation
audit. Its complete source, executed copy, code hashes, output and result are
included in the new [evidence archive](evidence/m2_h2_input_recovery/README.md).
The original terminal-one audit output remains included as a failure.

## Debug equality rejection

The actual Debug compiler returned zero with empty stdout and stderr. The
reviewed driver then returned one at `Compiler binary differs; stop`, after its
post-compiler identity/export checks.

| Debug output | Bytes | SHA-256 |
| --- | ---: | --- |
| Required historical output | 72,174,904 | `4c89d63f760f467315e83d8c40021f49335b432490e9a06f8cf3f604e69bb476` |
| Observed, rejected output | 72,162,616 | `6d3953c9a85481fa234f94b239d886c677168c3a6d28dc24127953126296a927` |

The rejected file is 12,288 bytes smaller. It remains at the compiler's output
path; this archive contains its recorded observations, never the ELF bytes or
an encoding of that output. There was no ReleaseSafe compilation, retry,
flag/source/recipe change, output promotion, target execution or native replay.
The old receipts' binary references remain unsatisfied. New empty compiler
streams remain separate from the restored historical receipts.

## Diagnosis and remaining limits

Recorded argv, cwd, explicit environment, remaps, preflight and tool/source
identities match the authenticated original records. The compiler recipes
leave the native target implicit. Host detection is therefore a plausible
unbound input; it is not a demonstrated cause of this byte difference.
Historical CPU/kernel/resolved native target and filesystem/cache metadata
were not retained. No old ELF or old section summary was available to localize
the difference to code, debug data, alignment or another section.

The bounded copy search inspected 78,993 safe regular-file metadata rows and
found no exact-size candidate, so it hashed no candidate contents. A separately
permitted literal cache target was absent. This does not establish that no copy
exists outside the searched scopes. No guessed-CPU rebuild was authorized.

The lossless archive retains genuine behavioral RED results, failed startup
checks, corrected controls, both rounds of findings and fixes, phase-two STOP,
diagnosis and the qualified final review. Initial source/cache and Git-admission
findings were addressed, followed by the independent launcher fix. The final
review supports publication with the failed audit and these limits intact;
the reviewer did not rerun the compiler, component audit or native matrix.

Publication verification covers helper structure/inert behavior, decoded
content bytes/sizes/SHA-256/modes, complete archive membership and local links.
The prior 852/852 repository tests and 22/22 build steps are retained baseline
verification only, with a warm compiler cache and retained diagnostics. Zig and
native suites were not rerun for this documentation/evidence checkpoint.
No source, pins, versions, quality gates or original evidence were changed.

Any fresh acceptance needs a separate checkpoint and authorization, with new
Debug/ReleaseSafe identities, resolved target/CPU and metadata/cache policy,
runtime closure, four owned full40 runs and independent review. It cannot
inherit historical PASS or satisfy the old equality audit. Production adoption,
H3, multipart transport, early data and the remaining ownership/platform/release
gates keep M2 open.
