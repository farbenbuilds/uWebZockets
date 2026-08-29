# µWebZockets Examples

Build the supported examples with Zig 0.16.0 and all recursive submodules:

```sh
zig build -Doptimize=ReleaseSafe
```

The default install contains `hello_world`, `chat_server`, `h1spec`, and
`autobahn_server` under `zig-out/bin`.

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

## Compliance targets

`autobahn_server` listens on port 9001 and accepts a 16 MiB echo message for
the external Autobahn fuzzing client. `h1spec` listens on port 8000 for the
vendored HTTP/1.1 suite. Use the GitHub workflows or the commands documented in
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md) so readiness checks and report gates
are applied consistently.

## HTTP/3 status

`http3_server.zig` is retained only as an explicit unavailable-feature target.
Running `zig build http3_server` returns `error.Http3NotImplemented`. The Zig
transport is a fail-closed stub with no raw callbacks; the lsquic vendor archive
is built only to keep dependency integration tested.
