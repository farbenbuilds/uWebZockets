# HTTP/1.1, Routing, and Middleware

This document covers the HTTP/1.1 transport, the radix router, middleware, and
the allocation-free request/response helper layer. HTTP/2 and HTTP/3 share the
same application boundary; see [http2.md](http2.md) and [quic.md](quic.md) for
their wire behavior.

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, and bodies, and unsupported expectations. Pipelined
bytes are retained and parsed again after a response completes. Request targets
accept origin-form, absolute-form for `http`/`https`, and asterisk-form for
server-wide `OPTIONS`; authority-form, fragments, and userinfo are rejected.
Responses validate control-character injection and ambiguous `Content-Length` /
`Transfer-Encoding` before writing.

Every complete request in one read buffer is dispatched in order. When another
request already follows, its response bytes accumulate in the bounded write ring
and the read completion ends with one socket write. A lone request keeps the
direct nonblocking `sendmsg` fast path, so pipelining does not add a copy to the
common case.

### Limits and rejections

| Input | Default | Configured by | Oversized result |
| --- | --- | --- | --- |
| Request line | 8 KiB | `with_max_request_line_size` | `431 Request Header Fields Too Large` |
| Header block | 16 KiB | `with_max_header_size` | `431 Request Header Fields Too Large` |
| Header count | 64 inline fields | `with_max_header_count` | Spills into per-connection slab storage, then `431` |
| Request body | 16 KiB | `with_max_body_size` | `413 Payload Too Large` |

`with_max_header_size` also sizes HTTP/3 request-header storage. Values above
65535 remain valid for HTTP/1.1 and HTTP/2, but `listen_udp` rejects them
because lsxpack field lengths are 16-bit.

Rejections carry the structured JSON documents described in
[memory_model.md](memory_model.md), so a client always learns which limit it
hit and by how much. `100 Continue` is handled automatically.

### Reading a request

```zig
fn search(req: *uz.Request, res: *uz.Response) void {
    // Register routes on the path only; the query string is already split off.
    const params = req.query_params() catch return;
    const page = (params.get_int(u32, "page") catch null) orelse 1;
    var scratch: [96]u8 = undefined;
    res.json_buf(.{ .query = params.get("q") orelse "", .page = page }, &scratch) catch {};
}
```

`Request` fields and route-parameter values borrow the connection's request
buffer. They stay valid through a synchronous callback or until an asynchronous
response completes; copy them into bounded application storage for longer work,
or use `Request.clone(allocator)` for an owned snapshot.

### Writing a response

Use the highest-level helper that fits:

| Need | API |
| --- | --- |
| Fixed text, HTML, or bytes | `res.text`, `res.html`, `res.bytes` |
| A comptime or bounded JSON value | `res.json`, `res.json_buf` |
| Arbitrarily large JSON without allocation | `res.begin_json()` |
| Chunked output you drive | `begin_chunked` / `write_chunk` / `end_chunks` |
| A body produced as the transport drains | `res.begin_stream()` |
| Server-Sent Events | `res.sse()` |
| A file from disk | `res.send_file()`, `res.stream_file()`, or `App.static` |
| Gzip from the per-worker pool | `res.end_gzip()` with `with_http_compression(true)` |

`Response.end_gzip` compresses into the worker's startup-allocated scratch,
emits `Content-Encoding: gzip` and `Vary: Accept-Encoding`, and never allocates
on the request path. The input must fit `ServerConfig.max_body_size`; the
compressed result must also fit the transport's response capacity (HTTP/2 uses
its configured response stride). Compression is opt-in; do not gzip responses
that mix secrets with attacker-controlled input.

#### Response producer backpressure

`Response.begin_stream()` invokes its producer immediately, then resumes it
when output drains or flow-control credit returns. A producer writes bounded
chunks and returns `.pending` when `write_chunk` reports `error.WouldBlock`.
Advance the body offset only after a write succeeds, and retry refused bytes
on the next invocation. A successful write copies the bytes into transport
storage; the producer context must remain valid while the callback is armed.

Response size can exceed the write queue, but each individual write must fit
the transport's payload bound. Split large logical chunks into bounded writes;
framing and TLS records also occupy queue space. An atomic 64 KiB payload does
not fit the default 64 KiB queue once that overhead is included. A refused
oversized chunk does not become writable merely because the queue drains.

An empty `write_chunk` is a no-op. Call `end_chunks` successfully before
returning `.done`; retry `end_chunks` after backpressure as needed. Returning
`.done` without terminal framing uses the transport's producer-failure path.
After `end_chunks` succeeds, the callback is disarmed even if it returns
`.pending`. Producer errors abort the HTTP/1 connection or affected HTTP/2/3
stream; HTTP/3 can replace an unsent response with 500. HEAD and bodyless
statuses cannot start a response producer.

