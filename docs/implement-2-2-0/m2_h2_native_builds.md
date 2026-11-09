# Native HTTP/2 runtime inputs and fresh builds

Fresh Debug and ReleaseSafe fixtures compile successfully from the reviewed
[reconstructed candidate](m2_h2_native_rehydration.md). Their complete input
rechecks and executable metadata inspection pass. This checkpoint compiles the
fixtures; it does not execute the HTTP/2 matrix.

| Mode | Binary bytes | SHA-256 |
| --- | ---: | --- |
| Debug | 72,174,904 | `4c89d63f760f467315e83d8c40021f49335b432490e9a06f8cf3f604e69bb476` |
| ReleaseSafe | 31,072,272 | `94510b8b95880b084f5a2250fd825db181cc9f1320d36f59130f3bdcf64d2f10` |

The accepted outputs are under `/tmp/uwz-h2-native-c8-fix1/`. Recipes preserve
the historical argument order and module scopes, with explicit source, cache
and output remaps. Both use Zig 0.16.0, six authenticated static archives and
the authenticated pre-generated C module. Production dependency pins stay at
their recorded versions; the historical c223 libxev override is test evidence.

## Runtime authorization and review

Initial review found that discovery automatically authorized new or changed
native dependencies. The original successful compilations remain recorded,
but their runtime-acceptance claim is superseded.

The correction compares every discovered ELF identity and dependency with an
independent approval map before admission. It authenticates historical inputs
and separately pinned tool/data controls. Real construction regressions reject
unknown and changed discoveries; an identity-bound extension without an
approved native graph is rejected before loading. Eleven focused groups plus
inert CLI checks pass in normal and optimized Python. Foreign-directory
inspector checks also pass. Independent scoped review closes the finding.

The corrected manifest binds 5,038 runtime paths and 44 ELF objects for the
executed metadata phase. Other historical extension identities do not grant
permission to import them. Future provider sources, imports and native graphs
need explicit authorization before execution.

## Independent checks and remaining work

Independent inspection rehashed current input and output bytes, checked exact
tree sets and read-only source modes, and reconstructed both compiler commands
from the immutable historical receipts. It checked candidate 1,031 files,
libxev 93, fixture 25, SDK 19,542, zslay 14 and 480 bytecode absences. Seven
current SDK directories absent from the historical file-derived set establish
forward preservation; their historical state is unproved.

Root's audit first omitted the interpreter's real path, then reused a
restoration receipt. Both setup failures remain recorded. The corrected audit
used the pinned bootstrap controls and a fresh receipt and passed.

Repository formatting, conventions, version, dependency and unit checks pass;
the tracked-baseline suite reports 852/852 tests and 22/22 build steps. Expected
negative-test diagnostics remain in the raw output. Reconstructed-fixture
runtime tests remain open.

The [evidence archive](evidence/m2_h2_native_builds/README.md) retains source,
controls, review verdicts, failures, recipes, raw results and exact binary
references. Tools and binaries are referenced without embedding their bytes.
The controls depend on the recorded local layout and historical bootstrap;
clean-machine reproduction remains open.

No target executable, provider, SSLContext, certificate operation or socket ran
in this checkpoint. Real ownership, process/capture completion, normal cleanup,
combined native all40, H3, production adoption and remaining repository/platform
and release gates remain required. M2 is open.
