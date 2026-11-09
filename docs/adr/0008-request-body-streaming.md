# 0008. Bounded request body streaming

- Status: Accepted; HTTP/1.1 and TLS live, H2/H3 binding deferred
- Date: 2026-10-26
- Revision: typed request view and platform activation guard, 2026-10-27
- Release: 2.2.0 ships the contract and live H1/TLS binding; 2.3.0 owns H2/H3 binding
- Deciders: transport, HTTP, router, QUIC, and root integrator

## Context

Every live transport currently buffers request bodies before dispatch. Its
Content-Length policy applies the buffered ceiling before routing, so a new
handler alone cannot support a 100 MB upload. Response producers and async
response tokens do not provide a request coroutine runtime.

Choose the route-level sink recommended by the milestone plan. Keep framing
and lifecycle validation pure; transport drivers call application sinks and
perform I/O. The full-body APIs remain the default and remain compatible.
M1 must finish before this decision's transport implementation starts.

## 2.2.0 delivery note

2.2.0 ships the public `StreamingRequest`, `BodySink`, `BodyRoute`,
`BodyControl`, `BodyState`, pure HTTP/1 body decoder, and the incremental
multipart sink. HTTP/1.1 and TLS HTTP/1.1 bind the sink live through
`App.post_stream`, `put_stream`, and `patch_stream`; a 1 MiB live upload is
covered with a 16 KiB buffered cap. HTTP/2 and HTTP/3 still buffer request
bodies and return 501 for a streaming route. The 2.3.0 milestone owns H2/H3
DATA/QUIC stream binding, flow-control pause/resume, trailers, and the 100 MB
bounded-memory proof. See the
[2.2.0 release record](../releases/2.2.0.md#limits-and-dated-restoration-criteria).

## Compatibility revision, 2026-10-26

A compiler proof recorded during the 2.2.0 review showed
that adding BodyNotBuffered to an existing inferred helper error set breaks
unchanged buffered consumers. Preserve Request/OwnedRequest, their layouts,
helpers, error sets and clone semantics. New sink callbacks receive a distinct
metadata-only StreamingRequest with its own explicit refusal contract. Do not
alias the new error into an unrelated old parse error or widen legacy helpers.
The route-level lifetime, framing, flow-control and capacity decisions remain.

## Public contract

Add ServerConfig.stream_request_bodies, default false. Enabling it reserves
bounded startup storage; registration cannot resize a running slab.
Setup eligibility is limited to Linux, macOS, and Windows. Enabled setup on
other targets returns the existing InvalidTransportConfiguration error before
allocation or owner binding; community BSD activation requires worker wakeups
and native validation first. The user confirmed this scope on 2026-10-27.
Eligibility does not establish runtime support, and the Windows release-job
gate remains in force. Disabled configurations, generic loops, pure decoders,
body registries, and BodyState retain their existing contracts. The
isolated platform guard is verified; production transport integration is
deferred to 2.3.0 and recorded in the
[2.2.0 release record](../releases/2.2.0.md#limits-and-dated-restoration-criteria).
route_body returns BodyStreamingDisabled when the feature was not enabled.
It borrows an immutable BodyRoute whose lifetime covers the App:

```zig
pub const BodyReadiness = enum { ready, paused };
pub const BodyProgress = struct { consumed: usize, readiness: BodyReadiness };
pub const BodyBinding = struct {
    context: *anyopaque,
    readiness: BodyReadiness = .ready,
};
pub const BodyLimits = struct { max_body_bytes: u64, max_active: u16 };
pub const BodyBeginFn = *const fn (*anyopaque, *const StreamingRequest, BodyControl) anyerror!BodyBinding;
pub const BodyChunkFn = *const fn (*anyopaque, []const u8) anyerror!BodyProgress;
pub const BodyEndFn = *const fn (*anyopaque, *const StreamingRequest, *Response) anyerror!void;
pub const BodyCancelFn = *const fn (*anyopaque, BodyCancelReason) void;
pub const BodySink = struct {
    context: *anyopaque,
    begin: BodyBeginFn,
    chunk: BodyChunkFn,
    end: BodyEndFn,
    cancel: BodyCancelFn,
};
pub const BodyMiddlewarePolicy = enum { reject_legacy, headers_only };
pub const BodyRoute = struct {
    sink: BodySink,
    limits: BodyLimits,
    middleware_policy: BodyMiddlewarePolicy = .reject_legacy,
};
pub const BodyCancelReason = enum {
    cancelled, peer_closed, reset, invalid_body, body_too_large,
    timeout, shutdown, source_failure, sink_failure,
};
pub const BodyControlError = error{
    BodyControlExpired, BodyCallbackActive, BodyNotPaused, BodyDeliveryFailed,
};
```

StreamingRequest contains method/target/path/protocol/query slices, the existing
HeadersView and a named RouteParamsView over primary/extra capture arrays.
It exposes no raw body, legacy Request pointer or runtime BodyMode. Projection
is pure and copies no metadata arrays. text()/bytes() return empty; its JSON,
schema, form and multipart helpers return the closed BodyReadError set
`error{BodyNotBuffered}` before parsing, media checks, allocation or issue
mutation. Query parsing and case-sensitive capture lookup remain available.
Use HeadersView directly rather than a second broad header facade.

The caller supplies per-request state through begin's returned context. The
library never allocates it. max_active is a required positive admission bound
per route, per worker; existing connection/stream slots also bound concurrency.
Store counters within the existing router-record capacity. Refuse admission
before begin when its quota is full, with 503. A declared or observed logical
body above max_body_bytes receives 413 before accepting the offending bytes.
A zero logical limit permits only an empty body. Invalid registration limits
return InvalidBodyLimits. Check counters and logical arithmetic for overflow.

## Admission and terminal ownership

Validate framing and finish initial headers before choosing buffered or
streaming policy. Preserve existing early-data, method, QUERY, upgrade, and
routing rules. Buffered routes retain their existing ceiling and complete-body
middleware timing. For an enabled streaming route:

1. Pin initial metadata and validate the route's global middleware policy.
2. Run every authorized global once in existing order, using a header-only
   legacy Request with an empty body; preserve its baseline helper semantics.
3. Check declared length, physical ingress, admission, and metadata capacity.
4. Preserve middleware metadata, reserve admission, project StreamingRequest,
   and call begin.
5. After successful admission, send any required 100 Continue and deliver data.

A successful begin establishes exactly one end or cancel. A failed begin owns
its partial-resource rollback; no context was accepted and no cancel follows.
Release its admission reservation. Defer cancellation during begin until its
return; a successful binding returned after cancellation still receives cancel.

Each chunk slice is borrowed only during the callback. The sink consumes or
copies its accepted prefix. ready requires consumed equal to the offered
length; a partial prefix must return paused. Reject over-consumption and
zero-progress ready results. paused stops delivery until explicit resume,
including a pause after consuming the final byte. Do not spin-poll the sink.

Call end only after exact framing/length agreement, validated trailers, no
queued data, and readiness. Invalidate control generations before terminal
notification and release admission once after it returns. End follows normal
synchronous response rules: complete its fresh Response or arm an existing
response producer. It does not acquire an AsyncResponse token. End owns its
cleanup even on error; its error aborts output without a second cancel.
Starting an outgoing producer does not extend upload binding lifetime: output
context, scratch and any retained metadata owner must independently survive
that response. Never retain freed binding state or callback-only request/view
arrays. Individual pinned metadata bytes retain their separate response lifetime.

Cancel reasons distinguish application cancellation, peer close/reset, invalid
body, limit, timeout, shutdown, source failure, and sink failure. Reset/shutdown
during a callback records cancellation and defers notification and slot/context
release until the callback unwinds. Never release or recycle callback storage
under an active callback. Forbid event-loop reentry and App destruction there.

## Control and request lifetime

BodyControl is copyable, generation checked, and confined to the owning loop.
Its public operations are resume(control: BodyControl) BodyControlError!void
and cancel(control: BodyControl) BodyControlError!void. Both execute inline:
they may synchronously invoke terminal callbacks and release caller-owned sink
state before returning. Callers must not access per-request context after either
call without an independently valid lifetime. Copy needed values before calling.

BodyControlExpired covers inactive/stale generations; BodyCallbackActive refuses
reentrant use during begin/chunk, and BodyNotPaused refuses an unpaused resume.
Those validation errors change no state. BodyDeliveryFailed means resumed
delivery or end failed and the owner performed its terminal failure path; it
does not return the old context to the caller. Cancel does not use the latter
two errors. Resume retries retained input before arming reads and can deliver
pending end with no remaining bytes. Cancel abandons the upload through its
owner, invoking cancel before returning. Generation validation precedes callback
validation, so controls used from a terminal callback are already expired.

The App and backing storage must outlive every control use, matching the
existing async-token boundary. Header slices and route captures remain pinned
through deferred end and subsequent response lifetime. Move HTTP/2's shared
overflow captures to per-stream ownership before admitting streaming requests.
StreamingRequest pointers and header/capture array views are borrowed for each
callback only; retain individual pinned byte slices or owned copies instead.
Keep source arrays/slots valid through the whole active callback, including
synchronous response end/reset, and through any longer response lifetime.
Control expiration does not permit storage recycling under a terminal callback.

Request and OwnedRequest remain unchanged, including buffered body helpers and
all inferred error sets. New StreamingRequest.clone explicitly allocates an
OwnedStreamingRequest metadata snapshot with checked sizes and failure cleanup.
It owns flat byte/header/capture arrays and copies no body, future data, control,
response or transport pointer. view() derives borrowed HeadersView/RouteParamsView
from stable heap arrays after construction; no view points into a moved inline
Request. Returning the owner before deriving a view is safe. Deinit invalidates
all views. This separate owned type preserves body unavailability without a
legacy runtime mode. Validate and discard trailers on every transport; they
never merge into initial headers and end has no trailer view.

## Middleware and early responses

BodyRoute defaults to reject_legacy. With any registered global middleware,
route_body refuses that policy with BodyMiddlewareIncompatible before route
mutation. Do not add an error to old App.use/Router.use/listen/run to police
later registration. Admission rechecks the entire global chain: an incompatible
late use gets bounded 503 before callbacks, quota, begin or 100 Continue.

Explicit headers_only certifies every current/future global uses metadata and
response operations only. Invoke all globals once in their existing order;
none is silently skipped. Their original Request ABI sees an empty body and
baseline helper behavior: form may parse an empty form, without a new error.
BodyNotBuffered belongs to new StreamingRequest callbacks. Body-dependent
globals must retain buffered routes or move validation into the sink. The
policy adds no registry or middleware-capacity assumption.

Retain up to the current 2048-byte pending-header capacity across middleware
and end; never retain the stack Response pointer. HTTP/1 reserves persistent
header storage only when streaming is enabled. HTTP/2 and HTTP/3 may reuse
their idle response-header storage, copying metadata into the fresh Response
before encoding overwrites it. Preflight capacity before begin, including
configurations smaller than 2048; refuse overflow without truncation.

Before the body completes, middleware can append headers or send a bounded
fixed final response. Open-error stream/file/JSON/SSE starts return
BodyNotComplete before any head, pending-header, queue or ownership mutation.
Legacy send_file keeps its closed set and uses the semantically appropriate
existing BodyNotAllowed tag for this phase. Do not use ZeroCopyUnavailable,
which would invite fallback. JSON/SSE wrappers must reach the guard before
mutating headers. Preserve the
nonfallible writable_stream signature; its first write reaches that guard.

Early HTTP/1 rejection closes after final output drains. HTTP/3 stops reads
independently of response writes. HTTP/2 emits NO_ERROR reset only after every
final frame is accepted into ordered output. A high-level end call with pending
DATA is insufficient: retain explicit retry state, or abort on output failure.
Never queue reset ahead of the final response bytes.

## HTTP/1 and TLS

Add a header-ready admission boundary before buffered body policy. Extract one
pure incremental decoder for fixed-length/chunked framing; return consumed
offsets and body/end/error events without invoking sinks. Reuse that decoder
in the buffered collector to preserve framing strictness.

Pin the initial prefix and reuse its physical tail as bounded ingress. For
L=max_request_line_size, H=max_header_size, and B=max_body_size, the existing
request stride is S=align_up(L+H+B+1024,16). With parsed request-line length q
including CRLF and header content length k, header_end=q+k+4, q<=L, k<=H.
Compute R=S-header_end with checked arithmetic. Normal validated configurations
give R>=B+1020; defaults give S=41,984 and worst-prefix R=17,404. Persistent
middleware metadata is separate and does not reduce R.

Admission requires no ingress for an absent/known-empty body, R>=1 for positive
Content-Length, and R>=3 for chunked framing, including an empty chunked entity.
An unusable low-level storage configuration returns BodyIngressUnavailable and
503 before begin/100 Continue, then closes after output. Never grow storage.

For streaming chunked input, line_content_limit=min(H,R-2), excluding CRLF,
applies to each chunk-size/extension line and trailer field line. A chunk payload
can exceed R and is delivered in pieces. Trailer content is the sum of field-line
content lengths plus 2*(field_count-1), bounded by H; field count is at most 64,
matching existing trailers independently of initial max_header_count. Empty
trailers consume two bytes. Validate incrementally without retaining the whole
section. This per-line bound is new for streaming mode; buffered line/status
behavior is preserved. Malformed/overlong framing and trailer bounds fail with
400 and close; logical route limits use 413; initial-line/header limits retain
431. Error output is best-effort if transport writes have already failed.

Keep logical counters separate from buffer offsets. Preserve following pipeline
bytes and suspend dispatch through upload/response ownership. Cap enabled-path
raw TCP reads and SSL_read at min(8192,free_ingress), even before admission, so
no unretained plaintext suffix can remain after a pause. Never call SSL_read
with zero capacity. A full retained window pauses reads; it is not by itself a
body-limit error.

For selected TLS HTTP/1, positive plaintext capacity and readiness gate new
encrypted receives; their byte count is min(8192,the network BIO write guarantee).
The existing 32 KiB BIO retains ciphertext independently of plaintext ingress.
Sample that guarantee immediately before submission or rearm. Preserve one
active receive, one inbound BIO writer and the same BIO through retirement, so
an already submitted receive may retain its reserved ciphertext after a pause
without extracting plaintext or rearming. Handshake receives and selected
HTTP/2/WebSocket paths retain the BIO bound without the HTTP/1 window gate.
This ciphertext exception avoids tiny socket reads while assembling a TLS
record; it adds no spill buffer and does not relax SSL_read's plaintext bound.

Pause socket reads and TLS plaintext extraction while preserving BIO contents.
Resume consumes retained plaintext first. An upload pause retains idle-timeout
coverage; do not inherit dispatch_suspended's current timer cancellation.

## HTTP/2 storage and credit

Continue parsing connection frames while a sink is paused. Queue unaccepted
DATA in connection-owned 1024-byte blocks with per-stream head/tail indices
and a free list. Do not allocate a complete receive window per stream.

Hold DATA credit, including consumed head prefixes, until each occupied block
is completely reclaimed. Refund padding immediately because it uses no retained
payload storage. The required pool payload bound is:

```text
round_up(65535 + max_streams * 1023, 1024)
```

At eight streams this is 73,728 bytes, plus 432 planned bytes for three u16
metadata fields per block, before owner state/alignment. Only the partial tail
of each queued stream adds unaccounted fragmentation; consumed head bytes stay
uncredited. At most 1023 consumed bytes per queued stream remain held this way.
Allocate this pool only when streaming is enabled; measure both enabled and
disabled layouts on Linux, macOS, and Windows.

The pool is independent of max_h2_body_size/body_stride, which retains its
positive buffered request/response role. Streaming bypasses complete-body
ceilings after admission and never requires a 1024-byte or 65,535-byte stride.
Validate the enabled pool at startup. A low-level session with missing/undersized
storage returns BodyIngressUnavailable/503 before begin rather than accepting
and later overflowing on its first legal DATA frame.

Keep checked pending connection/stream WINDOW_UPDATE counters. Validate before
output and update actual receive windows only after the whole frame is accepted.
WouldBlock preserves the intent without granting credit. Reset reclaims queued
storage, restores connection credit once, and drops obsolete stream intents.

Control frames and outbound responses continue during a pause. Exhausting the
shared connection receive window can block all inbound DATA; unconditional
sibling upload progress is not promised. This follows
[RFC 9113 flow control](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.2.2).

## HTTP/3 and informational headers

Move buffered body-cap policy after routing while retaining structural header
validation. Reuse a bounded ingress window and pause only that stream with
wantread(0). Trailer decoding must not overwrite initial overflow-header arrays.
max_h3_body_size supplies this reusable window; one byte suffices, independently
of the logical route limit. Normal configured engines already require positive
capacity. A malformed low-level zero-window streaming fixture refuses before
begin with BodyIngressUnavailable/503; preserve the buffered zero-window probe.

Pinned lsquic supports successive IETF header blocks after the previous block
is sent; a pending block can refuse another. Implement private bounded interim
paths: HTTP/1's literal, HTTP/2 status-100 HEADERS without END_STREAM, and HTTP/3
status 100 without write shutdown and with retry state. Do not consume final
pending metadata or mark final headers sent. Admit before 100 Continue; do not
wait for content to decide whether to send it. Source inspection is provisional
until real-client validation, following
[RFC 9110 Expect](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.1).

## Implementation and acceptance

First prove unchanged narrow-return/exhaustive-catch buffered consumers through
release exports, new typed helper refusals, owned snapshot lifetime/failure
cleanup, and unchanged legacy layout. Earlier runtime-mode prototype growth
must not be applied to config assertions. Later adapters must prove middleware
policy/refusal ordering and the closed send_file error/ownership exception.
End/reset inside BodyEnd cannot recycle its metadata before return; a pending
output producer must use independently valid context after upload cleanup.

Implement serial slices: common types/storage/router admission, HTTP/1/TLS,
HTTP/2, HTTP/3, the transport matrix, then incremental multipart. Keep the body
decoder and lifecycle/progress invariants common; adapters own I/O and storage.
Do not introduce a generic continuation framework.

Prove 100,000,000 logical bytes on every claimed transport using bounded input
and exact byte/hash checks. Cover split framing, chunk CRLF/extensions, trailers,
100 Continue, metadata retention, limits/admission, pause/resume at EOF, errors,
resets/shutdown, callback cancellation, stale tokens, and no library allocation
after startup. Preserve existing buffered suites. Record exact source, capacities,
commands, raw results, sanitizer/target/package gates, h1spec/HTTP2 regressions,
real HTTP/3 clients, fuzzing, and independent review.

Multipart follows the stable sink: a pure event parser with the plan's boundary
and metadata bounds, boundary.len + 4 carry, and an optional explicit-Io file
adapter. Retain the full-body API; verify every boundary split, 100 MB input,
backpressure/errors, fuzzing, and a deterministic same-input comparison.

## Design review

Fresh-context review found two actionable omissions: control calls could release
sink state synchronously without an explicit caller lifetime rule, and physical
ingress/framing limits were deferred. The concrete operations/errors, inline
terminal semantics, capacity formulas, limits, and refusal outcomes above resolve
both. Bounded re-review found no remaining actionable contract issue. The root
integrator accepts the design; runtime and client evidence remain implementation
requirements, including the provisional HTTP/3 informational-header path.

The compatibility follow-up rejects the initial shared runtime-mode guards:
actual buffered compiler consumers would break. Independent revision review
supports the distinct typed view, unchanged legacy surfaces and explicit global
middleware policy. Its remaining outgoing-producer lifetime clarification is
incorporated above with adapter acceptance; no output hook is introduced. Bounded
re-review found no remaining findings; root accepts this revised design.
Toy declaration/membership probes establish feasibility only; actual revised
source, compiler consumers, measurements and all required gates remain mandatory.
