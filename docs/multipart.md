# Incremental multipart parsing

`uz.multipart.StreamingParser` accepts arriving entity chunks using caller-owned
working storage. The parser emits part metadata, borrowed payload, and part-end
events. It performs no I/O or allocation and never retains an input pointer.
Live request-streaming routes are available through `App.post_stream`; this utility can
already parse chunks supplied by an application.

```zig
var headers: [2048]u8 = undefined;
var carry: [74]u8 = undefined;
var parser = try uz.multipart.StreamingParser.init("upload-boundary", .{
    .max_body_bytes = 100_000_000,
    .max_parts = 128,
    .max_part_headers = 16,
}, .{ .headers = &headers, .carry = &carry });
```

The boundary is copied and must contain 1–70 valid bytes. Init requires positive
part and field limits, nonempty header storage, and at least `boundary.len + 4`
carry bytes. It uses only that carry prefix. Keep the working buffers stable,
exclusive, and disjoint from each other and from input. The header buffer bounds
header content, excluding the final CRLFCRLF. The logical limit counts the
entire entity, including preamble, framing, headers, payload, and epilogue.

Call `next(input)` and advance input by `StreamingStep.consumed`. Its optional
`StreamingEvent` has these cases:

| Event | Ownership and progress |
| --- | --- |
| `part_begin: PartMeta` | Committed once; metadata borrows header storage until the next parser mutation |
| `part_data: []const u8` | Nonempty borrowed payload; acknowledge an accepted prefix with `accept_data(n)` |
| `part_end` | Committed once; no acknowledgement is required |

`PartMeta` contains `name`, optional `filename`, and optional `content_type`.
Copy retained metadata before another parser mutation. Filenames are opaque
metadata; the parser does not interpret them as paths.

Advance input by the additional count returned from `accept_data(n)`. This is
`n` for current-input data and zero for replay of already accepted carry. Reoffer
the exact unaccepted input suffix; it may move to another backing buffer. The
payload borrow ends at acknowledgement or another mutation. Call `next` again
only after acknowledging the previous data event. Partial acknowledgement,
including zero, lets an application pause delivery without accepting more input.

At entity EOF, call `finish()` once. It validates the closing delimiter and
emits no deferred payload. Missing closes, truncated metadata or delimiters,
pending data, and exceeded bounds fail closed. Every error after successful
initialization is terminal; later operations return `InvalidMultipartState`.
Invalid acknowledgements accept no additional bytes and preserve byte
accounting, carry, and replay cursors before invalidating the event.

The incremental scanner validates all part headers before emitting metadata.
It rejects missing disposition/name, duplicate disposition/type fields or
recognized parameters, folding, invalid controls, and malformed quoted values.
An empty present name is accepted. False boundary prefixes inside payload are
delivered as data at every chunk split.

Ordinary delimiters require an exact CRLF suffix; closing delimiters use `--`.
Preamble and epilogue are supported. Ordinary delimiter transport padding remains
unsupported under MP-L1 in [ADR0011](adr/0011-incremental-multipart.md); this is
an explicit MIME subset. Existing `Request.multipart()`, `multipart.Parser`,
`Part`, and `ChunkIterator` retain their buffered contracts and error sets.

## Part sinks

`uz.multipart.MultipartSink` connects parser events to an application-owned
`uz.multipart.PartSink`. Construct it with an initialized parser and the sink's
context and callbacks. The adapter owns that parser afterward; keep its working
buffers and the sink context alive through outer completion or cancellation.

| Callback | Contract |
| --- | --- |
| `begin_part(context, PartMeta)` | Returns `BodyReadiness`; success accepts the part, including when paused. Metadata is borrowed only for this callback. A failed begin owns its own cleanup. |
| `write_chunk(context, data)` | Returns `BodyProgress` for a nonempty borrowed payload. A ready result must accept the whole chunk; a paused result may accept a prefix, including zero. |
| `end_part(context)` | Returns `BodyReadiness` and owns that part's cleanup on success, pause, or error. It is called once. |
| `cancel_part(context, reason)` | Releases a successfully begun part that has not reached end. It is called at most once. |

Call `consume(input)` for each nonempty outer body chunk. It returns the outer
`BodyProgress`, including framing bytes already accepted before a pause. On
resume, reoffer only the unaccepted suffix. A paused begin or end is already
committed and is not called again. Empty resume chunks are unnecessary.

At outer EOF, call `finish()` even after a final end callback paused and was
subsequently resumed. It validates the closing boundary and owns active-part
cleanup on failure. On a `consume` error, call `cancel(reason)` after the part
callback has unwound; the outer owner retains that cleanup obligation. Repeated
cancellation is harmless, including after successful finish. Callbacks must not
reenter the adapter or free its containing upload.

An ended part receives no later `cancel_part` callback. If a paused `end_part`
retains asynchronous work, outer terminal cleanup must stop that work before
freeing the upload, working buffers, or sink context.

The adapter performs no file I/O and supplies no automatic HTTP status. An
application chooses its outer body callbacks, storage lifetime, response, and
file policy. The adapter is transport-agnostic; `App.post_stream`,
`put_stream`, and `patch_stream` can drive it from HTTP/1.1, TLS, HTTP/2, or
HTTP/3.
