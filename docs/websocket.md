# WebSocket

µWebZockets implements RFC 6455 with RFC 7692 per-message deflate, a bounded
pub/sub layer, and RFC 8441 tunneling over HTTP/2.

## Registering a route

```zig
_ = try app.ws("/chat", .{
    .open = on_open,
    .message = on_message,
    .close = on_close,
    .drain = on_drain,
    .compression = .permessage_deflate,
    .ping_interval_ms = 30_000,
    .pong_timeout_ms = 10_000,
});
```

`App` defaults to 16 KiB WebSocket messages. `max_frame_size` and
`max_message_size` may lower that bound per route; `ConfiguredApp` raises the
compile-time connection count, message capacity, and write-queue capacity. A
route whose limits exceed the configured message capacity fails registration
with `500 Internal Server Error` rather than accepting a peer it cannot serve.

## Sending and backpressure

- `send` returns `error.WouldBlock` when bounded output storage is exhausted.
- `buffered_amount` reports the pending bytes; the `drain` callback resumes
  producers once the queue drains.
- Incoming `message` slices are valid only for the callback. Copy anything you
  need to keep.
- Outgoing text and close data are validated.
- `send_close` closes after the frame drains; `terminate` closes immediately.

## Compression

Compression is opt-in per route through `.compression = .permessage_deflate`.
Negotiation always selects `server_no_context_takeover` and
`client_no_context_takeover`, accepts window sizes 9 through 15 for server
output and 8 through 15 for client input, and rejects compressed expansion
beyond `max_message_size`. Enabling compression allocates paired receive and
send scratch per connection during route registration; message processing does
not allocate. Set `ServerConfig.compression = true` to reserve that scratch
inside the startup slab instead.

## Heartbeats and idle peers

Heartbeat-enabled routes reuse the connection sweeper: idle peers receive an
empty ping and are closed if the configured pong timeout expires. The default
idle timeout is 120 seconds, refreshed by successful reads and writes. Use
`ConfiguredAppWithTimeout` to select another compile-time timeout, or zero to
disable idle sweeping.

## Pub/sub

The bounded pub/sub engine is embedded directly in the application value.
Subscriptions are fixed-capacity; publishing never allocates and reports the
number of subscribers reached. `App.cluster` coordinates cross-worker publishes
through a bounded lock-free inbox per worker, and `Cluster.publish` broadcasts
to every worker. See [architecture.md](architecture.md) for the ring design.

## WebSocket over HTTP/2

RFC 8441 extended CONNECT is supported on HTTP/2. Because parsing and message
storage are connection-owned, each connection permits one active tunnel and
additional tunnels receive `503 Service Unavailable` without disturbing the
active one. See [http2.md](http2.md).

## Compliance

The bundled Autobahn runner executes all 517 selected server cases. The verified
baseline is 514 `OK` and 3 `INFORMATIONAL` results for both protocol and close
behavior. The strict gate accepts all 517 cases, including RFC 7692 groups 12
and 13, with no exclusions. Close-code handling, fragmentation, streaming
UTF-8 validation, and SIMD masking also have deterministic unit coverage.
