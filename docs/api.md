# Application API Guide

This is the practical guide to the µWebZockets application surface. It is the
map; each linked protocol document has the wire-level detail.

- [http.md](http.md) — HTTP/1.1 parsing, routing, middleware, helpers, static files
- [http2.md](http2.md) — HTTP/2, HPACK, RFC 8441 tunnels
- [quic.md](quic.md) — HTTP/3, QPACK, WebTransport status
- [websocket.md](websocket.md) — RFC 6455, compression, pub/sub
- [json_rpc.md](json_rpc.md) — JSON-RPC 2.0
- [client.md](client.md) — outbound HTTP/1.1 client
- [multipart.md](multipart.md) — bounded incremental multipart events and acknowledgement
- [memory_model.md](memory_model.md) — capacities, slab layout, backpressure
- [deployment.md](deployment.md) — production checklist

## Application types

| Type | Connections | Message size | Write queue | Idle timeout |
| --- | ---: | ---: | ---: | ---: |
| `App(N)` | `N` | 16 KiB | 64 KiB | 120 s |
| `ConfiguredApp(N, message, queue)` | `N` | compile-time | compile-time | 120 s |
| `ConfiguredAppWithTimeout(N, message, queue, timeout_ms)` | `N` | compile-time | compile-time | compile-time |
| `Server.builder(io)` | runtime config | runtime config | runtime config | runtime config |

`App(N)` is the shortest path. `Server.builder` is the fluent path for runtime
configuration and presets:

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();
```

`build` performs exactly one application allocation: the contiguous slab behind
the pool, request buffers, message regions, write queues, router storage, and
optional compression scratch. `ServerConfig` presets are listed in
[memory_model.md](memory_model.md).

## Lifecycle

```zig
var app = try uz.App(128).init(init.io);   // one allocation
defer app.deinit();                        // drains, then releases the slab