HTTP/2 retains blocked stream resets in fixed storage bounded by the configured
concurrent-stream capacity. It releases the failed stream once and sends its
reset before further response HEADERS or DATA, preserving healthy siblings
under ordinary output backpressure. Exhausting that fixed reset storage or
encountering a fatal transport error still fails closed.

#### Bounded file responses

`res.stream_file(status, headers, source)` sends a known-length file through
HTTP/1, TLS HTTP/1, HTTP/2, or HTTP/3. `uz.FileSource` supplies the open file,
`std.Io` context, nonempty scratch slice, offset, and length. The scratch and
Io context must remain valid until completion or cancellation. Keep the
scratch separate from transport storage and use it only on its owning loop,
without concurrent or recursive use. Reads are bounded positional operations;
this API does not provide asynchronous disk I/O.

On success, the caller's response is ended and the transport owns the file,
closing it once after completion or failure. Every returned error leaves the
file with the caller. HEAD sends the declared length and closes the accepted
file without reading; an empty file also completes without body reads. Bodyless
statuses and successful CONNECT responses are refused before ownership changes.
The response uses Content-Length and raw file bytes, without chunk delimiters.

HTTP/2 bounds reads by both flow-control windows. HTTP/3 copies accepted bytes
into its existing body storage before later partial writes. Both own a file
per stream. Legacy custom targets without file support return
FileStreamingUnsupported before accepting a descriptor.
Plaintext send_file remains the kernel path. App.static integration follows
separately. The ownership and framing decision is [ADR 0010](adr/0010-bounded-file-streaming.md).

## Routing

Exact routes stay on the radix fast path. A `:name` segment captures one
nonempty path segment, and a terminal `*name` captures the remaining path
including an empty remainder. `Request.get_param` reads up to 16 borrowed
captures.

- Static routes win over parameter and wildcard matches.
- Malformed patterns, duplicate parameter names, and nonterminal wildcards fail
  registration instead of falling back to ambiguous matching.
- Parameterized patterns with the same shape, which differ only in capture
  names, fail registration with `error.RoutePatternConflicts`; a registered
  route is never silently shadowed by another shape.
- Registration is a startup activity. Route arrays are immutable once a
  listener starts, so callbacks never observe a structural mutation.
- `App.openapi(path)` serves a generated OpenAPI 3.1 document; parameter and
  wildcard paths are emitted with OpenAPI braces.

```zig
_ = try app.get("/", index);
_ = try app.get("/users/:id", show_user);
_ = try app.get("/assets/*path", serve_asset);
```

### Handler shapes

| Registration | Callback | Use |
| --- | --- | --- |
| `get` / `head` / `post` / `put` / `delete` / `patch` / `options` / `trace` / `query` / `any` | `fn (*Request, *Response) void` | Synchronous work |
| `route_context` | `fn (*anyopaque, *Request, *Response) void` | Explicit caller-owned state |
| `route_async` | `fn (*Request, AsyncResponse) void` | Work that finishes later |
| context variants | `fn (*anyopaque, *Request, AsyncResponse) void` | Deferred work with state |

Asynchronous tokens are generation-checked and complete exactly once. A pending
token keeps the TCP request buffer or HTTP/3 stream from being reused. Complete
the token on the owning event loop; marshal cross-thread results back to it
first.

## Middleware

`App.use` appends at most 32 global middleware callbacks. They run in order and
stop when they return `.stop` or start a response.

```zig
var headers = uz.middleware.security_headers(.{});
_ = try app.use(&headers, uz.middleware.SecurityHeaders.handler);

var cors = uz.middleware.cors(.{ .origins = &.{"https://example.com"} });
_ = try app.use(&cors, uz.middleware.Cors.handler);
```

### Authentication

`Auth` validates the unique `Authorization` field against caller-owned Basic
and Bearer credential lists. It decodes Basic into a bounded stack buffer,
compares in constant time, and answers missing, duplicate, or invalid
credentials with `401 Unauthorized` plus a challenge listing only the
configured schemes.

```zig
var credentials = uz.middleware.auth(.{
    .realm = "ops",
    .basic = &.{.{ .username = "admin", .password = "secret" }},
    .bearer = &.{.{ .token = "service-token" }},
});
_ = try app.use(&credentials, uz.middleware.Auth.handler);
```

### Rate limiting

`RateLimit` charges caller-owned token buckets keyed by a custom function, an
FNV-1a hash of a configured header, or a constant. Buckets refill continuously
from the monotonic clock; an empty bucket receives `429 Too Many Requests` and
`Retry-After`. A full bucket table evicts the oldest entry and starts the
evicted key empty, so rotating a key cannot reset a budget.

```zig
var buckets: [256]uz.middleware.RateLimitBucket = @splat(.{});
var slots: [512]uz.middleware.RateLimitIndexSlot = @splat(.{});
var links: [256]uz.middleware.RateLimitLink = @splat(.{});
var limiter = try uz.middleware.rate_limit_indexed(io, .{
    .rate_per_second = 20,
    .burst = 40,
    .key_header = "x-api-key", // server-derived values only
}, &buckets, &slots, &links);
_ = try app.use(&limiter, uz.middleware.RateLimit.handler);
```

