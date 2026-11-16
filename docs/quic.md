# QUIC and HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises `h2` and
`http/1.1`, while QUIC advertises only `h3`. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`. The `App` value must remain at a
stable address after `listen_udp`.

```zig
var server = try uz.App(128).init_http3(init.io, "certs/fullchain.pem", "certs/privkey.pem");
defer server.deinit();

_ = try server.get("/", hello);
try server.listen("0.0.0.0", 3443);      // TCP/TLS
try server.listen_udp("0.0.0.0", 8443);  // QUIC
try server.run();
```

For local development, `init_http3_ephemeral` generates an in-memory
certificate; see [tls.md](tls.md).

After `Server.builder(...).build(...)`, call `enable_http3(cert_path,
key_path)` or `enable_http3_ephemeral()` on the resulting application before
listening. This retains the builder's connection, stream and datagram
capacities while installing isolated TCP and QUIC TLS contexts.

## Request path

The adapter decodes HTTP/3 pseudo-headers directly into the existing `Request`
shape and writes structured QPACK response headers without converting through
HTTP/1.1 text. QUIC connections, streams, header sets, packet buffers, and
bodies come from startup-allocated contiguous pools.

- The live listener explicitly rejects TLS 0-RTT so replayable application
  requests never reach a handler. Pure early-data policy helpers remain
  available for a future backend that exposes per-request early-data state.
- Congestion control is pinned to BBRv1 with per-connection pacing.
- Linux transmit batching coalesces equal-sized packets for one destination into
  one `sendmsg` with `UDP_SEGMENT` (GSO). Mixed sizes and other platforms use the
  per-packet path. Receive-side `UDP_GRO` is disabled because the event loop does
  not expose ancillary segment boundaries; a coalesced buffer would be misread as
  one QUIC datagram.
- The engine enforces decoded header limits, request bodies, packet buffers,
  connections, and active streams through `ServerConfig`.
- Request validation is strict: pseudo-fields must precede regular fields and
  stay unique, `:protocol` is accepted only on CONNECT requests that carry
  `:authority`, and connection-specific fields are rejected as malformed with
  a stream-scoped `H3_MESSAGE_ERROR`.
- Known-length file responses use `Response.stream_file`. The stream copies
  accepted bytes into its existing bounded body storage before a partial write,
  owns one descriptor per active stream, and closes it exactly once on
  completion, reset, or reuse.
- Route-level request-body streaming after completed headers. `post_stream`,
  `put_stream`, and `patch_stream` deliver stream bytes to the sink without
  whole-body buffering; a pause stops reads and retains the bounded suffix.
  An initial `expect: 100-continue` receives an interim 100 response after
  admission.

## Observability

HTTP/3 emits one `http_request` development-log record per completed
request/response cycle through the owning thread's sink. The QUIC path does not
advance the counter registry in this release.

## RFC 10008 `QUERY`

Both routing APIs support the `QUERY` method. It rejects a missing or
syntactically invalid `Content-Type`; resource-specific media-type and content
consistency remain the handler's policy.

`TRACE` is also first-class and opt-in: `:method: TRACE` reaches a registered
handler, but the library never synthesizes an echo route. `method_is_replay_safe`
classifies TRACE as safe for early-data forwarding policy.

## Extended CONNECT, WebTransport, and datagrams

`uz.http3_extensions` supplies RFC 9220 extended CONNECT validation, push
bookkeeping, and replay-aware early-data policy. `uz.webtransport` supplies
bounded draft-16 settings, CONNECT/origin checks, sessions, stream and datagram
association, capsules, flow control, and error mapping.

The **published dependency pin does not activate WebTransport**. Its
maintained fork backend exposes raw datagrams but not the complete
extended CONNECT, outgoing unidirectional stream, or reset-at interfaces they
require, and the build does not yet enable the WebTransport server compile
option. Completed CONNECT dispatch returns `501 Not Implemented`; headers alone
do not admit a long-lived session and ordinary body completion/bounds apply.
WebTransport models draft-16 only, without deployed interoperability. Live
activation was re-declared on 2026-10-26 with
[dated restoration criteria](roadmap.md#deliberate-boundaries).

[adr/0001-http3-datagram-and-webtransport.md](adr/0001-http3-datagram-and-webtransport.md)
records the exact backend blockers and the accepted implementation plan. The
maintained `farbenbuilds/lsquic` fork can carry the missing server interfaces,
but the live path remains capability-gated until a post-2.2.0 implementation and
compliance gate land.

The private runtime now binds App admission and datagram callbacks when built
against the complete local native proposal. It requires an exact WebTransport
endpoint and an explicitly registered synchronous CONNECT handler. An empty,
completed 2xx response from that handler approves both authentication and the
supplied Origin; an `any` fallback or generic CORS continuation cannot admit
the session. The conservative profile requires exactly one nonempty Origin.
The handler must validate its value and all application credentials.

Early candidate datagrams use separate startup-owned storage; they never reach
App handlers or rings before admission. The global budget is four entries per
configured engine connection, with at most four queued entries for any one
connection. Payloads respect the configured per-datagram bound and the native
2048-byte physical ceiling. Entries expire after one second of monotonic awake
time. Replay preserves FIFO for each session and assigns the connection's
local dispatch ordinal at delivery attempt, including ring-full drops; this
ordinal is not a wire sequence number.

Terminal stream identities share a separate global budget of four entries per
configured engine connection. Retiring an HTTP, refused, cancelled or closed
identity purges its queued entries. If the terminal
budget fills, the affected connection drops further early datagrams for
unconfirmed IDs until it closes, including IDs with data already queued.
Previously queued future-session entries remain eligible for later admission,
and established traffic continues. Connection teardown clears both stores
before generation reuse. Cooldown disables new unknown buffering for those
generations before clearing pending traffic and terminal records.

This candidate retains one session per connection. Session flow is off by
default; positive startup limits require the complete native receive observer.
It retains a registered route identity after releasing request headers and
parses fragmented capsules with bounded carry. This is an implementation
checkpoint, without published fork pins or independent draft-16 client
acceptance. Multi-session activation remains open;
the later checkpoints below retain receive, transmit and outgoing-stream work.
See the
[App admission evidence](../benchmarks/results/webtransport_app_admission_v1/2026_11_16/README.md).

Each CONNECT stream owns its session route, phase and callback publication.
A startup-sized worker index maps the connection generation and full session
ID to that CONNECT's global slot and stream generation. Child-parent checks
resolve the slot directly; association and datagram routing use the index.
Closing removes the index entry and record before callbacks. This keeps
storage linear in global stream capacity. Multiple sessions still require
independent cleanup and isolation verification.

### Child receive callbacks

`App.webtransport_streams(path, callbacks)` and
`webtransport_streams_context(path, context, callbacks)` register a child
consumer. `uz.webtransport_stream` defines the named callbacks and handles.
The endpoint table has sixteen distinct paths shared with `App.datagram`;
adding the other capability to an existing path does not consume another
slot. A duplicate capability returns `RouteAlreadyRegistered`. Paths and
contexts are borrowed for the App lifetime, and registration locks with the
other routes. The default callback context is the App itself; keep it at a
stable address after registration. Stream-only applications need no datagram
builder settings.

An explicit synchronous CONNECT handler still authenticates and approves the
Origin. `session_open` runs after establishment and request-header release,
before queued children. `open` returns true to own one eventual `closed`
notification. It is admission only: handle operations return `NotReady` until
it returns. Rejection owns no close notification. A missing data callback
rejects payload rather than silently discarding it.

Data slices are borrowed until their callback returns. EOF follows actual
native read zero; reset reports the full final payload size, including gaps.
Application-mapped errors use `ErrorCode.application`; other full-width codes
use `ErrorCode.http3`. Unknown final size remains null at close. Native close
does not prove peer receipt or acknowledgment.

Receive EOF/reset leaves BIDI sending open. Call
`webtransport_stream_finish(handle)` to accept an empty FIN promise, or
`webtransport_stream_cancel(handle, application_code)` to cancel both halves.
The latter preserves its first code; conflicting repeated cancellation fails.
Operations schedule native work for transport processing without invoking
application callbacks inline.

`webtransport_stream_stop(handle, application_code)` abandons receiving while
sending remains open. Further payload, EOF and receive-reset callbacks stop;
final-size accounting and peer STOP notifications continue until native close.
After a peer FIN or RESET, success can mean local abandonment without sending
a new wire STOP. `webtransport_stream_reset(handle, application_code)` resets
only sending and immediately disables writes, finish and writable events.
Receiving can continue. RESET after finish returns `WriteClosed`.

Each half preserves its first accepted code independently. Identical repeats
succeed without requesting another wake; different repeats return
`ConflictingIntent`. A later whole cancellation fills only missing half
intents. Native credit blocking retains the request for retry. Both operations
require accepted ownership and native publication, and invoke no callbacks
inline. `ControlFailed` reports an unexpected native rejection before a new
intent was accepted.

`webtransport_stream_write(handle, bytes)` returns the prefix copied into
native ownership. Retain only the suffix for retry; the accepted prefix may
be overwritten as soon as the call returns. A nonempty zero-progress write
returns `WouldBlock`. A valid empty write returns zero without scheduling
service. Accepted payload offsets cannot exceed the QUIC 62-bit bound.

An optional `writable(context, handle)` callback reports one requested sending
opportunity. Partial/blocked writes arm it when configured. Use
`webtransport_stream_want_writable(handle, true)` to request an opportunity
explicitly, and false to disarm. Enabling without a callback returns
`NoWritableCallback`. Interest is disabled before notification; explicitly
rearm or attempt another partial write to request a later callback. Returning
from the callback does not rearm it. Without a callback, retry the suffix from
application scheduling.

Interest may be recorded during `open`, but sending and notifications wait for
both accepted ownership and the actual native typed publication. Write/finish
return `NotReady` before that boundary. Peer STOP disables sending and writable
interest while receiving can continue. Receive EOF/reset does not close TX.
Submit every intended byte before finish; finish retains the accepted native
payload and FIN, and further writes return `WriteClosed`.

Native copying is tracked independently of the write return value. A native or
flush failure after consuming a prefix still returns its positive byte count;
the stream then closes with an internal failure. Never resend that prefix.
Zero-consumption failures return `WriteFailed` or `WriteClosed` as applicable.
`WakeFailed` means deferred service could not be reserved before mutation, so
that call consumed no input. The UDP transport coalesces external service
requests through its existing timer and waits for both timer and cancellation
completion before reuse. No engine processing runs inline from a wake request.

Handles contain a stable App identity, global stream slot and never-wrapping
generation; session handles also contain connection/session generations.
They are worker-confined and cannot outlive their originating App. Wrong-App
and reused handles fail without touching another stream. Session closure
invalidates its handles before its callback; accepted children retain their
own eventual close notification. A normal parent FIN or CLOSE_SESSION reports
`session_closed`; cooldown reports `shutdown`, and connection loss reports
`connection_closed`. CLOSE_SESSION preserves its application code. Root
callback dispatch allocates no memory.
Upstream native buffering has no allocation-free claim.

These registration/types compile with the published pin; live operations
return `Unsupported` there. The complete unpublished native proposal is still
required to exercise the candidate path.

`webtransport_stream_create(session_handle, direction)` creates a local UNI or
BIDI child and returns its handle without calling application callbacks inline.
The later `open` callback receives `initiator.local` and explicitly accepts
ownership, just as for a peer child. Accepted-only operations return `NotReady`
until then. Rejection owns no close callback. A local UNI stream only sends;
it receives no data, EOF or reset callbacks, and its native receive final size
remains null. Local BIDI receive accounting starts at payload offset zero.

Creation requires an established session; draining sessions reject new children.
Root reserves its stream slot and connection lease before native construction.
`CapacityExceeded`, `GenerationExhausted`, `WakeFailed` and native creation
failures release that reservation. `WouldBlock` queues no delayed request;
retry explicitly after credit becomes available. Failed attempts before the
native stream callback do not consume a handle generation. Payload offset
bounds exclude the local association prefix.
The peer must grant both stream-count and byte credit for that prefix; a
stream-count allowance with zero BIDI byte credit still returns `WouldBlock`.

The [public receive checkpoint](../benchmarks/results/webtransport_public_receive_v1/2026_11_16/README.md)
retains 26 actual App cases in all three optimization modes, exact source
inputs and a relocatable replay. It does not establish accepting-phase
cooldown staging, outgoing streams, positive session flow control or an
independent draft-16 client.

The [peer-BIDI transmit checkpoint](../benchmarks/results/webtransport_public_tx_v1/2026_11_17/README.md)
retains actual stream/connection credit recovery, accepted-buffer copying,
one-shot callbacks and loop-only deadline wakes. C-boundary injected failures
are labeled separately from the actual native cohort.

The [local STOP/RESET checkpoint](../benchmarks/results/webtransport_public_half_v1/2026_11_17/README.md)
retains 51 actual App cases in all three optimization modes, including independent
half progress, callback reentry, immutable codes and whole-cancel composition.
Native half-control error-return faults remain unforced.

The [outgoing-stream checkpoint](../benchmarks/results/webtransport_public_outgoing_v1/2026_11_17/README.md)
retains 67 actual App cases in all three modes, including local UNI/BIDI
creation, real MAX_STREAMS recovery and the bounded local receive-window fix.

The [session-record checkpoint](../benchmarks/results/webtransport_session_records_v1/2026_11_17/README.md)
retains the 67 stream cases and a separate 33-case datagram driver in all three
modes, including publication-aware cooldown and global session-index cleanup.
Positive flow and multiple-session activation remain subsequent work.

The [native receive-observer prerequisite](../benchmarks/results/lsquic_receive_observer_v1/2026_11_17/README.md)
retains high-water/delta observation and lifecycle regressions. It remains an
unpublished proposal; positive flow enforcement remains gated. The subsequent
[publication snapshot checkpoint](../benchmarks/results/lsquic_receive_publication_v1/2026_11_17/README.md)
adds the native publication bit needed for NULL-context close reconciliation.

The pure [session flow budget](../src/quic/webtransport/session_flow.zig) validates
cumulative body/child limits and separates receipt, consumption and advertised
credit. Its fixed capsule buffer retains partially accepted bytes and coalesces
later grants with fair DATA/BIDI/UNI service. Centralized tests cover these
transitions independently of I/O. The candidate runtime uses these budgets
when both endpoints advertise positive flow intent.

Candidate native receive observers now record prefix-excluded body deltas before
typed admission, with peer-created stream counts charged once at publication.
Known-session receipt resolves its indexed CONNECT record before any retired-ID
scan; only unknown associations scan the bounded retirement store.
Early usage and reclaimed bytes/closed children persist in four startup-owned
SID slots per connection until CONNECT takes ownership. Reads and final gaps
are not charged again. Closing a child reclaims its remaining final body debt;
whole-connection teardown discards its exact generation. An append-only native
publication snapshot bit distinguishes NULL-context children at close.

When Root's stream pool is full, a BIDI classifier probe consumes no child body
and retains its session identity before rejection. Debt exhaustion retires that
SID before discarding counters; unremembered stream-debt loss blocks new unknown
session admission independently of datagram buffering exhaustion. CONNECT checks
this policy before invoking application admission.
Published dependency pins remain unchanged.
The [early-debt checkpoint](../benchmarks/results/webtransport_early_debt_v1/2026_11_17/README.md)
retains the combined 77-case stream/debt driver and separate 33-case datagram
driver in all three modes, with callback-order injection labeled separately.

### Candidate session flow limits

Set initial cumulative receive credit before starting the UDP listener:

```zig
const limits: uz.webtransport.FlowLimits = .{
    .data = 64 * 1024,
    .streams_bidi = 8,
    .streams_uni = 8,
};
var server = try uz.Server.builder(init.io)
    .with_max_clients(128)
    .with_webtransport_flow_limits(limits)
    .build(allocator);