_ = try app.get("/", hello);
try app.listen_all(&.{                    // bind every port before accepting
    .{ .address = "0.0.0.0", .port = 3000 },
    .{ .address = "0.0.0.0", .port = 3001 },
});
try app.run();                             // blocks until shutdown drains
```

`listen` is the one-endpoint convenience wrapper. `listen_all` replaces it; it
returns `error.AlreadyListening` after either call. A `.tls = true` endpoint
requires an HTTPS initializer (`init_https`, `init_https_ephemeral`, or
`init_http3`) before the listen call.

| Step | Rules |
| --- | --- |
| `init*` | Choose plaintext, HTTPS, mTLS, or HTTP/3; HTTPS variants load credentials before the loop starts |
| Route registration | Before the first `listen`; later calls return `error.RoutesLocked` |
| `listen` / `listen_udp` | Bind and start accepting; the `App` must stay at a stable address |
| `listen_all` | Bind up to four TCP endpoints, verify every port, then arm accepts |
| `run` | Drives the loop until shutdown completes; `error.ApplicationAlreadyRunning` if re-entered |
| `request_shutdown` | Safe from any thread or a callback; stores the request and wakes the owning loop, then returns |
| `shutdown` | Loop-thread only: from a callback it begins shutdown, otherwise it drives the loop and drains before returning |
| `deinit` | Panics if called from inside the event loop; always pair with `defer` |

### Graceful shutdown signals

```zig
try app.catch_shutdown_signals();
try app.run();
```

`catch_shutdown_signals` installs a process-wide SIGINT/SIGTERM watcher (a
Windows console-control handler on Windows) that requests the same shutdown
path as `shutdown`. Install it once per process. Cluster applications use
`Cluster.catch_shutdown_signals()`, which requests shutdown for every worker.
The watcher is allocation-free and coalesces repeated signals.

## Routing and handlers

```zig
_ = try app.get("/users/:id", show_user);
_ = try app.post("/users", create_user);
_ = try app.query("/search", search);        // RFC 10008 QUERY
_ = try app.trace("/probe", trace);           // opt-in TRACE
_ = try app.any("/health", health);
```

| Registration | Callback signature | Use |
| --- | --- | --- |
| `get` / `head` / `post` / `put` / `delete` / `patch` / `options` / `trace` / `query` / `any` | `fn (*Request, *Response) void` | Synchronous work |
| `route_context` / `get_context` | `fn (*anyopaque, *Request, *Response) void` | Explicit caller-owned state |
| `route_async` / `get_async` | `fn (*Request, AsyncResponse) void` | Work completed later |
| `route_async_context` / `get_async_context` | `fn (*anyopaque, *Request, AsyncResponse) void` | Deferred work with state |
| `post_stream` / `put_stream` / `patch_stream` | `BodyRoute` sink callbacks | Request-body streaming on H1/TLS/H2/H3 |

Path patterns: exact segments stay on the radix fast path, `:name` captures one
nonempty segment, and a terminal `*name` captures the remainder. Static routes
win. Malformed patterns fail registration rather than matching ambiguously.

A streaming route borrows a `BodyRoute` for the application lifetime and uses
`begin`/`chunk`/`end`/`cancel` callbacks. The sink context is application-owned;
`BodyControl` pauses and resumes delivery. `middleware_policy = .headers_only`
authorizes global middleware that does not read the body. H2/H3 streaming
routes return 501; use the buffered helpers there.

`trace` is opt-in: the library does not register a route or synthesize the
RFC 9110 echo response. A handler that reflects the request must redact
`Authorization`, `Cookie`, `Proxy-Authorization`, and application secrets, and
must keep the reflected bytes within the response capacity. Prefer disabling
TRACE on public deployments unless an operational requirement exists.

## Middleware

`App.use(context, handler)` appends at most 32 global middleware callbacks; they
run in registration order and stop on `.stop` or a started response. Built-in
middleware: `Cors`, `SecurityHeaders`, `Auth`, and `RateLimit`. See
[http.md](http.md#middleware).

## Request

| Group | API |
| --- | --- |
| Target | `req.method`, `req.target`, `req.path`, `req.query`, `req.url()` |
| Headers | `req.headers()`, `req.get_header`, `req.get_unique_header`, `req.header_has_token` |
| Body | `req.text()`, `req.bytes()`, `req.json(T, allocator)`, `req.body` |
| Route captures | `req.get_param`, up to 16 borrowed captures |
| Query and form | `req.query_params()`, `req.query_params_of(N)`, `req.form()` |
| Ownership | `req.clone(allocator)` returns an `OwnedRequest` for deferred work |

## Response

Request body streaming has an accepted [design contract](adr/0008-request-body-streaming.md).
`App.post_stream`, `put_stream`, and `patch_stream` bind a `BodyRoute` sink on
HTTP/1.1, TLS HTTP/1.1, HTTP/2, and HTTP/3; the sink receives chunks as they
arrive. HTTP/1/TLS use `BodyControl` to pause/resume; H2/H3 are ready-only and
reset a paused stream. H2/H3 flow-control pause remains 2.3.0 work. See the
[2.2.0 release record](releases/2.2.0.md#limits-and-dated-restoration-criteria).

| Group | API |
| --- | --- |
| Simple bodies | `res.text`, `res.html`, `res.bytes`, `res.json`, `res.json_buf` |
| Streaming JSON | `res.begin_json()` |
| Chunked output | `begin_chunked`, `write_chunk`, `end_chunks` |
| Drain-driven bodies | `res.begin_stream()` with a `StreamProducer` |
| Files | `res.send_file()`, `res.stream_file()` with `FileSource`, `App.static` |
| Server-Sent Events | `res.sse()` |
| Redirects and headers | `res.redirect`, `res.append_header`, `end_with_headers` |
| Callback ABI endings | `end_best_effort`, `end_with_headers_best_effort` (aborts the TCP connection or HTTP/2/3 stream on failure) |

Response producers follow the [backpressure and completion contract](http.md#response-producer-backpressure).
Known-length file responses follow the [file ownership contract](http.md#bounded-file-responses).

## Asynchronous responses

An async token is copyable, generation-checked, and completes exactly once:

```zig
fn deferred(_: *uz.Request, token: uz.AsyncResponse) void {
    // Hand the token to a worker, then complete it on this loop.
    token.complete("200 OK", "later") catch {};
}

