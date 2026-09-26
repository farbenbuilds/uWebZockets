# HTTP/2

µWebZockets embeds a bounded HTTP/2 server session in every TCP connection.
Requests decoded from HTTP/2 run through the same router, middleware, and
handlers as HTTP/1.1; see [http.md](http.md) for the application surface.

## Starting HTTP/2

| Path | Mechanism |
| --- | --- |
| TLS | ALPN selects `h2` ahead of `http/1.1` (`init_https`, `init_https_ephemeral`) |
| Plaintext | Prior knowledge: a client that opens with the HTTP/2 connection preface is detected before HTTP/1.1 parsing |

h2c Upgrade (RFC 7540 section 3.2) is not implemented. RFC 9113 removed the
Upgrade mechanism; prior knowledge is the standard cleartext path, and TLS ALPN
is the standard encrypted one.

## What the session implements

- Strict client preface, frame size, and frame sequencing validation.
- SETTINGS negotiation, PING, GOAWAY, and RST_STREAM.
- Stream lifecycle with an eight-stream request, body, response, and
  async-token slab carved from the startup allocation.
- Partial DATA and trailers.
- Connection-level and stream-level flow control.
- Async response tokens and drain-driven producers, exactly as on HTTP/1.1.

No dynamic allocation happens on the steady-state path. `uz.http2` also exposes
the frame and connection primitives directly, and `uz.http2_hpack` exposes a
bounded HPACK decoder/encoder with caller-owned dynamic-table, header, and byte
storage, including Huffman and pseudo-header validation.

## RFC 8441 WebSocket tunneling

Extended CONNECT (`:protocol = websocket`) is supported. Because parsing and
message storage are connection-owned, each connection permits one active tunnel;
additional tunnels receive `503 Service Unavailable` without disturbing the
active one.

## Capacities

The stream count is fixed at eight concurrent streams per connection. Per-stream
metadata follows `ServerConfig`:

- `with_max_h2_header_block_size`
- `with_max_h2_body_size`
- `with_max_h2_response_header_size`
- `with_max_h2_response_header_count`

Oversized input is rejected with a structured error rather than a dropped
connection. Raising the concurrent stream count requires specializing the
connection type and is tracked in [roadmap.md](roadmap.md).

## Observability

HTTP/2 dispatch emits one `http_request` development-log record per completed
exchange and advances the `uwz_http_requests` counter, matching HTTP/1.1.
Records are emitted at response completion, never per frame or per DATA chunk.
WebSocket tunnels record the upgrade response when the tunnel is established.

## Verification

The HTTP/2 unit suite covers frame sequencing, settings, flow control, HPACK
vectors, stream reuse, async completion, producer output, and malformed input.
The HTTP/1.1 and HTTP/3 compliance gates run against the same handlers, so the
shared application boundary is exercised from three wire formats.
