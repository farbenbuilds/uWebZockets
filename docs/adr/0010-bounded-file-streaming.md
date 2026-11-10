# 0010. Bounded file streaming on framed transports

- Status: Accepted
- Date: 2026-10-26
- Deciders: transport, HTTP, QUIC, and root integrator
- Release: 2.2.0

## Context

Plaintext HTTP/1 already supports kernel sendfile. TLS, HTTP/2, and HTTP/3
cannot use that path and static files larger than the route buffer currently
receive 413. General response producers have no cancellation callback, while
static files need descriptor ownership to survive asynchronous output and to
end on cancellation. HTTP/1 producers also default to chunked framing, which
does not satisfy the plan's exact Content-Length requirement for static files.

## Interface

Keep `Response.send_file` as the preferred plaintext path. Add
`Response.stream_file(status, headers, source: FileSource) !void` with a named
source record:

```zig
pub const FileSource = struct {
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    offset: u64,
    length: u64,
};
```

The source carries no allocation. Its buffer is borrowed, nonempty, fixed, and
worker-local. Its storage and the Io context must outlive completion or
cancellation. Normal `App.static` handlers already have separate storage per
App, and App shutdown drains transports before releasing their handlers.
Lower-level callers must uphold the same lifetime and loop ownership.

The caller owns the descriptor until the call succeeds. Every returned error
leaves descriptor ownership with the caller. Validate framing, response state,
status, header capacity, target support, transfer-slot capacity, and checked
`offset + length` before accepting the file. Ownership commits only after the
known-length head is accepted or copied and the producer is armed. After that
point, a synchronous producer fault uses transport teardown and the call must
not return an error that implies caller ownership.

Success is terminal for the caller's Response: its state becomes ended and
ordinary writes, end_chunks, another stream, or parking are refused. TCP's
dispatch completion must preserve an active transport-owned file producer
instead of clearing it with the caller's ended response. The internal pump
constructs a separate streaming response view with private file framing.
TCP dispatch suspension follows the owned-file slot before ordinary ended
response cleanup. HTTP/2 and HTTP/3 already retain their producer on this path.
This keeps user writes from exceeding the declared length or ending it early.

HEAD sends the selected representation length and accepts/closes the file once
without invoking its body producer. Empty files complete without body reads.
Reject 204, 205, and 304 before ownership, including zero-length files. Static
304 retains the existing metadata-only end path. Reject successful CONNECT
file responses before generating Content-Length, following
[RFC 9110 section 8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6).
HEAD on an otherwise supported status remains permitted.

## Storage and progress

A private named FileTransfer stores the descriptor, Io context, borrowed
scratch, current offset, remaining length, and current chunk bound. There is
one transfer slot per HTTP/1 connection, HTTP/2 stream slot, or HTTP/3 stream;
an occupied slot refuses another transfer before taking ownership. Measure
the exact slab increase on POSIX and Windows. No output queue, TLS record,
HTTP/2 window, or static route-buffer capacity increases for this feature.

Add named optional file-arming callback aliases to Http2Target and Http3Target,
defaulting to null so existing custom target initializers keep compiling.
They enforce the same error-retains-caller-file contract and refuse unsupported
targets before emitting a head. They locate persistent transfer storage and
pass the known length without teaching the HTTP/2 session about file I/O.

Use a common internal StreamProducer with the existing public callback
signature. Each invocation performs at most one bounded positional read. The
owning transport sets a current chunk bound from its writable capacity:

- HTTP/1 TLS: plaintext capacity after record overhead and pending BIO output.
- HTTP/2: positive connection and stream credit, DATA frame capacity, remaining
  length, and scratch length.
- HTTP/3: available response-body storage and scratch length.

Check remaining length zero before checking current credit: terminal framing
must not require WINDOW_UPDATE after the final byte exhausts an HTTP/2 window.
A temporary zero bound with bytes remaining yields pending without reading.
Permanently zero body/DATA storage refuses a nonempty transfer before ownership;
an empty file or HEAD can complete without body storage. This refusal applies
only when an actual nonempty body is sent. Accepted bytes advance file
progress exactly once. WouldBlock advances nothing; rereading the same offset
on a later callback is permitted. Use bounded readPositionalAll so valid
positive short syscalls accumulate. Fewer bytes than requested from that call
mean premature EOF and fail closed. File growth cannot extend the declared
range.

Every existing adapter consumes or copies source bytes before returning.
HTTP/3's later partial writes refer to its own response-body storage. This
allows interleaved producers on one loop to share the route scratch. It must
be proved with source-buffer poisoning and partial-drain tests. Never reuse
TCP's TLS ciphertext scratch for file plaintext: flushing TLS can overwrite
that scratch while plaintext is still being consumed.

The borrowed route scratch must not overlap transport-owned output, BIO,
HTTP/2, or HTTP/3 storage. It must not be used concurrently or recursively
during a file callback. Worker locality alone does not establish these
nonaliasing and nonreentrancy requirements; normal static route scratch does.

## Framing and cleanup