fn delayed(req: *uz.Request, token: uz.AsyncResponse) void {
    const delay_ms = std.fmt.parseInt(u64, req.get_param("ms") orelse "0", 10) catch 0;
    // Borrowed fields are retained in the connection-owned parking slot.
    token.sleep_complete(delay_ms, "200 OK", "Content-Type: text/plain\r\n", "later") catch {};
}
```

A pending token keeps the request buffer or HTTP/3 stream from being reused.
Complete it on the owning event loop; marshal cross-thread results back to that
loop before completing. `sleep` parks a custom resume callback;
`sleep_complete` parks a response with borrowed fields. HTTP/1 uses one
connection-owned slot and HTTP/2 maps one slot per stream, so neither allocates.
A disconnected peer, a reused generation, or an expired token fails closed.

Each parking slot owns one delay callback. A second sleep replaces that callback
and re-arms its timer; it does not provide simultaneous pending delays. Do not
reuse a slot this way or rely on re-arming to expire an earlier response token:
the current response generation remains pending until completion, cancellation,
or reuse. HTTP/3 has no stream-owned parking node and returns TimerUnavailable.

The timing wheel's exact range is 67,108,863 milliseconds, about 18.64 hours.
Longer deadlines wait on an intrusive overflow list and re-enter the wheel when
they come into range. The active scheduler uses a bounded 5 ms driving tick;
that is not a wall-clock callback-latency guarantee. The
[2.2.0 release record](releases/2.2.0.md#limits-and-dated-restoration-criteria)
records the remaining timer and response-token requirements.

`ServerConfig.idle_timeout_ms` bounds a drained keep-alive connection.
`ServerConfig.header_read_timeout_ms` bounds an incomplete HTTP/1 request head
or body; HTTP/2 header blocks are bounded by `max_h2_header_block_size` and the
connection idle deadline. Both use the per-worker timing wheel; zero disables
the corresponding deadline.

## WebSocket, static files, RPC, OpenAPI

```zig
_ = try app.ws("/chat", .{ .open = on_open, .message = on_message, .close = on_close });
_ = try app.static("/assets", "public", .{});
_ = try app.rpc("/rpc", &service);
_ = try app.openapi("/openapi.json");
```

`negotiate.select_encoding(header, available)` returns an optional
`Encoding` (`identity`, `gzip`, or `br`) using fixed storage and no I/O. See
[the content-coding contract](adr/0009-static-content-coding.md) for weights,
refusals, and duplicate handling. Callers supply verified availability; static
sidecar selection is a separate integration step.

## Cluster

`listen_all(&.{ ... })` binds up to four TCP endpoints and does not arm any
accept completion until every socket has bound and reported a local port. A
bind or verification failure closes the sockets created by that call, leaves
`listener_count == 0`, and keeps routes unlocked. Each endpoint may set
`.tls = true` or `.tls = false`; null follows whether the application owns a TLS
context. All TLS listeners share the application certificate.

`App.cluster(worker_count)` and
`Server.builder(...).build_cluster(allocator, worker_count, options)` return a
heap-backed thread-per-core manager. `worker_count` is the compiled capacity.
`build_cluster` uses that capacity unless `ClusterOptions.worker_count` selects
fewer active workers; `build_cluster_from_environment` prefers an explicit
`ClusterOptions.worker_count`, then `UWEBZOCKETS_WORKERS`, then the platform CPU
count.
Configure routes per worker, `listen` once, and `run` joins every worker.

`Cluster.publish` broadcasts through bounded per-worker rings. It keeps its
`!usize` shape; after `run` it returns `error.ClusterStopped` instead of
queueing into loops that no longer consume.
`Cluster.publish_report` returns a named `PublishReport` with `queued`,
`dropped`, `notify_failed` (including a stopping loop), and
`first_dropped_worker`; `publish` keeps its `!usize` shape and returns
`queued`. `all_delivered()` means every worker accepted and every wakeup was
posted, not that an application subscriber consumed the message. Validation
happens before any inbox is mutated, so a bad topic or oversized payload cannot
partially deliver.
`Cluster.request_shutdown` drains all workers.

### Cluster lifecycle and failures

| API | Contract |
| --- | --- |
| `state()` | `configured`, `running`, `stopped`, `releasing`, or `released` |
| `worker_count()` | Workers allocated for the active runtime count |
| `worker_capacity()` | Compiled worker capacity |
| `configure(callback)` | Typed `ConfigureCallback`, before any thread starts |
| `first_failure()` | `WorkerFailure { index, phase, err }`, or null |
| `failure_count()` | Total failures recorded since the last `run` |
| `run()` | Spawns, joins, and returns the named `RunError` |
| `deinit_checked()` | Typed release claim; `error.ClusterRunning` while active |

```zig
var group = try uz.Server.builder(init.io)
    .with_max_clients(256)
    .build_cluster(std.heap.page_allocator, 4, .{});
