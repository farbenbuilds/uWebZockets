# Client wire-storage ownership, 2026-11-18

This experimental checkpoint owns the remaining selected client wire-storage
family through initial handshake, HRR, preparation, established reuse, clear and
free. It preserves the complete worker-wide PostgreSQL lifecycle intervals.
Production source/pins are unchanged and the strict PostgreSQL zero-allocation
gate remains RED.

## Measured behavior

Every row below ran three times with equal functional, callback, preparation,
pool and interval invariants. Counts are malloc/calloc/realloc/free/requested
bytes from the unchanged ordinary counter.

| Full lifecycle interval | Parent | Owned wire storage |
|---|---|---|
| Failure | 242 / 2 / 0 / 244 / 340927 | 199 / 2 / 0 / 201 / 34665 |
| Cancellation | 484 / 4 / 0 / 488 / 681854 | 398 / 4 / 0 / 402 / 69330 |

Across the six intervals, the reduction is 387 malloc/free pairs and 2,756,358
requested bytes. Remaining allocations are counted. These results do not claim
a zero-allocation whole handshake, total TLS capacity or complete v2.3.0 delivery.

Final native verification recorded 67/67 steps, including fixture-witness
compilation. The ordinary constructor proof retains 26 rows, with 24 strict-zero
rows. The wire proof has 13 generic rows, 10 strict-zero rows, and two additional
strict-zero public fatal-alert regressions. The verified fixture matrix contains
36 rows: 33 normal preparation rows and three immutable-context TLS1.3
clear/ticket/resumption controls. Unsupported readiness in those controls is
explicit. Nine additional framed-byte cases remain separate from complete
verified handshakes. IPv6 certificate identity is verified; IPv6 TCP transport is
not claimed.

The final SDK and unchanged Root live suites passed all 1214 and 1182 tests
respectively. Final ReleaseSafe compilation and ReleaseFast library build passed.
Initial failures and diagnoses are retained separately, including the two real
public fatal-alert RED witnesses that led to the final source fix. The final
restore helper, after adding SDK/contract bindings and the exact auxiliary-plan
guards, passed a fresh 64/64 `proof` plus `wire-proof` build. All 34 optimized-
Python rejection cases passed. The earlier 64-step/29-case helper revision is
retained as history and is not the current acceptance count.

## Inherited verification and compiler modes

The historical Debug campaign rebuilt and exercised 26 executables with 173
commands. All 95 archived original inputs and their original verifiers remain
unchanged, and that campaign passed.

ReleaseSafe exercised the same 26 programs with a separate calloc-aware fault
observer. Compiler-folding diagnosis, the initial malloc-only fault-observer
failure and the original Debug-vector verifier failure are retained. The observed
ReleaseSafe startup vector is exactly 9 mallocs, 2 callocs and 291926 requested
bytes. The additive mode-specific verifier passes while retaining total 11
requests and every other assertion. The historical Debug-specific verifier's
RED result is preserved. These campaign distinctions are recorded in
`proof_evidence/wire_verification_report.json` and
`proof_evidence/wire_inherited_safe_result.json`.

## Delivered evidence and source identities

The directory contains exactly this README, `manifest.sha256` and one
the omitted raw evidence archive. The original archive contained `sql_tls_client_wire_storage/`.
Its regular-file checksum map and payload mode identity cover every archived
input, including source, commands, raw results and first-failure evidence.

The native candidate has 8710 files derived from an external 8709-file immutable
parent: 15 modified paths and new `crypto/buf/internal.h`, with no removals or
existing mode changes. Only those 16 native replacement/addition files are
bundled. The complete 503-file SDK is bundled once; its parent has 501 files.
All 118 final proof inputs and the one exact auxiliary inherited-plan input are
hash/mode bound. SDK, native and contract digests are checked against the final
proof identity before restore output creation.

