# uWebZockets Examples Testing Guide

This document outlines how to compile and test the provided example applications in `uWebZockets`.

## Build Instructions

All examples are built automatically when compiling the project. Ensure you are in the project root.

```bash
zig build -Doptimize=ReleaseFast
```

The compiled binaries will be placed in the `zig-out/bin/` directory.

## 1. HTTP/1.1 Server (`hello_world.zig`)

This is the standard, zero-allocation HTTP/1.1 server running on TCP port 3000.

**Start the server:**
```bash
./zig-out/bin/hello_world
```

**Test with curl:**
```bash
curl -i http://127.0.0.1:3000/
```

**Expected output:**
You should receive an HTTP/1.1 200 OK response with the body "Hello from uWebZockets! Zero allocation achieved."

## 2. WebSocket Pub/Sub Server (`chat_server.zig`)

This starts the WebSocket server on TCP port 3000 with a `/chat` endpoint. It leverages a zero-allocation pub/sub engine.

**Start the server:**
```bash
./zig-out/bin/chat_server
```

**Test with wscat (Recommended):**
WebSockets are persistent, two-way connections. `wscat` is the recommended tool for testing interactive broadcast channels.
```bash
# terminal 1
npx wscat -c ws://127.0.0.1:3000/chat

# terminal 2
npx wscat -c ws://127.0.0.1:3000/chat
```
When you type a message in terminal 1, it will instantly broadcast to terminal 2.

**Test with curl:**
Newer versions of curl (7.86.0+) have experimental WebSocket support. You can initiate the HTTP/1.1 Upgrade handshake manually:
```bash
curl -i \
     --no-buffer \
     --header "Connection: Upgrade" \
     --header "Upgrade: websocket" \
     --header "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
     --header "Sec-WebSocket-Version: 13" \
     http://127.0.0.1:3000/chat
```

## 3. QUIC / HTTP/3 Server (`http3_server.zig`)

This starts the HTTP/3 server over UDP port 8443.

HTTP/3 requires TLS. Before running this example, you must generate a local self-signed certificate in the `certs` directory.

**Generate TLS certificates:**
```bash
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem -sha256 -days 365 -nodes -subj "/CN=localhost"
```

**Start the server:**
```bash
./zig-out/bin/http3_server
```

**Test with curl:**
Your `curl` installation must be explicitly compiled with HTTP/3 support (e.g., via `quiche` or `ngtcp2`). Use the `--http3` flag and `-k` to bypass the self-signed certificate warning.

```bash
# test the index route
curl -k -i --http3 https://127.0.0.1:8443/

# test the simulated chunked video route
curl -k -i --http3 https://127.0.0.1:8443/video
```
