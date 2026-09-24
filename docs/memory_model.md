# Memory Model

µWebZockets never allocates on the request path. Every connection slot, request
buffer, message region, response queue, and protocol table is sized before the
first listener starts and then reused for the process lifetime. This document
describes the layout, the startup slab, and the capacity contract.

## Allocation rules

| Phase | Allocation |
| --- | --- |
| `build` / `init` | One contiguous application slab via the caller allocator |
| Route registration | Fixed router storage only; lazily allocated RFC 7692 scratch is freed in `deinit` |
| `init_tls` | BoringSSL-internal state, bounded per connection |
| `listen_udp` | QUIC engine pools created before the listener succeeds |
| Request path | None |
| `deinit` | Every slab released once through its owner |

`Request.clone(allocator)` and `req.json(T, allocator)` are the only explicitly
allocating public request APIs. Everything else returns `error.WouldBlock` or a
specific bounded error instead of growing memory. Query and form parsing
(`Request.query_params`, `Request.form`), percent decoding, error documents,
`Accept` scoring, ETag matching, and the cookie helpers all slice or format into
caller-owned storage and never allocate. `Response.begin_json` streams JSON
through a fixed stack buffer into chunked response parts, so body size is
bounded by the configured write queue rather than by a rendering buffer.

## The startup slab

`src/router/config.zig` turns one `ServerConfig` into one `SlabLayout`. The
layout is computed with checked arithmetic and partitions a single aligned block
into these regions, in order:

| Region | Size |
| --- | --- |
| Connection pool storage | `max_connections * sizeof(TcpConnection)` |
| Pool freelist indices | `max_connections * sizeof(usize)` |
| HTTP/1.1 request buffers | `max_connections * request_stride` |
| Response write queues | `max_connections * write_queue_size` |
| WebSocket message storage | `max_connections * max_ws_message_size` |
| RFC 7692 compression scratch | `max_connections * 2 * worst_case_scratch` when enabled |

`request_stride` is the request line, header block, framing slack, and
`max_body_size`, rounded to a 16-byte boundary. Write queues start on a cache
line. `required_bytes` and `carve` share one offset computation, so sizing and
partitioning cannot drift apart. Pool storage is zeroed during initialization;
every other region is written before it is read.

`App.init` and `App.init_configured` allocate this block once and free it once;
`App.init_from_slab` accepts caller-owned storage with the same contract. Each
worker in a cluster owns its own slab, so no region is shared between threads.

## Capacity presets and the builder

`ServerConfig`, `Presets`, and `Server.builder` replace byte arithmetic with
named limits:

```zig
var server = try uz.Server.builder(init.io)
    .preset(uz.Presets.microservice)
    .with_max_body_size(256 * 1024)
    .build(std.heap.page_allocator);
defer server.deinit();
```

| Preset | Connections | WebSocket message | Write queue | Request body |
| --- | ---: | ---: | ---: | ---: |
| `Presets.microservice` | 256 | 8 KiB | 16 KiB | 64 KiB |
| `Presets.websocket_chat` | 512 | 32 KiB | 32 KiB | 4 KiB |
| `Presets.file_server` | 128 | 4 KiB | 512 KiB | 8 KiB |

Capacities stay compile-time because they size the generated application type;
pass literals or `const` values. `ServerConfig.slab_bytes()` and
`Server.builder(...).slab_bytes()` report the exact footprint before allocation. The libxev
event loop allocates its fixed 4096-entry backend table during `build`,
independently of application capacity.

Each embedded HTTP/2 session (eight streams with request, body, and response
storage) dominates the per-connection footprint. Presets therefore spend bytes
on the capacity each workload actually exercises instead of maximizing every
dimension. `max_body_size` sizes the HTTP/1.1 request buffers; HTTP/2 stream
bodies and HTTP/3 request bodies stay bounded by their compiled 16 KiB
transport slabs.

## Structure of arrays

Large collections are stored as parallel arrays so hot scans touch only the
fields they need:

