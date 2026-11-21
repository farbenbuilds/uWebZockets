# Third-Party Notices

µWebZockets includes or links the following third-party software:

| Component | Version or revision | License |
| --- | --- | --- |
| zslay | 0.2.1 | MIT |
| libxev | c49f6dfb83038c146232472c063e4b2681d098d8 (farbenbuilds fork, base 9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf) | MIT |
| BoringSSL | 0.20261020.0 (d3bf4795ad5b79d646cddf2fec687da5b9b502db) | ISC-style and component licenses |
| Fiat Crypto (via BoringSSL) | BoringSSL revision above | Apache-2.0 |
| lsquic | 85bd081c9103c077a7cc98271d09334d0f1043d4 (farbenbuilds fork, base 4.10.2 a9616720af78b9aab895145c1792d5305c480ae8) | MIT and bundled component licenses |
| ls-qpack | 2.7.0 | MIT |
| ls-hpack | fda48e02491d865cce00612be8cc10c2622b8e55 | MIT |
| libdeflate | 1.26 | MIT |
| zlib | 1.3.2 | zlib License |
| Unicode SASLprep data (optional SQL authentication) | Unicode 3.2, RFC 3454/RFC 4013 tables | Unicode License V3 |
| SQLite (optional) | 3.54.1 (amalgamation SHA3-256 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30) | Public domain |
| h1spec | 999ba9e8f318b1c0ebbff1278b98bc5833f1af18 (farbenbuilds fork, base f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e) | Unverified; maintainer confirmation required |

The pinned h1spec compliance source contains no license notice. Its previous
MIT attribution is unverified. h1spec is a test-only submodule: it is not
compiled into `libuWebZockets`, linked into a consumer artifact, or included in
the package `.paths`. The maintainer must confirm attribution before
redistributing the submodule itself; the release checklist in [TODO.md](TODO.md#82-re-declared-to-230) carries the
open item.

The zslay, libxev, and zlib license texts are in the licenses directory, and
the C and C++ license texts are in `licenses/vendor`. Sources are selected by
immutable Zig package hashes or pinned release tags; the repository retains
the `vendor/h1spec` compliance submodule and optional SQLite amalgamation. Releases publish the tagged
source only, with these license texts in-tree, so no binary archive copies
licenses separately.

The optional SQLite backend retains its unmodified, pre-generated source and
header, including their public-domain notices, under `vendor/sqlite/`.
[SQLite provenance](vendor/sqlite/provenance.md) records the immutable archive
and verified checksums. It is compiled with Zig's C toolchain only when both
`-Dsql=true` and `-Dsqlite=true` are enabled.

The maintained downstream forks are
<https://github.com/farbenbuilds/libxev>,
<https://github.com/farbenbuilds/lsquic>, and
<https://github.com/farbenbuilds/h1spec>. `build.zig.zon` pins libxev at
`c49f6dfb83038c146232472c063e4b2681d098d8` on `uwz/zig-0.16` and lsquic at
`85bd081c9103c077a7cc98271d09334d0f1043d4` on `uwz/main`; the h1spec
submodule points at `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` on `uwz/main`.

- libxev carries XEV-001 through XEV-005: IOCP accept-socket ownership, Winsock
  error mapping, kqueue rearm/duplicate-queue repair, and kqueue dispatch/active
  count hardening.
- lsquic carries LSQ-001, which keeps positive header-callback results and
  ambiguous content lengths stream-scoped, and LSQ-002, which commits the
  generated version table so the build runs no Perl.
- h1spec carries H1S-001, which closes and unreferences completed test
  connections so the Deno runner exits cleanly.

No local `patches/` directory, `vendor/lsquic_overlay`, or CI `patch` step
remains. `scripts/check_dependency_forks.sh` verifies every pin, the dependency
views, remote reachability, and the fork mirrors. See
[ADR 0005](docs/adr/0005-libxev-fork.md),
[ADR 0006](docs/adr/0006-dependency-forks.md), and
[docs/dependency_forks.md](docs/dependency_forks.md).

SQL SCRAM authentication includes pinned Unicode 3.2 normalization and
SASLprep tables in `src/sql/unicode_3_2.zig`. The original generation used
Python 3.14.4's `unicodedata.ucd_3_2_0` and `stringprep`; the Unicode database
version is asserted separately from the host Unicode version. The data is
covered by [Unicode License V3](licenses/unicode_data.txt), retrieved from
<https://www.unicode.org/license.txt> on 2026-11-11. Its source specification is
[Unicode 3.2](https://www.unicode.org/Public/3.2-Update/UnicodeData-3.2.0.txt),
[composition exclusions](https://www.unicode.org/Public/3.2-Update/CompositionExclusions-3.2.0.txt),
[RFC 3454](https://www.rfc-editor.org/rfc/rfc3454), and
[RFC 4013](https://www.rfc-editor.org/rfc/rfc4013).
`misc/generate_sql_unicode.py` is a deterministic maintenance tool. Generated
inputs are checked in; Python is never invoked by the Zig build or required
by library consumers. The table lookup, normalization, and authentication
paths allocate no storage dynamically.
