# 0008. Bounded request body streaming

- Status: Accepted; live on H1/TLS/H2/H3 with pause/resume
- Date: 2026-10-26
- Revision: typed request view and platform activation guard, 2026-10-27
- Release: 2.2.0 ships live H1/TLS/H2/H3 binding with pause/resume
- Deciders: transport, HTTP, router, QUIC, and root integrator

## Context

At decision time, every live transport buffered request bodies before
dispatch. Its Content-Length policy applied the buffered ceiling before
routing, so a new handler alone could not support a 100 MB upload. Response producers and async
response tokens do not provide a request coroutine runtime.

Choose the route-level sink recommended by the milestone plan. Keep framing
and lifecycle validation pure; transport drivers call application sinks and
perform I/O. The full-body APIs remain the default and remain compatible.
M1 must finish before this decision's transport implementation starts.

## 2.2.0 delivery note

2.2.0 ships the public `StreamingRequest`, `BodySink`, `BodyRoute`,
`BodyControl`, `BodyState`, pure HTTP/1 body decoder, and the incremental
multipart sink. HTTP/1.1, TLS HTTP/1.1, HTTP/2, and HTTP/3 bind the sink live through
`App.post_stream`, `put_stream`, and `patch_stream`; live 1 MiB and 100 MB
uploads are covered on plaintext and TLS with a 16 KiB buffered cap. Every
transport supports pause/resume; H2 withholds stream credit and H3 stops
reading, both retaining a bounded suffix. Live H2 and H3 100 MB socket-pair
uploads pass; the HTTP/3 compliance client measured RSS growth under 1 MiB
against a 64 MiB bound. All four transports send `100 Continue` after
streaming admission. H2 streaming route matching uses the inline 16 capture
slots, so larger capture configurations use the buffered path. See the
[deliberate boundaries](../roadmap.md#deliberate-boundaries).

## Compatibility revision, 2026-10-26

A compiler proof recorded during the 2.2.0 review showed
that adding BodyNotBuffered to an existing inferred helper error set breaks
unchanged buffered consumers. Preserve Request/OwnedRequest, their layouts,
helpers, error sets and clone semantics. New sink callbacks receive a distinct
metadata-only StreamingRequest with its own explicit refusal contract. Do not
alias the new error into an unrelated old parse error or widen legacy helpers.
The route-level lifetime, framing, flow-control and capacity decisions remain.

## Public contract (2.2.0)

The shipped opt-in is route registration, not a `ServerConfig` switch.
`App.stream(method, path, *const BodyRoute)`, `post_stream`, `put_stream`,
`patch_stream`, and `Router.route_stream` register a borrowed route for the
application lifetime. There is no `ServerConfig.stream_request_bodies` flag,
no `route_body` entry point, and no `BodyStreamingDisabled` path. The route
registration is the opt-in; a transport that cannot stream returns 501 for that
route. Buffered `Request.body` remains the default and source-compatible path.

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
library never allocates it. max_active is a required positive per-session
admission bound: HTTP/1 and TLS allow one active upload per connection, HTTP/2
bounds concurrent streams on one connection by this value, and HTTP/3 allows
one per stream. The fixed connection/stream slab remains the hard memory
bound. A declared or observed logical body above max_body_bytes receives 413
before accepting the offending bytes.
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
the transport refuses admission before begin rather than silently invoking it:
HTTP/1 returns 500, HTTP/2 resets with REFUSED_STREAM, and HTTP/3 returns 501.
Registration itself does not fail, so existing App.use/Router.use signatures
stay unchanged. Explicit .headers_only certifies every current and future
global as metadata-only; admission invokes those globals once before begin.

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

## HTTP/2 storage and credit (2.2.0)

The implementation uses the per-stream `body_stride` slab as the bounded
suffix. While a sink is paused, the session retains at most one stride of
unaccepted DATA for that stream and withholds the stream WINDOW_UPDATE credit;
connection credit is refunded immediately so sibling streams can progress.
The earlier 1024-byte block-pool design was not adopted: the per-stream slab
already bounds each stream, and the connection footprint stays fixed. A paused
stream therefore resets with ENHANCE_YOUR_CALM if a peer sends more than the
retained stride instead of growing storage. Control frames and outbound
responses continue during a pause.

## HTTP/3 and informational headers (2.2.0)

The stream reuses its bounded `body_storage` as the ingress scratch and retains
the unaccepted suffix in the same slab. A pause calls `wantread(0)`; resume
retries the suffix before reading new bytes. The earlier `max_h3_body_size`
window and interim 100-continue design were not needed for the shipped H3
implementation. The buffered body-cap check now runs after route selection so a
streaming route can accept a declared body larger than the per-stream slab;
buffered routes still return 413 before reading.

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
and exact byte/hash checks. The 2.2.0 suite contains live H1/TLS, HTTP/2, and
HTTP/3 100 MB proofs; the H3 compliance artifact also bounds RSS growth. Cover split framing, chunk CRLF/extensions, trailers,
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