defer group.deinit();

const Group = @TypeOf(group);
try group.configure(struct {
    fn routes(worker: *Group.Worker, index: usize) !void {
        _ = index;
        _ = try worker.get("/", hello);
    }
}.routes);

try group.listen("0.0.0.0", 3000);
group.run() catch |err| {
    if (group.first_failure()) |failure| {
        std.log.err("worker {d} ({s}): {s}", .{
            failure.index,
            @tagName(failure.phase),
            @errorName(failure.err),
        });
    }
    return err;
};
```

Lifecycle-sensitive calls reject `error.ClusterDeinitialized`,
`error.ClusterRunning`, or `error.ClusterStopped` instead of silently touching
released or drained worker storage. `run` uses the same names for re-entry.
The first worker failure wins, so a shutdown cascade does not replace the root
cause. A spawn failure records phase `spawn`; an event-loop failure records
phase `run`; a post-run drain failure records phase `cleanup`.

The `threads`, `active_workers`, `thread_count`, `worker_failed`, and
`deinitialized` fields stay public and source-compatible. They are
compatibility mirrors; `state()`, `first_failure()`, and `worker_count()` are
authoritative. `Cluster.deinit` keeps its panic contract; supervisors that
need a typed error call `deinit_checked()`. A concurrent `deinit_checked()` waits for the winning
releaser to publish `released` before returning.

`uz.cluster.message_queue` is an advanced helper for tests and embedders.
`broadcast` validates once and reports drops/wakeup failures; `pop_copy` leaves
a message queued when the caller buffers are too small; `pop_scratch` borrows
queue-owned scratch until the next call. One consumer owns each queue.
`Cluster.group` is an implementation detail; direct access can corrupt the
lifecycle and is not supported.

`state()`, `worker_count()`, `worker_capacity()`, `first_failure()`, and
`failure_count()` are safe from any thread that holds a mutable `*Cluster`;
they do not touch worker storage. Supervisor calls that
touch worker storage register an in-flight call, and release waits for them:
`request_shutdown()`, `publish()`/`publish_report()`, `configure()`, TLS
setup, `listen()`, and `catch_shutdown_signals()` cannot race storage
teardown, provided the `Cluster` value itself stays alive. Those mutating calls,
including `run()`, remain caller-serialized among themselves; `enter` protects
release teardown, not lifecycle ordering. Raw `worker()` pointers or public
fields need external synchronization, and a `Cluster` value must not be copied
or moved after `catch_shutdown_signals()` or `run()` starts.

`request_shutdown` after `deinit` remains a documented non-erroring no-op: the
worker slice has already been released, so rebuild the cluster instead of
relying on shutdown to report a lifecycle error. See
[architecture.md](architecture.md),
[ADR 0003](adr/0003-tls-cluster-operational-boundaries.md), and
[ADR 0007](adr/0007-cluster-lifecycle-and-failures.md).

### TLS-enabled clusters

```zig
Cluster.enable_https(cert_path: [:0]const u8, key_path: [:0]const u8) !void
Cluster.enable_https_ephemeral() !void
```

Call one of these exactly once after `configure` and before `listen`:

```text
build_cluster -> configure -> enable_https (or enable_https_ephemeral)
              -> listen -> run -> request_shutdown or shutdown signal -> deinit
