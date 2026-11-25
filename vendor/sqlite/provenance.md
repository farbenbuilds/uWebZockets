# SQLite 3.54.1

Upstream: <https://www.sqlite.org/>.
Source archive: <https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip>.
Retrieved: 2026-11-11 UTC.
License: public domain, as stated in the unmodified source/header notices and
<https://www.sqlite.org/copyright.html>.

The published archive SHA3-256, verified before extraction:

```text
92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
```

Retained, unmodified files and SHA-256:

```text
0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52  sqlite3.c
d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c  sqlite3.h
```

The amalgamation is pre-generated upstream. `builds/sql.zig` compiles it with
Zig's C compiler only when both SQL and SQLite are enabled. No configure,
code generator, system SQLite, extension loader, or build-time download runs.
The public header identifies the full immutable source revision in
`SQLITE_SOURCE_ID`; no vendor changes are applied.
