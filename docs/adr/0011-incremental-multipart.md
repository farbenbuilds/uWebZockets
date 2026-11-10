# 0011. Incremental multipart events and part sinks

- Status: Accepted
- Date: 2026-10-26
- Deciders: HTTP, transport, verification, and root integrator
- Release: 2.2.0

## Context

The existing multipart Parser requires a complete buffered entity. Part.chunks
iterates that existing body; it does not accept incremental network input.
Uploads need bounded recognition and backpressure without retaining a complete
part. [ADR 0008](0008-request-body-streaming.md) supplies the outer body lifecycle.
This decision adds multipart recognition and accepted-part cleanup within it.

Preserve the legacy Parser, Part, ChunkIterator, Request/OwnedRequest helpers,
buffered results and inferred error sets. New StreamingRequest/OwnedStreamingRequest
views alone have the BodyNotBuffered refusal contract. No legacy hardening or
shared error-set widening belongs in this change.

## Decision

Keep a pure StreamingParser in the existing multipart namespace. A separate
multipart_sink module invokes application part callbacks and enforces their
once-only lifecycle. The parser imports no callbacks, transport, file or Io.
All state and working memory are caller-owned; parsing and delivery allocate
nothing. Keep working buffers stable and exclusively owned until disposal;
they cannot overlap each other, current input or another upload. The existing
explicit allocator clone surface remains separate.

Use these named types:

```zig
pub const StreamingLimits = struct {
    max_body_bytes: u64,
    max_parts: u32,
    max_part_headers: u16,
};
pub const StreamingStorage = struct { headers: []u8, carry: []u8 };
pub const PartMeta = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
};
pub const StreamingEvent = union(enum) {
    part_begin: PartMeta,
    part_data: []const u8,
    part_end: void,
};
pub const StreamingStep = struct {
    consumed: usize,
    event: ?StreamingEvent = null,
};
```

The concrete operations are init(boundary, limits, storage), next(parser, input),
accept_data(parser, consumed), and finish(parser). Use a named StreamingError
set for invalid boundary/storage/limits, logical/header/part limits, malformed
metadata, missing disposition/name, truncation and invalid progress/state.
Do not expose unrelated container errors or use a generic error mapper.

## Bounds and recognition

Copy the validated boundary into a fixed configuration array, at most 70 bytes.
Require positive part/header-count bounds and nonempty header storage. The
header buffer bounds header content, excluding its final CRLFCRLF separator.
Count every field, including ignored fields. All arithmetic is checked.

Require carry.len >= boundary.len + 4 at init; reject smaller storage with
InvalidMultipartStorage before accepting body bytes. Use only that prefix,
even if the caller supplies more.
Header lookbehind and delimiter carry share this storage in disjoint phases.
After matching a complete known prefix, reconstruct it from boundary/literals
and scalar cursors; reuse carry for undecided suffix bytes. No hidden payload
array or payload packed into scalars supplements that bound.

The u64 logical limit counts the entire decoded HTTP entity: envelope, headers,
payload, preamble and epilogue. Count accepted input once; replay counts zero.
Bound every offered payload event by remaining budget before invoking a sink.
Limits must reject the offending acceptance before any external sink effect.

Opening delimiters retain legacy line-start handling; later delimiters need
CRLF. Wait for a complete boundary and valid suffix. A false delimiter prefix
inside a part remains payload at every split, including the legacy abcX case.
The CRLF introducing a real delimiter belongs to framing. Empty parts emit no
empty data callback; an immediate closing delimiter permits zero parts.

[RFC 2046 section 5.1.1](https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1)
defines the boundary grammar and padding requirement. The initial implementation
supports exact CRLF ordinary suffixes and closing double-dash suffixes. Ignore
subsequent epilogue while counting it against the logical limit.

MP-L1: ordinary delimiter transport padding remains unsupported, matching the
legacy exact-suffix subset. Owner: HTTP and root; declared 2026-10-26. A padded
ordinary prefix is not recognized as a delimiter. Closing epilogue handling
does not establish padded-line validation. Make no general RFC 2046 conformance
claim. Restore padding only after a reviewed storage/accounting bound, every
split/overlap/pause test, fuzz coverage and updated capacity evidence.

Validate all part headers before begin: tokens/colon/CRLF, no folding, NUL or
invalid controls. Require one form-data disposition with a present name. Reject
duplicate recognized name/filename parameters and duplicate disposition/type
fields. Empty-present names differ from missing names. A bounded scanner handles
quoted semicolons/pairs and decodes permitted pairs within their header spans.
Do not change legacy first-match/permissive parsing to share this policy.

