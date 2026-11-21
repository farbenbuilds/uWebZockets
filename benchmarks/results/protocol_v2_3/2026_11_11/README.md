# v2.3.0 protocol evidence, 2026-11-11

These are local loopback protocol checks on x86_64 Linux with Zig 0.16.0,
`ReleaseSafe` native. They are separate from the full release matrix and SQL
performance acceptance.

## Final functional results

| Gate | Result |
| --- | --- |
| Default protocol/server build | `Build Summary: 48/48 steps succeeded` |
| Autobahn | 517/517; 514 OK + 3 INFORMATIONAL for protocol and close; current runtime-equivalence proof retained |
| h1spec maintained commit `999ba9e8f318b1c0ebbff1278b98bc5833f1af18` | `33 out of 33 tests passed.` |
| HTTP/3 ordinary destination `127.0.0.1` | Expanded curl/ngtcp2 and aioquic gate passed |
| HTTP/3 wildcard destination `127.0.0.2` | curl HTTP/3 200 and expanded aioquic probe passed |
| Sustained valid streams, each HTTP/3 destination | 1,024/1,024 completed, 32 concurrent streams, five-second request timeout, zero errors/incomplete |
| Malformed-stream soak, each HTTP/3 destination | 300/300 rejected; healthy sibling and fresh-connection requests succeeded |
| 100 MiB ordinary HTTP/3 upload | RSS 110,376 -> 110,584 KiB: 208 KiB growth against the unchanged 65,536 KiB bound |

Autobahn selects groups 1-7 and 9-13 with no exclusions. Its case set and both
protocol/close classifications must match the exact baseline. No baseline,
exclusion, timeout, allocation bound, or existing HTTP/3 rejection assertion was
relaxed.

Current final-source executable SHA-256 values:

| Executable | SHA-256 |
| --- | --- |
| `h1spec` | `d65c670c5eee628626b56e193da4e5f046259833e6cf8fb2a60adc6a2df30c78` |
| `autobahn_server` | `34595028127478f2158eaf06bdd62bed9b3881f49350db339def83fecd5fe6a5` |
| `http3_server` | `a030db27d0dfb67935a1e4cc93b0296917926a6230cd563f5d27567f6d19e5ee` |

The final Autobahn run executed pre-portability binary
`8858ffeb05b5efd966401b6a6e6bd2b2d1576339522e7e3bd1da41391039c371`.
A final source audit then detected exactly three `msg_controllen` assignments
wrapped in `@intCast` for narrower C header fields on musl. GNU uses the same
source/destination integer width. A GNU rebuild passed 48/48; `objcopy
--strip-debug` copies of all three before/after executables were byte-identical
(`cmp` exit 0), preserving every non-debug byte of the tested Autobahn program.
Original executable files were not modified. Tool identity, full/stripped
hashes, source diff and comparison commands/results are retained under
`portability/`. Short h1spec and expanded ordinary/wildcard HTTP/3 checks were
then rerun on the current full executable bodies above.

## Sustained-stream regression

The fixed receive diagnostic stopped before its measured phase. The original
pre-ownership HTTP/3 binary completed exactly 128 of 1,024 warmup requests,
then 32 requests timed out at the declared five seconds; 896 remained
incomplete. A separate candidate-only functional reproduction hit the same
boundary. The approved diagnostic contract and failed cohort were preserved
unchanged. **Zero measured requests and no successful receive-performance
comparison were collected.** There is no throughput, latency-distribution,
relative improvement, GRO-only causal, or official acceptance claim.

The source audit found that successful request EOF did not acknowledge the
read-side shutdown required by pinned lsquic. Streams therefore did not return
connection stream credit. The protocol owner added the narrow success-EOF
acknowledgment and four centralized regression tests.

The ordinary HTTP/3 gate now starts with the same bounded workload: 1,024
valid GET requests on one connection, concurrency 32, timeout five seconds.
The expanded gate failed on preserved pre-fix binary
`78b7dff346b58fa314b2f83233679368119adb4efbf10ae107db6309f81e8f1e`
at exactly 128 completed requests, then passed on the final binary on both
destinations. Existing trailers, malformed headers, stream error 270,
oversized QPACK, healthy sibling streams, reset soak, upload and fresh health
checks remain required.

The original failed performance contract SHA-256 is
`26fdca33b503f0f90b3540fb80889cbe9435305ae30891ebe416831b96be599f`.
Functional gate duration metadata is not a performance sample.

## Provenance and phases

| Archive prefix | Scope |
| --- | --- |
| `original/` | Initial pre-ownership Autobahn 517 baseline pass and h1spec 33 pass, with exact original binaries/hashes |
| `pre-eof-fix/` | Combined ownership/GRO candidate: separate Autobahn 517 and h1spec 33 passes, then ordinary and wildcard HTTP/3 passes before the sustained regression was added |
| `diagnostic-failure/` | Unchanged failed performance contract/driver/cohort, candidate functional reproduction, and explicit zero-measurement outcome |
| `stream-fix/red/` | Expanded ordinary gate failure on the preserved pre-fix candidate |
| `stream-fix/green/` | Final expanded ordinary and wildcard HTTP/3 reports, versions, traces, qlogs and upload RSS |
| `stream-fix/autobahn-reports/` | Final-binary full Autobahn reports |
| `portability/` | Final three-cast source snapshots, runtime-equivalence proof and current-binary short rechecks |
| `tools/` | Exact-pin h1spec source/fetch log, unchanged Autobahn inputs, client retrieval/version evidence and dependency provenance |
| `commands/` | Exact invocation wrappers and source-snapshot helpers |