defer server.deinit();
```

The equivalent config field is `ServerConfig.webtransport_flow_limits`.
Data is bounded by `2^62 - 1`; each child count by `2^60`, inclusive. Invalid
configurations return `InvalidWebTransportFlowLimits`. Positive limits require
the native receive observer and fail startup with `UnsupportedWebTransportFlow`
when it is absent. The published pin still does not activate live WebTransport.

Flow is negotiated only when each endpoint declares at least one nonzero
initial limit. Otherwise the session retains legacy behavior and ignores
session MAX/BLOCKED capsules. With flow enabled, early receive usage must fit
the initial limits before the application CONNECT handler runs. Limits count
cumulative child body bytes and peer-created children, including closed ones;
association prefixes and CONNECT capsule bytes consume no session data credit.
Native final-size gaps are included once, even after local STOP.

Reads and final-known child closure replenish receive credit without waiting
for BLOCKED capsules. CONNECT output retains one bounded partial capsule and
advances advertised credit only after native acceptance of its complete bytes.
Malformed capsules reset CONNECT with `H3_MESSAGE_ERROR`; non-increasing grants
and stream limits above `2^60` use `WT_FLOW_CONTROL_ERROR` on negotiated flow.

Outgoing creation checks session count credit before native construction and
charges only successful ownership transfer. A failed or blocked attempt queues
no delayed creation; retry explicitly from application scheduling after a peer
grant. Writes return only the accepted prefix allowed by the peer's data
credit. At zero credit, requested writable interest is retained without
repeated callbacks; a later MAX_DATA schedules native writable service.
RESET, STOP and FIN progress independently. Existing children and credit output
continue while a session drains, although new child creation is rejected.

The [positive-flow checkpoint](../benchmarks/results/webtransport_positive_flow_v1/2026_11_17/README.md)
retains the native matrix, exact source snapshots and relocatable replay.

## Verification

The cross-implementation gate uses pinned curl/ngtcp2 and aioquic clients to
verify the normal request path, a valid trailing field section, and malformed
pseudo-header/connection-field rejection with `H3_MESSAGE_ERROR`. Malformed and
healthy sibling streams share one connection so connection-wide aborts fail the
gate. The gate then soaks more malformed requests than the engine's full header
pool (`2 * connection capacity`), requires a healthy request on a fresh
connection, and requires the server to exit cleanly so `deinit` can assert that
every pool was drained. The gate retains server logs, traces, versions, results,
and qlogs; see [operations.md](operations.md) and
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md).
