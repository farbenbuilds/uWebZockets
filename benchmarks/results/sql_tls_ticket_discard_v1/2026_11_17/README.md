# Validated client ticket-discard candidate

This isolated native proposal adds `SSL_discard_client_session_tickets` for
an idle, completed ordinary TLS 1.3 client. It validates received tickets and
discards their resumption material before session construction. PostgreSQL's
client does not currently save or reuse TLS sessions. The opt-in removes unused
ticket work from its future bounded profile; production pins and PostgreSQL's
complete allocation gate remain unchanged.

The baseline is the
[bounded KeyUpdate output candidate](../../sql_tls_ku_output_v1/2026_11_17/README.md)
on BoringSSL `d3bf4795ad5b79d646cddf2fec687da5b9b502db`. Four of 8709 native
source entries change, with twelve cumulative changed files from the original
package. The complete matching crypto/SSL Debug rebuild passes all six steps,
including all 38 SSL translation units.

## Policy and lifetime

The caller verifies the certificate and hostname before enabling the policy.
Initial enable requires no CLIENT cache bit and no new-session callback in the
effective session context. Both OFF (0) and SQL's default SERVER (2) qualify;
cache-disabled mode alone does not change ordinary ticket behavior. Servers,
DTLS/QUIC, initialization, shutdown/error and pending I/O, messages, alerts,
updates, flights or borrowed AEAD contexts are excluded.

Once active, the per-SSL policy dominates later shared-context cache/callback
changes. Repeated valid idle enables remain successful. Incoming tickets retain
wire validation and message observation, while ticket-session callbacks, time
rebasing, PSK derivation, ticket copying and synthetic session IDs are skipped.
Established-session getters and previously exported sessions retain their
ownership; an already resumed handshake is not undone. The explicit external
record-layer ticket-session construction API remains generic and may allocate.
Other TLS processing still needs its existing bounds and reservations.

The flag follows SSL3_STATE lifetime. Successful `SSL_clear` resets it. A
preflight failure retaining the old state preserves it; the existing destructive
replacement-state allocation failure destroys that state and its flag. No atomic
clear rollback is promised. Mutating SSL I/O must be serialized and non-reentrant.

| Measured quantity | Value |
| --- | ---: |
| Enable-time heap operations | 0 |
| SSL3_STATE size before / after | 640 / 640 bytes |