```

Each worker creates and owns one BoringSSL `SSL_CTX` before any listener
exists; each connection creates its own `SSL` from that worker's context.
Credential files are read once per worker at startup. TLS state is never
shared between loops, and the request path adds no lock or allocation. The
context is TLS 1.3 only with ALPN `h2` then `http/1.1`. `enable_https` does not
configure client certificates.

HTTP/3/QUIC clustering is not supported. `init_http3` and `listen_udp` remain
single-application APIs, and a cluster listener is TCP/TLS only.

| Error | Cause |
| --- | --- |
| `error.ClusterDeinitialized` | A lifecycle-sensitive call was made after `deinit` |
| `error.ClusterRunning` | A configuration call was made while `run` was active |
| `error.ClusterStopped` | A configuration, listen, or publish call was made after `run` returned |
| `error.AlreadyListening` | `enable_https` was called after `listen` started |
| `error.TlsAlreadyEnabled` | `enable_https` was called more than once |
| `error.CertificateLoadFailed` / `error.PrivateKeyLoadFailed` | The PEM files could not be read or parsed; a mismatched key fails here too |
| `error.TlsContextCreationFailed` / `error.ProtocolConfigurationFailed` | BoringSSL could not create or configure the context |
| `error.ApplicationUnavailable` | A worker was already shutting down or deinitialized |

A failed enable releases only the contexts it created and can be retried. Use
`enable_https` with PEM files in production; `enable_https_ephemeral` generates
a distinct development certificate per worker and can also return the
`Ephemeral*` generation errors in [tls.md](tls.md#zig-error-reference). See
[tls.md](tls.md#tls-enabled-clusters).

## Observability

```zig
var server = try uz.Server.builder(init.io)
    .with_observability(true)
    .with_dev_log(true)
    .build(std.heap.page_allocator);
```

- `with_dev_log(true)` prints a startup wordmark and per-request lines; stderr
  is only written when it is a terminal unless `set_dev_log_file` binds a file.
- `App.log_metrics()` records every counter of the bounded Prometheus registry.
- `uwz_connections_accepted`, `uwz_connections_closed`, `uwz_http_requests`,
  and `uwz_ws_messages` advance for HTTP/1.1 and HTTP/2. HTTP/3 emits request
  records but does not advance the counter registry yet.

## Ownership and lifetime rules

| Value | Valid until |
| --- | --- |
| `Request` fields, route captures | Synchronous handler return, or async token completion; see the HTTP/1 producer-body exception below |
| WebSocket `message` slice | Callback return |
| `ResponseView` from the client | Callback return, or `FetchStorage` lifetime |
| `AsyncResponse` token | Completed exactly once; copyable |
| `App` value | Must not move after `listen`/`listen_udp`, nor after any context-capturing registration: `openapi`, `datagram`, or the observability install performed by `listen` |
| `Cluster` value | Single owner; do not copy; must not move after `catch_shutdown_signals`/`run`, and must stay alive through `deinit_checked` |
| `Cluster.worker(i)` | Borrowed pointer; valid until release begins, and must not be retained across `deinit_checked` |

Slices always borrow connection storage. Copy into bounded application storage
or use `clone` for work that outlives the callback.

An armed HTTP/1 response producer pins the current `Request.body` storage until
producer completion or cancellation. It can read that body on each producer
callback without retaining a separate body slice. Return after successful
`end_chunks`; request ownership may then be released. This body lifetime does
not extend handler-local application data or route-capture scratch.

## Error handling

Framework methods return Zig error sets; route handlers report failures through
the `Response`. Capacity exhaustion is explicit: `413` for oversized bodies,
`431` for oversized headers, `503` for exhausted WebSocket tunnel or capacity
limits, and `error.WouldBlock` from WebSocket `send`. Structured JSON rejection
bodies name the limit and its value. See
[troubleshooting.md](troubleshooting.md).

## C and C++ consumers

`zig build lib` installs `zig-out/include/uWebZockets.h` with versioned opaque
handles, `uwz_slice` views, and a versioned error mapping. The C ABI is a
high-level server ABI: the low-level `udp`, HTTP/2, HPACK, HTTP/3-extension,
WebTransport, and client modules are Zig-only. See
[operations.md](operations.md#c-abi).


The [2.2.0 release record](releases/2.2.0.md#limits-and-dated-restoration-criteria)
retains shared TCP credentials, opt-in TRACE without automatic reflection, and
the current C single-endpoint surface. It defines the consumer requirements and
ownership tests needed to reopen those boundaries.
