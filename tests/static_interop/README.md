# Public static-route interop consumer

This reviewed consumer supplies additional M1 correctness evidence. Run it on
an exact saved revision after sidecar source is frozen; retain actual linking
and live results in the [2.2.0 release record](../../docs/releases/2.2.0.md).
The canonical protocol and repository gates still apply.
It makes no throughput or official HttpArena activation claim.

The consumer imports the release module through the same local path dependency
as `tests/package_consumer`. It uses public `App(8)` startup, `static`, listener,
signal, run, shutdown, and deinit APIs. Each process selects plaintext, TLS, or
HTTP/3. Its App stays at a stable address after handlers and listeners attach.
`/files` explicitly opts into `Options.precompressed`; `/identity` uses its
default false value. There is no compatibility reflection or custom adapter.

## Exact-source execution

The root integrator owns integration, revision selection, and execution.
After committing the reviewed harness and sidecars, make a saved local clone
without changing the original checkout:

```sh
git clone --no-hardlinks --no-checkout /workspaces/uWebZockets /tmp/uwz-static-saved
git -C /tmp/uwz-static-saved checkout --detach FULL_40_HEX_REV
bash /tmp/uwz-static-saved/tests/static_interop/run.sh \
  FULL_40_HEX_REV /tmp/uwz-static-artifacts-UNIQUE
```

The runner refuses a wrong revision, dirty source, an existing artifact
directory, or artifacts beneath the source. It builds only this consumer:

```sh
nix develop --no-write-lock-file /tmp/uwz-static-saved --command bash -c '
  cd /tmp/uwz-static-saved/tests/static_interop
  zig build -j2 -Doptimize=ReleaseSafe --summary all
'
```

It then enters the saved source's existing
`scripts/http3_compliance` Nix shell. `expectations.json` must match actual
curl 8.21.0, ngtcp2 1.22.1, nghttp3 1.15.0, and aioquic 1.3.0; HTTP/2, HTTP/3,
and Brotli decoder features are mandatory. The checked-in client flake pins
Nixpkgs `d57af924f160a5084293c71c2043f058bd1cdb60`. Ordinary system curl is not
a substitute. `run.sh` retains each exact command and exit, source revision,
Git tree, submodule identities, manifest/flake/harness hashes, actual client
version output, and the built server hash. The build mode is ReleaseSafe.

Translate-C/native compilation and loopback execution require the demonstrated
sandbox escalation in this workspace. Do not interpret an empty log or a
timeout as authority to restart a job. This runner never restarts a server.

## Checks and retained evidence

Each plaintext H1, TLS H1, TLS H2, and live H3 curl transfer downloads exactly
104857600 bytes from a sparse source. Nonzero sentinels cover the first/last
byte and 8/32/64 KiB boundaries. Every body byte is compared against the source
with reads capped at 8192 bytes; counts and SHA-256 are retained. Exact
Content-Length and negotiated HTTP version are required. A second URL in the
same curl process must return `/health` using the original connection ID and
zero new connections.

The live aioquic H3 connection downloads the same file while a healthy sibling
stream runs, then serves another health stream. It compares data incrementally,
requires exact Content-Length and END_STREAM at EOF, records stream IDs, and
rejects reset, termination, or timeout. Legal data events are split into 8192-byte
comparison slices; a larger event is accepted and its actual size recorded. Receive
configuration starts at 64 KiB per stream and 256 KiB per connection; the
library may adjust transport credit. Free functions drive public `QuicConnection`
and `H3Connection` operations in one explicit UDP/timer loop. Named plain
dictionary records hold all state; no custom classes, subclass adapters, private
SDK access, or monkeypatching is used. A reusable 65536-byte buffer bounds UDP
receive copies. There is no aioquic qlog event list. The
`aioquic.application.jsonl` file is a streamed application-event trace and is
labeled accordingly.

