# Pure client TLS storage readiness candidate

The isolated BoringSSL candidate adds
`SSL_get_client_storage_readiness(const SSL *)`: UNSUPPORTED=0, PENDING=1,
READY=2. READY establishes eligibility for the existing six reservation/policy
calls, apart from allocation failure. It enables nothing, verifies no certificate
and does not inspect external BIO or socket queues. Callers still verify the
peer/name, drain their transport and apply all six calls serially.

This resolves a real preparation ambiguity: an authenticated partial KeyUpdate
can leave `SSL_pending=0`, `SSL_has_pending=0`, empty external queues and
`SSL_read` returning WANT_READ, while a reservation is still ineligible.
The getter reports PENDING until valid completion. SQL consumer adoption,
production pins and the complete PostgreSQL allocation requirement remain open.

The five-file delta is
`6772a629cc9e6e09c3e06dca857576bb03a1553185d54a0d52ce6f4e2a333b3b`.
It preserves the six opt-in bodies, initializing crypto helpers, private layouts,
generated files, source lists and default policy. Exact AES method-identity
checks and digest-size metadata avoid lazy method initialization. Native version
metadata also avoids `SSL_version`'s historical pre-handshake TLS 1.2 fallback.
The two defects found during source review and their failing controls are retained.

| Proof | Observed result |
| --- | --- |
| Native conformance | Five programs, 1,091 JSON evidence rows: 935 conformance, 63 guards, 78 method/digest comparisons, 14 fault rows and one fresh-client check. The 64 partial subsets use AES-128-GCM; separate complete-bundle rows cover all three negotiated suites. These are evidence rows, not a getter-call total. |
| Authenticated controls | Three AES-128-GCM rows, 556 client IO calls and 25 getter intervals. Partial controls, an unprepared prefix behind server Finished and BIO17 write retries preserve exact bidirectional payloads and response ordering. Every getter counts zero allocator operations. |
| Getter purity | Twelve final runs across three suites, 360 getter observations: zero heap operations and zero observed once entries. Seventy-two serial cold-thread checks leave the first subsequent ERR use at two mallocs/984 bytes, followed by zero on its second use. Error queues, marks, popped pointers and calibrated observers remain unchanged. |
| Real runtime supplement | A genuinely verified TLS 1.2 pair returns UNSUPPORTED; a public write-header callback observes an actually borrowed KeyUpdate candidate and returns PENDING. Both getter intervals count zero heap operations and preserve native/ERR state. Authenticated payloads succeed afterward. |
| SDK compatibility | The complete candidate compiles through the existing Zig builder and normal C translation: all 407 native inputs, 38 SSL translation units and one header root. The ordinary suite passes 1,158/1,182 tests, with 24 live PostgreSQL tests skipped without fixture credentials. |

The interim purity control has the same zero heap and functional results, but
its READY getter enters `pthread_once` 7/10/7 times by suite. Its strict runs
fail after the functional checks; the corrected strict runs pass. The derivative
observer forwards to the verified real glibc alias and is separate from the
unchanged allocator-only program. The original all-C interposer and 63-byte
self-test are preserved; no allocator filtering or prewarming exception is used.

These are getter and control-protocol proofs, not a PostgreSQL request benchmark.
The unprepared control interval still costs 12 mallocs/12 frees/1561 bytes.
First enablement costs 11 mallocs/291926 bytes per session in this fixture.
SSL destruction, overlapping reconnects and auxiliary cancellation handshakes
remain part of the open request-path lifecycle work.

## Source and delivery

Local append-only proposal `f6176c03304e835d315cf4d9cbd86fc27e979f95` has parent
`33406dd2383eff3e84059a763933b010cc5a663d` and tree
`e46cd3464cb187f6ea7086d75e9140b0e9874262`. Together they change seventeen
paths from official `d3bf4795ad5b79d646cddf2fec687da5b9b502db`.
The 20,831-byte Git bundle requires that exact external complete base history;
base history is not embedded. Root independently restored the chain and verified
all 8,709 contents and official Git modes. Separate restorations from both
recorded package inputs verify all 8,709 raw candidate entries, including modes.
Wrong inputs and existing/protected output paths are refused before mutation.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
top-level `files.sha256`. Native, wire, purity, runtime-control and source-proposal
subdirectories retain their own current manifests. Root proofs and independent
reviews are under `root_checks/`. Delivered Debug executables omit DWARF;
archived ELF comparisons preserve mapped code/data, entry points, program
headers, regular symbol tables and executable modes. Original measured identities,
raw results and historical records remain unchanged.

The source bundle restores from an existing local complete-history repository
with HEAD exactly at official d3bf. Choose an absent output outside the artifact:

```sh
python3 source_proposal/restore_source_proposal.py \
  source_proposal/boringssl_sql_client_tls_readiness.bundle \
  /absolute/path/to/exact-official-base-repository \
  /absolute/absent/source-output
python3 source_proposal/verify_source_proposal.py /absolute/absent/source-output
```

To replay the delivered programs on the recorded compatible Linux/glibc/CPU
environment, restore the pinned PKI tool from the earlier immutable SDK artifact:

```sh
python3 restore_pki_tool.py /absolute/path/to/uWebZockets
python3 native/replay_prebuilt.py /absolute/absent/native-output
python3 wire/replay_prebuilt.py --pki-tool tools/wt-tools --output /absolute/absent/wire-output
python3 purity/replay_prebuilt.py --pki-tool tools/wt-tools --output /absolute/absent/purity-output
python3 runtime_controls/replay_prebuilt.py /absolute/absent/runtime-output
```

Root repeated all four commands from the staged delivery with fresh PKI and
cleanup. Existing outputs, artifact descendants and symlink aliases are refused.
The fixture tool itself, native archives, compiler caches, full source trees and
private PKI are omitted. Python, Git, OpenSSL and fixture tools are evidence
requirements; no new production build tool is introduced.

The measured target is Debug Linux x86_64/glibc with static native libraries.
Shared, prefixed and FIPS configurations are not validated here. No maintained
remote destination, production pin adoption, SQL integration, PostgreSQL
allocation exception or v2.3.0 release completion is implied. Dedicated
smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.