PartMeta omits raw headers. Its normalized slices borrow header storage until
the next parser mutation, or only begin_part's callback when using the sink.
Copy retained metadata before returning, including a paused begin. Treat file
names as opaque metadata, following
[RFC 7578 section 4.2](https://www.rfc-editor.org/rfc/rfc7578#section-4.2).

## Accepted-prefix ownership and EOF

next accepts only step.consumed. Begin/end events commit once before returning;
there is no parse-ahead queue. Data stays unaccepted until accept_data(n).
The event borrow ends at acknowledgement or another mutating operation.
Reject next while an event awaits acknowledgement.

Store pending origin/count, never a retained input pointer. accept_data returns
additional input advancement: n for input data, zero for previously accepted
carry/configuration replay. Reoffer the exact unaccepted input suffix; it may
move to different backing storage. Validate acknowledgement before changing
byte acceptance state. An invalid acknowledgement accepts zero additional input
bytes and leaves carry contents, payload/replay cursors and logical counts
unchanged. It marks the parser failed and invalidates the pending event borrow;
earlier framing/carry progress is not rolled back. Every parser error after
successful initialization is terminal. Subsequent next/accept_data/finish calls
return InvalidMultipartState without emitting events.

When a carried candidate proves false, replay it before accepting the deciding
mismatch. A paused replay therefore leaves real input for BodyControl.resume.
Recheck CR/CRLF overlap without losing held suffix bytes. Once all real input
is accepted, a paused metadata event is already committed and no deferred
payload remains. A full final-data pause can resume directly into finish/end.

finish validates once at outer entity EOF and emits no event. Partial delimiter,
headers, missing close or pending data fails; never flush a potentially pausing
payload callback from BodySink.end. No synthetic empty chunk or extra resume
hook is introduced. Terminal failure/success rejects further operations.

## Effect adapter and terminal ownership

PartSink has explicit context and named begin_part, write_chunk, end_part and
cancel_part aliases. Begin/end return BodyReadiness; write returns BodyProgress;
cancel receives BodyCancelReason. One MultipartSink holds the parser, immutable
callbacks and active/terminal state. Its consume returns exact outer progress;
finish validates EOF and cleans up; cancel terminates once.

Only successful begin establishes an active part. Failed begin rolls itself
back and receives no cancel. Validate write progress with the common body
contract before acknowledging it. Write/parser failure retains the active part
for outer cancellation after the chunk callback unwinds. Parser failure must
not suppress cleanup of that accepted active part; invalid sink progress is
rejected before accept_data.

Mark a part inactive before end_part: it owns cleanup on success, pause or error
and never receives a later cancel. Mark terminal before cancel_part; notify an
accepted active part once. Failed finish aborts such a part once before returning,
because outer BodySink.end owns cleanup even on error and has no later cancel.
After paused end_part, outer upload cleanup owns stopping any retained work.

Part callbacks cannot free their containing upload or reenter the driver.
Outer terminal cleanup releases that containing state after adapter cleanup.
Never retain callback-only request/metadata arrays or Response pointers. Copy
controls/independently valid values before inline control operations, which may
free upload state. Pending response producers need independent output lifetime.

Parser/part callback errors from BodyChunk remain outer sink failures. This
decision adds no automatic multipart HTTP status or early-response policy.
Defer a library file helper until a real consumer needs it. A sample may write
to an already-open caller-owned file using explicit Io and checked offsets;
caller end/cancel owns destination, close, rollback and durability. No filename
opens a path, borrowed payload is queued, or asynchronous disk claim is made.

## Implementation and acceptance

Production integration follows the common sink and transport gates in ADR 0008.
Parser-only preparation can run isolated. Implement and review pure events,
then the concrete effect adapter, trust-boundary fuzzing and real integration.

Prove all delimiter/header splits at boundary lengths 1/70, false prefixes,
overlaps, exact bounds, minimum B+4 success/B+3 init refusal, guard bytes,
quoted metadata, empty/missing/duplicate
names, truncation at every offset and invalid terminal/progress operations.
Invalid acknowledgement preserves byte-accounting state and carry contents
while invalidating the event and latching failure; later operations emit nothing.
Pause at every event/data prefix, relocate input, poison accepted storage and
check exact output. Exercise each replay fragment with the final real mismatch
retained; prove zero-input resume into finish and once-only cleanup/error paths.
Keep old closed-error consumers and buffered tests unchanged.

Add Smith and a real LLVM multipart target, with coverage/export checks, build
and OSS-Fuzz enumeration, bounded corpus, dictionary, options and smoke. Prove
100,000,000 logical bytes using fixed small blocks and bounded slow-sink storage.
Separately compare both parsers on the same complete deterministic 100 MB
caller fixture prepared before timing. Verify equal metadata/count/hash first;
retain raw samples and disclose host/mode/splits. No numerical speedup threshold
or quiet-host claim is inferred. Run canonical source/sanitizer/target/package,
fuzz and actual upload transport gates with independent review.

## Review

Independent contract review found one stale acceptance statement that assigned
BodyNotBuffered to legacy Request.multipart. The corrected contract separates
unchanged legacy helpers from new typed refusals and replaces stale ADR anchors.
No additional byte-ownership/EOF defect was found. Compression review also
required the explicit init carry minimum; the decision and acceptance now
preserve it. Bounded re-review found no remaining findings; root accepts the
contract. No implementation results are claimed.

An implementation-time ambiguity review clarified that invalid acknowledgement
changes only terminal/event-control state, accepting no additional bytes. This
preserves both pre-acceptance validation and the no-events-after-error contract;
independent bounded review accepted the clarification before implementation.