Public API use was checked against installed aioquic 1.3.0 source:
`quic/connection.py` defines `connect`, `datagrams_to_send`, `get_timer`,
`handle_timer`, `receive_datagram`, `next_event`, `get_next_available_stream_id`,
and `close`; `h3/connection.py` defines `H3Connection`, `send_headers`, and
`handle_event`. The shipped asyncio driver uses the same receive/event/send/timer
ordering. Runtime proof records hashes of both actual module files.

Curl's pinned 8.21.0 manual documents QLOGDIR for its ngtcp2 backend. Each live
curl H3 request enables it, and the gate requires and hashes nonempty transport
qlog files. Curl's internal logging allocations are outside the harness's
allocator scope; no curl memory bound is claimed. The canonical pinned
malformed/sibling HTTP/3 gate remains separately required on the same source.

Every curl protocol also checks actual gzip and Brotli full bodies, HEAD, 304,
encoded byte ranges, matching/mismatching If-Range, and 416 with selected
representation length. It checks source MIME, distinct identity/gzip/br ETags,
Vary, identity 304, explicit default identity behavior, complete refusal, and
duplicate Accept-Encoding fields separated by 18 filler fields. The second
gzip refusal must win and select Brotli. `--compressed` transfers must decode
to exact original bytes. A 416 has an empty error representation and need not
carry the selected file's Content-Encoding; its Content-Range still names the
selected file length.

Artifacts retain raw headers, curl verbose traces, qlogs, command output,
individual exits/timeouts, generated proof JSON, and gzip archives of the full
large client bodies. Compressed body archives are produced only after byte
verification; both original-byte and archive-file SHA-256 values are recorded. Generated
results are written by the runner and are never manually edited.

The runner prechecks both TCP and UDP bind availability, then proves listener
ownership using the owned PID's socket descriptors and `/proc/net` inode rows.
Only owned PIDs receive SIGTERM. Each must return zero without forced killing,
and log the marker after public shutdown and deinit have completed. These APIs
check pool/drain invariants. A forced kill or missing marker fails the gate.
`server.status` uses Python's raw return convention (negative signal number).

`build.status`, `clients.status`, `client_gate.status`, per-command statuses,
per-mode `server.status`/`server.forced`, and final `gate.status` keep build,
request, server, and aggregate outcomes distinct. A command start failure is
recorded as `None` with a traceback; no exit code is invented. Private keys and
fixture sources live only in an owned temporary runtime directory, removed on
normal/error cleanup. Public test certificates and their identity are retained.

The harness has bounded application reads/copies, bounded response-header
storage, incremental digests, and streaming body/qlog output. It does not
instrument App/TLS/QUIC startup heaps or internal curl/aioquic allocations, so it
does not claim zero global allocations. The library's allocation assertions
remain the responsibility of the centralized unit/sanitizer gates.

## Fixture reproduction

Fixture generation alone requires Python's standard library and touches only
the new destination:

```sh
python3 tests/static_interop/probe.py fixtures \
  --artifacts /tmp/uwz-static-fixtures-UNIQUE > /tmp/uwz-static-fixtures.json
```

`truncate` creates the large sparse file; seven one-byte writes establish the
sentinels. The manifest records logical and allocated file bytes and every file
digest. Small gzip uses `gzip.compress(..., mtime=0)`. The 1376-byte small source
and valid 49-byte Brotli fixture are fixed in `probe.py`; each live decoded curl
check independently verifies them. To regenerate the checked-in Brotli bytes
for development, use the following recipe (`BrotliEncoderVersion` returned
16781312 for the current bytes). This is not a library build requirement:

```python
import ctypes
import ctypes.util
encoder = ctypes.CDLL(ctypes.util.find_library("brotlienc"))
encoder.BrotliEncoderCompress.argtypes = [
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_size_t,
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
]
encoder.BrotliEncoderCompress.restype = ctypes.c_int
source = b"uWebZockets static representation fixture.\n" * 32
output = ctypes.create_string_buffer(4096)
length = ctypes.c_size_t(len(output))
assert encoder.BrotliEncoderCompress(
    5, 22, 0, len(source), source, ctypes.byref(length), output
) == 1
print(output.raw[:length.value].hex())
```