[RFC 8446 section 4.6.1](https://www.rfc-editor.org/rfc/rfc8446.html#section-4.6.1)
permits deleting tickets earlier under local policy. Ordinary resumption users
retain the generic path and callback ownership, including retained sessions.

## Shared validation and generic compatibility

Pure borrowed helpers parse the lifetime/age/nonce/nonempty-ticket prefix, the
extensions vector and body trailer, then extension semantics. No view escapes
processing and no validation helper allocates, logs, reads time or reports an
error through hidden state. Named errors map to the existing reason/alert order
at the effects boundary.

Generic construction retains its original order: session duplicate, time
rebase, prefix, ticket copy, vector framing, timeout/PSK, extension semantics and
finalization. The discard path runs the shared validation stages consecutively
without constructing a session. Complete extension framing and recognized
duplicates are checked before early-data contents, then flags. Unknown
extensions, unknown duplicates and unknown flag bits retain pinned behavior.
The four earlier reservation functions, `SSL_clear` and the explicit external
ticket API bodies remain byte-identical.

The direct differential has 37 syntax/metadata/event vectors: eleven valid and
26 malformed, including four combined-invalid precedence cases. Baseline and
candidate generic results agree exactly on return, metadata, allocator counts,
error queue and alert/message/time/new-session events, including the error queue
observed inside callbacks. Discard preserves validation, reason/alert and
message observations, while all eleven valid cases count zero malloc, calloc,
realloc, free, requested bytes and ticket-time/new-session callbacks. These are
helper-only synthetic inputs, not server-resumability or encrypted-wire proofs.

A preliminary fixture incorrectly expected the established session's
resumable-across-names flag to copy when the ticket omitted it. The pinned
duplicator copies maximum early-data metadata but initializes that names flag
false. Only the incorrect expectation was corrected; encoded-flag and remaining
metadata assertions stay checked. Preliminary source/logs and classification
are retained separately. No native change resulted from that fixture correction.

Six generic callback rows cover returns zero and one on all three suites, with
exact baseline/candidate parity. Callback-owned ticket objects are freed once
and can outlive their SSL and context. Twelve additional candidate policy rows
check cache-mode/callback eligibility, effective session-context selection,
later context changes, sibling isolation, idempotence, established getters and
the still-generic explicit ticket-construction API. Synthetic ticket contents in
these helper checks are not claimed server-resumable.

Three generic allocation-failure rows retain exact baseline error/alert/time
ordering and raw allocation/free accounting. A preliminary observer incorrectly
required every raw C allocation to be zeroed before free. The failing free
was a 16-byte saved error object released by `ERR_SAVE_STATE_free`, whose raw
malloc/free path has no OPENSSL erasure contract. Diagnostic source, logs and
code-site evidence are retained. Raw nonzero frees remain reported; erasure
assertions target positively identified default-OPENSSL owners. This changes no
native code or ordinary zero-allocation assertion.

Twenty eligibility/lifecycle cases and two clear-boundary cases pass. They cover
real pending data and recovery, shutdown/saved errors, role/protocol exclusions,
active-policy idempotence and clear plus a fresh verified nonresumed handshake.
Public config shedding demonstrates a failed preflight clear preserving the
live state, flag and traffic; replacement-state OOM demonstrates the existing
destructive path. The watched 640-byte S3 allocation, 648 raw bytes including
its prefix, is erased and actually freed once in each clear case. This is scoped
default-allocator ownership evidence rather than whole-process leak accounting.

All 51 inherited input sources remain byte-identical. Checks against the final
native libraries pass:
KeyUpdate output helpers, three sealer failures and 23 lifecycle cases;
24 AEAD direct epochs, twelve populated-initializer failures, 48 zero-heap
three-context transitions and 22 lifecycle cases; 64 handshake fragment loops
and 21 lifecycle cases; sixteen record lifecycle cases and both buffer/pair
helpers; and 1440 HKDF differential cases, including 700 zero-allocation
successes and 740 matching rejections.

## Initial encrypted ticket allocation gate

The genuine pre-edit RED uses three fresh CA/hostname-verified pairs, six real
initial server tickets and 75 complete metered client calls. Both peers assert
actual suite `0x1301` AES-128-GCM. Client caching is OFF with a null new-session
callback, and the prior record/handshake/AEAD/output reservations are enabled.
Exact 4096-byte application payloads travel both ways for each pair.

Each baseline or new-unopted ticket-bearing read counts twelve mallocs/twelve
frees/1600 requested bytes; writes count zero. Observe mode completes, and the
unchanged strict-ticket-zero assertion exits one after valid traffic with
identical operation/summary bytes. The opted-in candidate passes the same
assertion: all read and write calls count zero malloc, calloc, realloc, free and
requested bytes. The original all-C interposer and 63-byte self-test are
unchanged. Startup, peer work, validation and logging remain outside the client
call plus immediate error-mapping interval. These are TLS/BIO measurements,
not PostgreSQL query counts.

## Three-suite wire and real-session proof

The expanded protocol matrix has 27 rows and 1320 complete client operations
per variant across actual `0x1301` AES-128-GCM, `0x1302` AES-256-GCM and
`0x1303` ChaCha20-Poly1305. Both verified peers publicly select singleton suites
and assert the negotiated IDs. Baseline and new-unopted operation/counter bytes
agree exactly. Payload, call/error, message and alert observations remain
equivalent after discard; its nine healthy rows count zero allocator operations
in every measured phase. The eighteen fatal rows preserve full encoded reason
queues and ordered peer alert receipt, without a zero-allocation error claim.

Native server handshake code creates the real initial tickets. Late tickets
use synthetic opaque contents sealed by the native server after a bidirectional
application exchange, with header splits at 1/2/3 bytes, repetition, coalescing
and unknown-extension/flag cases. Client parser and cipher state are not staged.
Complete known synthetic message bytes are checked in memory. Those opaque
contents are syntax/protocol inputs and are not claimed server-resumable.

A separate three-row real-session chain uses 228 client operations per variant.
It exports two actual server-issued callback-owned sessions before opt-in, then
genuinely resumes an earlier export on both verified peers after enabling the
policy. It also enables discard after an already resumed handshake and processes
its new real tickets without allocation. Earlier exports retain ownership and
usability. Export intentionally precedes opt-in and allocates; saved sessions are
released once after both connections finish. No real ticket, PSK or session bytes or
hashes are persisted.

The twelve-row public control witness repeats four scenarios across three
fresh pairs, 255 complete client calls per build. With all prior reservations
and ticket discard enabled, every candidate control read/write phase counts
zero heap operations. KeyUpdate response ordering and exact payloads remain
checked.

| Client read phase | Prior malloc/free | Discard malloc/free | Prior bytes | Discard bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload | 0/0 | 0/0 | 0 | 0 |
| Two initial tickets, caching off | 12/12 | 0/0 | 1600 | 0 |
| Peer KeyUpdate, no response requested | 0/0 | 0/0 | 0 | 0 |
| Peer KeyUpdate, response requested | 0/0 | 0/0 | 0 | 0 |

Following writes remain zero. The initial-ticket control uses `0x1301`; the
three-suite protocol measures 1600 prior bytes for `0x1301`/`0x1303` and 1632
for `0x1302`, all becoming zero after discard. These are bounded default-BIO
proofs, not arbitrary custom-BIO recovery or complete PostgreSQL integration.

## Retained evidence and delivery replay

the original archive contained native source/build/provenance, helper and
wire evidence, independent reviews and root checks. Twelve cumulative candidate
snapshots reconstruct all 8709 source entries from the exact original package
or explicit prior-KeyUpdate-output input. Root validated both restoration modes
and existing-destination/wrong-mode refusals from the copied layout. See
`native/HANDOFF.md` for source-list build instructions.

Measured programs use Zig Debug. Existing GNU objcopy `--strip-debug` removes
debug information from 32 delivery copies, reducing 585633688 to 163616600
bytes. Native/test source, assertions, raw measurements and build inputs remain
unchanged. `delivery_transform/manifest.json` retains every original/current
identity and verifies allocated sections, entrypoints/ABI, program headers and
normalized load bytes; regular symbol tables and permissions remain. Complete
file hashes and section-table coordinates change. The wire identity's current
`delivery_stripping` flag is explicitly true; the archived original remains
false. All other producer metadata stays intact.

Current `prebuilt_identity.json` files and explicit delivery byte maps identify
the delivered executables. Producer handoffs/build records and archived
original maps describe measured Debug files. Helper uses `files.sha256`; wire
uses `payload_manifest.json` with its `sha256` map. The combined top manifest
covers both formats. No compiler, native archives, objcopy or network access is
needed for prebuilt replay.

Choose fresh extraction and absent external replay directories:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

The restore tool reads only the checksum-pinned PKI executable from the existing
independent-client artifact. Both wrappers verify current executable identities,
compare exact outcomes and remove owned private PKI in finally blocks. Output
must be outside the entire extracted bundle; standalone use retains its own-tree
guard. Nine helper and four wire guard checks use the valid PKI helper and
verify rejection before output creation. Delivery stripping changes no wrapper.
Both complete root replays pass after transformation: 107 helper commands and
24 wire commands with expected statuses. Raw results and post-replay checksums
are retained under `root_checks/`.

Root formatting leaves 314 source/build inputs unchanged. The SQL/SQLite unit
suite passes 1158 tests with 24 existing live-PostgreSQL tests skipped without
fixture settings.
Conventions, release metadata and documentation-link checks also pass.

Fatal-error/reconnect allocation, maintained native publication, production
adoption and PostgreSQL's complete request-path gate remain open. No PostgreSQL
allocation exception is approved. Dedicated smoke, security, sanitizer, fuzz and
scan campaigns remain user-deferred.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `cb97384fc09580c3df5caed748658b2d4df03611dbae98ac96a567d1ed6c7b89`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