HTTP/1 needs a named internal stream-framing state, defaulting to chunked.
Only accepted file transfers select fixed-length framing: write_chunk emits
raw bytes and end_chunks emits no chunk terminator. HTTP/2 gets a known-length
streaming head operation, without file I/O in the session layer. HTTP/3 adds
internally generated Content-Length to its existing bounded prepared headers.
Application-supplied framing headers remain refused.

Clear producer pointers and owned-file state before closing a descriptor.
Completion, producer fault, peer/local reset, connection close, and protocol
reset all converge on the owning transport's existing teardown seams. Repeated
cleanup must be harmless. HTTP/2 connection close needs an explicit sweep of
all producer/file slots; waiting for stream-slot reuse would retain files.
Cleanup must not act on a recycled slot with a different stream ID.
The internal producer must not access its FileTransfer after end_chunks can
synchronously clear it.

These reads use explicit bounded std.Io operations. This decision does not
claim asynchronous disk I/O. An asynchronous disk backend can be considered
separately after its ownership and measured benefit are established.

## Asset filesystem boundary

Static roots use an operator-controlled namespace. Untrusted users must not
create or replace entries beneath it. Deployment can replace regular files
with regular files; it must not substitute FIFOs, devices, or other special
types while serving. Filesystem I/O is synchronous and has no bounded-latency
guarantee against a hostile filesystem or writer.

Sidecar probing checks the final leaf without following symlinks on the same
already-confined parent handle, then performs the no-follow read open and
descriptor stat. Stable nonregular candidates never reach the read open;
freshness uses descriptor metadata. This preserves supplied std.Io semantics
and rejects symlinks, but cannot prevent regular-to-FIFO replacement between
preflight and open. The pinned API has no portable nonblocking read-open flag;
Windows stat itself can open a handle. The existing source opener shares that
local-writer limitation. Do not describe this preflight as race-free or
universally nonblocking. Supporting hostile filesystem writers needs a
separate native-opening/custom-Io contract.

Linux uses a private `path_only` open of the final leaf for this preflight.
Zig 0.16.0 pathname stat treats filesystem `ENAMETOOLONG` as an unexpected
errno, so appending a sidecar suffix to an otherwise valid source name can
panic. Both pinned Linux Io backends map that error from open to the catchable
`NameTooLong` result. An O_PATH descriptor is statted, required to be regular,
and closed before the readable open; it never becomes transfer input. Other
platforms retain their existing pathname stat. This narrow stdlib workaround
is an integrator-approved exception to the transport profile's prohibition
on new OS conditions in portable modules. Remove the Linux specialization
when the pinned pathname-stat implementation returns `NameTooLong` normally,
retaining the long-name and special-file regressions. No filesystem component
limit is inferred from `Dir.max_name_bytes`.

## Static integration

Keep send_file first for plaintext and use stream_file for framed delivery.
If a legacy custom target has no file callback, only FileStreamingUnsupported
permits its existing bounded small-file fallback. Do not convert WouldBlock or
other errors into a buffered success. Add Options.precompressed=false for
opt-in sidecars, preserving default identity behavior.
The static handler owns its fixed scratch; each in-flight descriptor belongs
to its transport slot. Evaluate sidecars only through the existing confined,
symlink-refusing opening path. Fresh regular sidecars have mtime at least that
of the opened source. Apply [ADR 0009](0009-static-content-coding.md) after
determining available representations, accounting for all encoding field lines.
When sidecar integration needs it, add a selector over the existing
fetch.HeadersView that shares private scalar accumulation with the single-field
helper. Iterate every matching field, including extra headers, and distinguish
absent fields from present empty values. This needs no copied header buffer or
new capacity; it is not implemented by this decision record.

Retain the original path's MIME type. Validators include the selected coding
and file metadata; conditionals and ranges run after selection. Ranges address
the selected representation's bytes. Emit Vary: Accept-Encoding for negotiable
identity responses and 304 as well as encoded responses. Metadata-derived ETags
retain the existing assumption that asset metadata changes when content does.

## Review and implementation acceptance

Independent ownership/framing review found caller-state, terminal-credit,
bodyless framing, callback compatibility, permanent-capacity, and scratch
aliasing gaps. The architect confirmed the amended contract, and independent
bounded re-review found no remaining blocking design findings. The root
integrator accepts the contract for implementation. Implement serial slices
for HTTP/1 TLS, HTTP/2, HTTP/3, then static selection. Review each slice before
integration. No file-transfer implementation is claimed by this ADR.

Required regressions: patterned files larger than scratch; exact length and
bytes; partial drain; tiny HTTP/2 windows; interleaved shared scratch; HEAD and
empty files; ranges, If-Range, and 304; framing/head refusal retaining caller
ownership; truncation; peer/local reset; connection shutdown; repeated cleanup;
and slot reuse. Sidecar tests cover quality/refusal, missing/stale files,
representation validators, encoded ranges, traversal, and symlinks. Required
repository, sanitizer, protocol, package-consumer, and static-profile evidence
remain part of M1 acceptance.