The initial full source snapshot was not captured; the archive retains its
original executable bodies and recorded hashes. The pre-EOF red executable is
also retained. Redundant later executable bodies are omitted; their complete
project source inputs, commands, full/stripped hashes and raw comparison results
remain available. The pre-EOF and final source
snapshots retain actual build input bytes, tracked patches, untracked input
lists, modes, base commits and SHA-256 manifests. A base commit alone is not
the identity of these uncommitted candidates.

Post-EOF pre-portability source archive SHA-256:
`f66317f9710612944982d980b590b06a6cddc5bf7a9211d14497c01b156c7152`.
Final portability source archive SHA-256 before and after the short rechecks:
`14d141dc98522fea4a34957fcf442933b68ac40d70ad8810bb46c7318d223021`.
Every captured project input checksum matched before/after those rechecks.

A broad input check during the pre-EOF phase detected authorized changes to
`builds/fuzzing.zig` and `examples/sql_httparena.zig`. The failed check and exact
diff are retained. A current-tree cached rebuild then reproduced all three
tested pre-EOF executable hashes; the check was not weakened.

Root confirmed that the separate libxev Cancel-mapper experiment did not
modify the dependency cache or any protocol build input. These protocol
binaries used unchanged libxev pin
`c49f6dfb83038c146232472c063e4b2681d098d8`. The known unmerged typed poll-cancel
issue is separate from these passing protocol results.

The h1spec client ran in an isolated checkout of the required full commit.
This task preserved the existing `vendor/h1spec` checkout, initially observed
at `f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e`. It does not establish that the main
checkout dependency-fork gate passed; checkout-state records are retained.

## Tools

- Zig `0.16.0`, executable SHA-256
  `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
- Deno `2.9.4`, extracted from cached
  `denoland/deno@sha256:c777b4b225501a61074837e90a826a58f99124837824023cd60334b1e2374498`.
- Autobahn runner image:
  `crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`.
- HTTP/3 clients: curl `8.21.0` with HTTP3, ngtcp2 `1.22.1`, nghttp3 `1.15.0`,
  aioquic `1.3.0`, from unchanged client-flake Nixpkgs commit
  `d57af924f160a5084293c71c2043f058bd1cdb60`.
- Isolated cached bootstrap:
  `nixos/nix@sha256:29fc5fe207f159ceb0143c25c19c774062fee02ce5eda118f3067547b3054894`,
  Nix `2.31.2`. CI installs Nix `2.34.1`; the checked client versions were exact.
- The original cache-image retrieval times are unavailable. Extraction,
  observed versions, executable/image hashes and host metadata are retained.

No host Nix/Deno installation was performed. HTTP/3 clients and the existing
gate ran in an owned host-network container with the repository mounted
read-only. The gate used its existing dynamic-linker override with the locked
glibc 2.42 runtime; executable bodies were not patched. Ephemeral TLS keys
were deleted during runner cleanup and are excluded from the archive.

## Reproduction

Build the checkout with the recorded Zig toolchain:

```sh
export ZIG_GLOBAL_CACHE_DIR=/tmp/uwz-zig-cache
zig build -Doptimize=ReleaseSafe --summary all
```

Run Autobahn with the existing unchanged runner and Deno 2.9.4:

```sh
deno run --no-prompt \
  --allow-net=127.0.0.1:9001 \
  --allow-read=tests/autobahn,zig-out/bin \
  --allow-run=docker,zig-out/bin/autobahn_server \
  --allow-write=tests/autobahn/reports \
  tests/autobahn/server_test.js
```

Start `zig-out/bin/h1spec`, wait for its own listener on port 8000, and run
the retained exact-pin client from its checkout:

```sh
deno run --allow-net=127.0.0.1:8000 http_test.ts 127.0.0.1 8000
```

The archive retains exact isolated clone/fetch and server-cleanup commands.
For HTTP/3, use the locked client flake and the unchanged expanded runner:

```sh
nix develop --no-write-lock-file path:./scripts/http3_compliance -c \
  bash scripts/http3_compliance/run.sh
```

The retained container wrappers set `HTTP3_SERVER_DYNAMIC_LINKER` and
`HTTP3_SERVER_LIBRARY_PATH` to the locked glibc runtime. They record both the
ordinary invocation and the additional `127.0.0.2` invocation. To replay the
red proof, set `HTTP3_SERVER_BIN` to the archived pre-EOF executable and
`HTTP3_ARTIFACT_DIR` to a new output directory before running the expanded
ordinary gate.

Extract the raw evidence with:

```sh
mkdir -p /tmp/uwz-protocol-evidence
tar -xzf raw_evidence_archive.tgz -C /tmp/uwz-protocol-evidence
```

`manifest.sha256` covers this README and the raw evidence archive. All raw
reports, scripts, outputs, source snapshots and executable evidence remain
inside that archive under `benchmarks/results/`.