`rate_limit_indexed` is the O(1) path: an open-addressed key index plus an
intrusive LRU over the caller-owned links. `slots.len` must be at least twice
`buckets.len`, and `links.len` must equal `buckets.len`. A hit and a free-slot
insert are O(1) expected; a full-table miss evicts the exact oldest bucket,
with the lowest bucket index winning equal timestamps, and starts the new key
with zero tokens. Tombstones trigger an amortized rehash. The older
`rate_limit(io, options, buckets)` constructor remains as the documented linear
compatibility path for pre-seeded tables without index storage.

Both middleware types are allocation-free. One table belongs to one event loop;
create one per cluster worker. Prefer `key_fn` or `key_constant` when the key
header can be set by the client.

## Static files

Mount an operator-controlled asset directory. Untrusted users must not replace
its entries, and publishers should replace regular files with regular files.
Filesystem operations are synchronous; sidecar preflight cannot eliminate a
hostile type-substitution race. See the [filesystem boundary](adr/0010-bounded-file-streaming.md#asset-filesystem-boundary).

`App.static(prefix, root, options)` mounts a directory with directory-relative
path confinement, symlinks disabled, MIME detection, ETag and Last-Modified
validation, cache control, and one RFC 9110 byte range. `If-None-Match` handles
`*`, comma lists, and weak validators; `If-Range` must match the current strong
ETag or Last-Modified value before a range is applied. Plaintext `GET` and
`HEAD` responses stream the file with the kernel `sendfile` boundary
(`Response.send_file`), so assets are not capped by the per-route file buffer.
TLS, HTTP/2, and HTTP/3 stream through the handler's stable scratch, so whole
files need not fit the route buffer. Legacy custom targets without file
callbacks retain a bounded small-file fallback.

`negotiate.select_encoding(header, available)` is a pure helper for choosing
among caller-verified identity, gzip, and br representations. It scans the full
borrowed header with constant storage, honors explicit refusals and wildcard
weights, and returns null when every available representation is refused.
Absent fields prefer identity; equal positive weights prefer br, gzip, then
identity. Repeated codings use their minimum weight. The named
`EncodingAvailability` defaults to identity only. The contract and malformed
input policy are recorded in [ADR 0009](adr/0009-static-content-coding.md).
Enable sidecars with `app.static("/assets", root, .{ .precompressed = true })`.
Only confined regular `.gz`/`.br` files at least as new as the opened source are
available. Selection uses every Accept-Encoding field; complete refusal returns
406. Selected coding and metadata determine validators, lengths, and ranges;
ranges address encoded bytes. Negotiable responses include Vary, and encoded
responses include Content-Encoding. Default mounts preserve identity behavior.

`negotiate.select_encoding_headers(req.headers(), available)` applies the same
rules to every matching field, including overflow headers. It preserves late
refusals and absent/empty distinctions without copying field values.

## Request and response helpers

The accepted [request-streaming design](adr/0008-request-body-streaming.md)
defines the opt-in sink contract shipped as `StreamingRequest`, `BodySink`,
`BodyRoute`, and `BodyState`. HTTP/1.1 and TLS HTTP/1.1 bind it live through
`App.post_stream`, `put_stream`, and `patch_stream`; a sink receives chunks as
they arrive and can pause/resume with `BodyControl`. HTTP/2 and HTTP/3 still
receive buffered bodies and return 501 for a streaming route. See the
[2.2.0 release record](releases/2.2.0.md#limits-and-dated-restoration-criteria).

Framework modules expose zero-allocation query/form parsing with SIMD slicing
and compile-time capacities, streaming chunked JSON (`Response.begin_json`),
drain-driven producer bodies (`Response.begin_stream`), multipart iteration,
HMAC-SHA256 signed cookies with rotating keys and HTTP-date `Expires`, comptime
JSON field constraints with typed parse issues, canonical status lines, typed
JSON error documents, `Accept` negotiation, ETag and conditional-GET helpers,
CORS and security-header middleware, and SSE.

Every helper reuses the existing bounded buffers and stays off the heap on the
request path. For the full helper inventory, see [api.md](api.md).

The standalone [incremental multipart parser](multipart.md) accepts arriving
chunks with bounded caller storage and explicit payload acknowledgement. It
does not depend on the deferred request-streaming transport adapters.
The [2.2.0 release record](releases/2.2.0.md#limits-and-dated-restoration-criteria)
records the pure framing foundation, its buffered compatibility proof, and the
deferred live transport binding.

## Integration with another parser

Integration code may attach borrowed `extra_param_*` or `extra_header_*` slices
when adapting a different parser. The built-in parsers do not populate them or
expand their fixed capacities dynamically.
