# SQL TLS reservation lifecycle and control traffic

Root source: `b9d42bd99150bc9b260e721ed48913f1cdca6b96`.
Native baseline: BoringSSL `d3bf4795ad5b79d646cddf2fec687da5b9b502db` plus the
unchanged four-file record-reservation prototype. Independent comparison finds
all 8709 candidate files identical. The complete native rebuild compiles all
38 SSL translation units together; no production source, pin or policy changes.

All sixteen final lifecycle cases pass: first/second reservation malloc failure,
idempotence, three actual pending TLS/BIO states and separate traffic controls,
null/unfinished/completed TLS 1.2 rejection, configured DTLS/QUIC rejection, and
two SSL_clear controls. The successful control completes another verified,
nonresumed TLS 1.3 handshake before reserving again. Both inherited capacity,
alignment, compaction and maximum-record proofs also pass.

Failure two may retain the successful receive reservation. Each rejected SSL
object is freed; the observer verifies complete cleansing immediately before
actual libc free and exactly-once ownership across reservation epochs. This
tracks reservation pointers, not every process allocation or leak. Pending
states arise from real TLS operations and are observed read-only. Their
rejection preserves observed buffers/cursors without reserving record storage;
error-queue changes remain allowed. Configured DTLS/QUIC rejection is not
completed protocol interoperability, and TLS 1.2 is an isolated negative case.

The separate public-API control witness creates three fresh verified TLS 1.3
pairs per scenario. Its unchanged original allocator interposer/self-test
meters only client SSL reads/writes and immediate error mapping. Peer work,
validation, logging and teardown stay outside the interval. Fixed callbacks
observe actual control delivery; exact 4096-byte payloads validate acceptance.

| Observed client interval | malloc | calloc/realloc | non-null free | Requested bytes |
| --- | ---: | ---: | ---: | ---: |
| Ticket-free payload read | 0 | 0 | 0 | 0 |
| Two initially queued tickets, cache off, read | 16 | 0 | 16 | 2186 |
| Peer KeyUpdate NOT_REQUESTED, read | 6 | 0 | 6 | 726 |
| Peer KeyUpdate REQUESTED, read | 15 | 0 | 13 | 1604 |
| Requested-update response, next client write | 0 | 0 | 2 | 0 |

All twelve rows and 255 operations reconcile; observed counts match across
three rounds. Tickets are initially queued by the server handshake and flushed
after reservation, not arbitrarily minted later. These are synthetic TLS/BIO
client-call measurements, not warmed PostgreSQL per-query counts. Every row
reserves 131070 record-buffer bytes before measurement and verifies explicit
CA/hostname trust, TLS 1.3, no ALPN and AES-128-GCM. Requested updates reach the
peer with a valid NOT_REQUESTED response before application data.

The normative requirement is no request-path allocation after startup. The
older cached-query interval is a limited audit method, not a universal TLS
lifetime rule or blanket exception. Valid control processing can still allocate
inside client I/O; record reservation alone cannot establish the strict gate.
Source maps identify separate handshake/session/key/flight/error storage and
the limits of cache-off/no-ticket options. Error/reconnect attribution, native
maintenance and production adoption remain unresolved. SQL-ALLOC-001 covers
SQLite only; no PostgreSQL allocation exception is approved.

Verify `manifest.sha256`, extract `raw_evidence_archive.tgz`, then verify its
top-level `files.sha256`. The archive retains final helpers, sources, commands,
raw results, source maps, independent crypto review and fresh Root verification
(1128/1128 tests; 314 unchanged formatted source/build inputs). Compiler caches,
native library archives and generated private PKI are omitted. Prebuilt helpers
require the recorded compatible Linux/glibc/CPU environment.

From the extracted directory, restore the pinned PKI helper from the earlier
immutable client artifact and replay into absent output directories:

```sh
python3 restore_pki_tool.py /path/to/uWebZockets
python3 lifecycle/replay.py --pki-tool tools/wt-tools --output /tmp/uwz-tls-new-lifecycle
python3 control/run_prebuilt.py tools/wt-tools /tmp/uwz-tls-new-controls
```

Both documented commands pass from the delivery layout, preserve retained
results and remove their generated PKI. Existing output directories are refused
before writes. Source rebuilding and the exact native/probe provenance are in
`lifecycle/HANDOFF.md` and `control/README.md`; source-built archive hashes may
vary with debug paths and are recorded rather than assumed equal. Git/Python
and fixture tools are external verification tools, not library build requirements.

Dedicated smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred.
The production allocation gate and other v2.3.0 requirements remain open.