| Input | SHA-256 |
|---|---|
| Native source identity | `6fb0396e4a2a2b29d95d109e12f9ce64a52cf708479062a39da245e981a1f766` |
| Native diff | `9345cf2e348f3d8f8465ff99414cc2546896c7d8a8fc141afe6ca7790480fdef` |
| SDK source identity | `5e2a5c8b807782fbfc095f944b9ac64ef2d48909ed1ad92683a4b88d9f9dfd5f` |
| Contract | `34bb38ba77211604d77d725352370bd9874214a68d9c302e84504ebf63265ab9` |
| Final proof identity | `956ed6a8b84faab44fe4aa8d9968f89fc23edb7890fd8211b92a6a69f821bc53` |
| Zig 0.16.0 executable | `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` |

There are 49 selected ELF payloads: 19 native executables, all 26 final
ReleaseSafe inherited executables and four observation/lifecycle executables.
All 75 initially selected binary identity rows remain in
`source_identity/binary_payload_map.initial.json` and the current map. Exactly
26 historical Debug ELF payloads have `bundled: false`; their executed hashes,
full sources, commands and results remain available. All 56 final executed
binary identities are preserved separately. The omitted Debug binaries can be
rebuilt with the command below. Path-dependent rebuilt Debug hashes must be
recorded for the new run.

The all-75 executable estimate was 128,556,271 compressed bytes. Root explicitly
approved the exact 26-Debug-payload selection after its measured estimate was
92,397,629 bytes, below 100 MiB. Both estimates and the selection authorization
are retained. Proof modules were stripped at link; observation/lifecycle
executables retain their full DWARF and original bytes. No post-link stripping
or executable rewriting occurred during packaging.

Generated private fixture material, private environment files, caches, object
files and native archives are excluded. Four exact hash-pinned public SDK `.env`
files remain as source inputs. Root recorded zero matches for its exact generated
PEM/DER/password patterns and removed only its labeled disposable container and
private fixture. See the public scan and cleanup records for their precise scope.
Dedicated smoke, security, sanitizer and fuzz campaigns remain user-deferred;
configured gates and benchmark thresholds were not changed.

## Reproduction

Use x86_64 Linux, the checksum-pinned Zig 0.16.0 executable, and the exact external
native parent restored from the preceding ownedSSL construction checkpoint. Its
full identity is included. The archived layout checks for other targets are
compile/layout evidence, not runtime support claims. Python handles evidence
validation and fixtures; Zig alone compiles the native source graph.

First verify the outer checksum and extract with file permissions preserved.
Source identities include modes such as 0664; a caller's umask must not change
them to 0644 before validation.

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Set absolute paths to the extracted packet, compiler, absent output and immutable
native parent. Keep all outputs outside the extracted evidence and parent trees:

```sh
PACKET=/absolute/extracted/sql_tls_client_wire_storage
ZIG_016=/absolute/zig-0.16.0/zig
PARENT_NATIVE=/absolute/owned_ssl_parent/boringssl
REPLAY=/absolute/absent_wire_replay
python3 "$PACKET/restore.py" --parent "$PARENT_NATIVE" --output "$REPLAY" --zig "$ZIG_016"
```

Restore verifies complete parent/candidate source sets, hashes and modes, copies
the exact proof/replay inputs and rebinds only the SDK builder's native source
path. It explicitly builds and runs both `proof` and `wire-proof`; the expected
fresh result is 64/64 steps. The bare historical default `proof` target does not
cover the new wire proof. The separate `wire-handshake-build` target compiles the
fixture-dependent witness.

For a fresh fixture, copy the public helpers into a new external directory before
executing them, because setup writes beside its script. Docker and OpenSSL are
fixture tools. The PostgreSQL image is pinned in the helper.

```sh
FIXTURE=/absolute/absent_wire_fixture
mkdir "$FIXTURE"
cp "$PACKET/fixture/setup_fixture.py" "$FIXTURE/"
cp "$PACKET/fixture/add_unicode_roles.py" "$FIXTURE/"
cp "$PACKET/fixture/add_ipv6_identity.py" "$FIXTURE/"
python3 "$FIXTURE/setup_fixture.py"
python3 "$FIXTURE/add_unicode_roles.py"
python3 "$FIXTURE/add_ipv6_identity.py" --fixture "$FIXTURE"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FIXTURE/private_fixture/untrusted.key" -out "$FIXTURE/private_fixture/untrusted.pem" -days 1 -subj /CN=uwz-untrusted
```

