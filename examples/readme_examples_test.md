# µWebZockets 1.3.0 Examples

Build the supported examples with Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseSafe
```

The default install contains `hello_world`, `chat_server`, `rpc_server`,
`http3_server`, `basic_microservice`, `custom_builder`, `dev_log_server`,
`shared_nothing_cluster`, `h1spec`, and `autobahn_server` under `zig-out/bin`.

These examples target the live `App` transports. The bounded HTTP/2/HPACK
components and the C ABI header are library surfaces rather than standalone
example servers.

## HTTP/1.1 server

Start the server:

```sh
./zig-out/bin/hello_world
```

Verify it from another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The expected result is `HTTP/1.1 200 OK` and the body `Hello from
µWebZockets! Zero allocation achieved.`

The equivalent build-and-run step is:

```sh
zig build hello_world -Doptimize=ReleaseSafe
```

## WebSocket pub/sub server

Start the server:

```sh
./zig-out/bin/chat_server
```

Connect two clients to the same bounded topic:

```sh
npx wscat -c ws://127.0.0.1:3000/chat
```

Text or binary messages sent by either client are published to the `global`
topic. The example reports subscription failure instead of silently continuing
when fixed pub/sub capacity is exhausted.

Message bytes are borrowed only until the callback returns. Copy into
application-owned bounded storage if work must outlive that callback.

The equivalent build-and-run step is:

```sh
zig build chat_server -Doptimize=ReleaseSafe
```

## JSON-RPC server

Start the typed JSON-RPC example:

```sh
./zig-out/bin/rpc_server
```

Call its `math.add` procedure from another terminal:

```sh
curl http://127.0.0.1:3000/rpc \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"math.add","params":{"left":2,"right":3},"id":1}'
```

The expected response is
`{"jsonrpc":"2.0","result":{"sum":5},"id":1}`. The equivalent
build-and-run step is:

```sh
zig build rpc_server -Doptimize=ReleaseSafe
```

## Terminal development log

Start the dev-log server:

```sh
zig build dev_log_server -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/
curl -i http://127.0.0.1:3000/snapshot
curl -i http://127.0.0.1:3000/metrics
npx wscat -c ws://127.0.0.1:3000/echo
```

The server prints the `µWEBZOCKETS` wordmark before the listening line,
followed by a blank line (a one-line `µWebZockets` mark fits narrow terminals),
and logs each request Vite-style as `HH:MM:SS | [METHOD] /path : STATUS` with a
dim clock, cyan method, and status-class color, alongside colored connection,
WebSocket, and metric lines. `/snapshot` records every Prometheus counter into
the same log and `/metrics` serves the registry. Each worker thread renders and
writes records through its own `dev_log.Sink` as soon as they are recorded, so
the event loop never allocates; `App.set_dev_log_file` redirects the output and
`ServerConfig.enable_dev_log` silences it.

## Capacity presets and custom builder

Start the microservice preset server on port 3000:

```sh
zig build basic_microservice -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/health
curl -i -X POST http://127.0.0.1:3000/echo -d '{"ping":true}'
```

The custom builder example on port 3001 reserves a 50 MiB request buffer per
connection inside one contiguous startup slab, prints the slab size, and
answers a body above the configured limit with a structured `413` document:

```sh
zig build custom_builder -Doptimize=ReleaseSafe
head -c 52428801 /dev/zero | curl -i -X POST http://127.0.0.1:3001/upload --data-binary @-
```

## Shared-nothing cluster

Start four workers that share one port through `SO_REUSEPORT`, each with its
own event loop, slabs, and pinned core where the platform allows it:

```sh
zig build shared_nothing_cluster -Doptimize=ReleaseSafe
```

```sh
curl -i http://127.0.0.1:3000/
```

The kernel load-balances accepted connections across the listeners, and every
connection stays inside the accepting worker's slab. See
[docs/architecture.md](../docs/architecture.md) for the affinity and tuning
details.

## Compliance targets

`autobahn_server` listens on port 9001 and accepts a 16 MiB echo message for
the external Autobahn fuzzing client. `h1spec` listens on port 8000 for the
vendored HTTP/1.1 suite. Use the GitHub workflows or the commands documented in
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md) so readiness checks and report gates
are applied consistently.

## HTTP/3 server

Place a PEM certificate and matching private key at `certs/cert.pem` and
`certs/key.pem`, then build and start the bounded lsquic server:

```sh
zig build http3_server -Doptimize=ReleaseSafe
./zig-out/bin/http3_server
```

The server listens for QUIC on UDP port 8443 and routes `GET /` through the
same `Request` and `Response` API as HTTP/1.1. A client with HTTP/3 support can
request `https://127.0.0.1:8443/`; configure trust appropriately for a local
self-signed certificate.

The example uses a capacity of 128 connections/active streams. QPACK headers,
request bodies, response metadata, response bodies, and outgoing UDP packets
all use fixed startup-allocated pools. The UDP socket, timer, cancellation, and
close completions are owned by `src/core/udp.zig` and drain before application
storage is released.

The live example serves bounded HTTP/3 request/response streams and rejects
extended CONNECT. RFC 9220 and WebTransport draft-16 validators and wire
helpers are Zig library surfaces only; they are not connected to the lsquic
listener. The HTTP/3 compliance gate exercises standard HTTP/3
request/response routing.