- **Connection pool** (`src/core/pool.zig`): one contiguous `TcpConnection`
  slab plus a freelist index stack and a `StaticBitSet` activity bitmap. Acquire
  and release are O(1) and range-checked; `from_slices` adopts caller-carved
  storage without owning it.
- **Router** (`src/router/radix.zig`): parallel arrays for node segments,
  child/sibling links, route bits, method handlers, and WebSocket behaviors.
  Exact routes stay on the radix fast path; parameterized and wildcard matches
  live in bounded side tables.
- **HTTP/2 session** (`src/http2/server.zig`): per-stream arrays for request
  metadata, body lengths, pending offsets, and flags, plus connection-wide
  HPACK dynamic-table and decoded-header storage.
- **Cluster inbox** (`src/router/cluster.zig`): topic, payload, length, and flag
  arrays with a sequence ring; only the sequence words are atomic, and the ring
  positions sit on separate cache lines.
- **JSON-RPC registry** (`src/rpc/json_rpc.zig`): procedure metadata in
  parallel arrays with an open-addressed index and contiguous copied method
  bytes.
- **Query and form pairs** (`src/http/query.zig`): key and value pointers plus
  their lengths live in four parallel fixed arrays (32 entries), so every slice
  stays borrowed from the request target and `Request.query_params()` performs
  no copy and no allocation.

## Capacity and protocol limits

The defaults are deliberately finite:

| Resource | Limit |
| --- | ---: |
| Request line | 8 KiB |
| HTTP headers | 16 KiB total, 64 fields |
| Query and form pairs | 32 default; compile-time `query.QueryParamsOf` capacity |
| HTTP request body | 16 KiB default; `ServerConfig.max_body_size` |
| Routes | 256 radix nodes |
| Parameterized routes | 64 patterns, 16 captures per request |
| Middleware | 32 callbacks |
| OpenAPI route registry | 320 entries, 64 KiB of paths |
| JSON-RPC procedures | 64 by default |
| JSON-RPC method names | 4 KiB copied storage by default |
| JSON-RPC response | 16 KiB by default |
| Mounted static directories | 8 |
| Static file body | configured write queue minus 4 KiB |
| Cluster message queue | 64 messages per worker |
| Route path | 2 KiB |
| WebSocket message | 16 KiB with `App` |
| WebSocket control payload | 125 bytes |
| HTTP/3 decoded headers | 16 KiB total, 64 fields |
| HTTP/3 request body | 16 KiB |
| HTTP/3 response metadata | 4 KiB, 64 fields |
| HTTP/3 response body | configured write-queue capacity |
| QUIC UDP payload | 2 KiB |
| QUIC connections and active streams | configured connection capacity |
| HTTP/2 active streams | caller-selected compile-time slab capacity |
| HPACK table, fields, and decoded bytes | caller-owned capacities |
| C ABI | 1,024 connections, 64 copied route paths |
| Write queue | fixed per connection |
| Idle timeout | 120 seconds by default |

Oversized or ambiguous input is rejected rather than expanded dynamically.

## Backpressure

Response bytes enter a per-connection bounded ring. A fully drained ring
normalizes its head so the next logical write stays contiguous instead of
creating a delayed-ACK wrap split. Producers observe `error.WouldBlock`
instead of causing unbounded memory growth; WebSocket routes use the `drain`
callback and `buffered_amount` to resume producers. Chunk headers, bodies, and
terminators are copied into the same ring as parts, so chunked responses need no
per-connection scratch. HTTP/1.1 heads are scatter-written the same way, so a
response with thousands of header fields is bounded by the ring, not by a fixed
header-formatting buffer; `with_write_queue_size` sizes that ring per server.

## DX rejection documents

Oversized input returns structured JSON instead of a silently dropped
connection. The transport reads a fixed `RejectionPolicy` from the connection's
application, formats the document into a 384-byte stack buffer, and writes it
through the normal bounded response path:

```json
{"error":{"code":"payload_too_large","message":"Request body exceeded the 64KB limit. Consider increasing 'max_body_size' in ServerConfig.","limit_bytes":65536}}
```

Oversized headers return the equivalent `431` document. Neither path allocates,
and neither requires the handler to be involved.