The IPv6 helper creates `private_fixture/ipv6_server.pem` from that fixture's CA
without changing the PostgreSQL server leaf. The witness receives the private
fixture directory:

```sh
cd "$REPLAY"
"$ZIG_016" build wire-handshake-build -Doptimize=ReleaseSafe -j4 --cache-dir cache --global-cache-dir global-cache --summary all
./zig-out/bin/wire_handshake "$FIXTURE/private_fixture"
```

Rebuild the omitted historical Debug programs and run the original verifiers:

```sh
"$ZIG_016" build native -Doptimize=Debug -j4 --prefix "$REPLAY/native-debug" --cache-dir "$REPLAY/cache-debug" --global-cache-dir "$REPLAY/global-cache" --summary all
python3 "$REPLAY/proof/inherited_wire/run_inherited.py" --work "$REPLAY" --native-prefix "$REPLAY/native-debug" --fixture "$FIXTURE/private_fixture" --zig "$ZIG_016" --global-cache "$REPLAY/global-cache" --output "$REPLAY/inherited-debug-replay"
```

For the separately labeled ReleaseSafe/calloc-aware campaign:

```sh
"$ZIG_016" build native -Doptimize=ReleaseSafe -j4 --prefix "$REPLAY/native-safe" --cache-dir "$REPLAY/cache" --global-cache-dir "$REPLAY/global-cache" --summary all
python3 "$REPLAY/proof/inherited_wire/run_inherited.py" --work "$REPLAY" --native-prefix "$REPLAY/native-safe" --fixture "$FIXTURE/private_fixture" --zig "$ZIG_016" --global-cache "$REPLAY/global-cache" --output "$REPLAY/inherited-safe-replay" --calloc-aware-faults
```

The auxiliary plan is copied and verified by restore; no undocumented manual
copy is needed. The original plan, mode-specific verifier and observer hashes
remain recorded. Exact SDK/live and six-interval lifecycle commands and private
input variable names are retained in `runtime_evidence/`, `lifecycle_evidence/`,
`run_sdk_check.py` and `run_lifecycle.py`. With the unrelated CA and Unicode roles
created above, replay the complete experimental SDK unit suite with:

```sh
python3 "$REPLAY/run_sdk_check.py" --mode units --expected-tests 1214 --fixture "$FIXTURE" --sdk "$REPLAY/sdk" --zig "$ZIG_016" --cache "$REPLAY/sdk-replay-cache" --global-cache "$REPLAY/global-cache" --output "$REPLAY/sdk-unit-replay"
```

Use the preceding checkpoint's 501-file SDK/native parent when rebuilding the
parent lifecycle observation. Preserve worker-wide intervals and the unchanged
counter when comparing the two sides.

The archived producer scan/cleanup helper retains its original producer-path
guard and is historical audit evidence. After replay consumers finish, remove
only the new fixture after verifying the exact label created by setup:

```sh
python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys
private = Path(sys.argv[1]).resolve() / 'private_fixture'
container = (private / 'container.id').read_text().strip()
label = subprocess.check_output(['docker', 'inspect', '--format',
    '{{ index .Config.Labels "uwz.sql-experiment" }}', container], text=True).strip()
if label != 'handshake-ownership-20261118':
    raise SystemExit('fixture label differs; cleanup refused')
subprocess.run(['docker', 'rm', '--force', container], check=True, capture_output=True)
shutil.rmtree(private)
PY
```

The final archive is created only after Root accepts delivery review. Restore
and negative-control results, final source validation, payload hashes/modes,
regular archive members and the three-file result shape are checked separately.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `4a46de0f4b94b82d2fc4c852596bc73ebf03294a1c7485875d0b8901e867e86a`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
