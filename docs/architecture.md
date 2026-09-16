# Architecture

µWebZockets is a transport-agnostic Zig 0.16.0 server library built around one
idea: every byte of I/O and protocol state lives in a bounded, startup-allocated
slab, and no thread ever touches another thread's slab. This document covers the
runtime architecture. See [memory_model.md](memory_model.md) for allocation and
capacity details and [protocols.md](protocols.md) for wire behavior.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are small functions with explicit input and output
   state. Stateful I/O stays localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. Non-blocking I/O (epoll, io_uring, kqueue, and IOCP via libxev) drives
   callbacks. CMake and Ninja build the vendored C and C++ libraries with Zig
   compiler wrappers.
5. WebSocket masking operates on native SIMD vectors before handling the
   scalar tail.
6. Cross-thread data movement is lock-free. Producer and consumer state occupy
   separate cache lines.

## Shared-nothing workers

`App.cluster(worker_count)` builds a thread-per-core group. Each worker:

- allocates its own contiguous slab (pool, request buffers, WebSocket message
  regions, response write queues, optional compression scratch);
- runs its own `libxev` event loop on its own thread;
- binds the shared port with `SO_REUSEPORT`, letting the kernel load-balance
  incoming connections across listeners;
- is pinned to a distinct physical core where the platform provides a
  hard-affinity API.

No connection state, request buffer, queue, or completion is shared between
workers. An accepted connection lands wholly inside the accepting worker's slab
and is only ever touched by that worker's event loop.

```text
               SO_REUSEPORT
                    |
     +--------------+--------------+
     |              |              |
     v              v              v
 worker 0       worker 1       worker 2        (one OS thread each)
 loop + slab    loop + slab    loop + slab
 pinned CPU 0   pinned CPU 1   pinned CPU 2
     |              |              |
     +------ lock-free inbox ------+          (cross-worker publish only)
```

### CPU affinity

`src/core/affinity.zig` selects one representative CPU per physical core:

- Linux reads `sched_getaffinity` for the allowed set, then
  `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list` to skip SMT
  siblings. Worker `i` is pinned with `sched_setaffinity`.
- Windows reads the process affinity mask and calls `SetThreadAffinityMask`.
- Other platforms report `error.UnsupportedPlatform` and continue unpinned;
  macOS has no hard-affinity API.

Pinning is best effort. A restricted cpuset or a failed syscall logs once and
leaves the worker unpinned rather than refusing startup. Extra workers beyond
the physical core count wrap over the selection instead of floating freely.

### Lock-free coordination

Cross-worker publish uses a bounded Vyukov sequence ring per worker inbox
(`src/router/cluster.zig`). Any worker thread may publish; only the owning
worker consumes on its event loop. The queue is allocation-free, reports
`error.ClusterQueueFull` instead of blocking, and keeps the enqueue and dequeue
positions on separate cache lines to avoid false sharing.

After removing the former spinlock, no mutex or spinlock remains on the
steady-state I/O path. The only lock left in the tree is lsquic's process-wide
initialization reference in `src/quic/lsquic_api.zig`, which is touched before
the first listener starts and after the last one drains.

### TCP tuning

Listeners and accepted sockets are tuned per platform:

- Linux listeners set `TCP_DEFER_ACCEPT` so the event loop is not woken by the
  three-way handshake alone; it wakes on the first application byte.
- Linux accepted sockets request `TCP_QUICKACK` once at accept, removing the
  initial delayed-ACK stall without adding a syscall to the read path. The flag
  is one-shot by design, so throughput-sensitive deployments keep it confined
  to connection setup.
- Other kernels keep their default accept and ACK policy.

### Windows fallback

Windows IOCP already multiplexes completions across threads and has no
`SO_REUSEPORT`. In cluster mode every worker binds the shared address with
`SO_REUSEADDR` instead. Each accepted connection still lands wholly inside the
accepting worker's slab, so routing stays safe; kernel distribution across
listeners is unspecified and the Windows cluster is documented as a graceful
fallback rather than a load-balancing path. Affinity uses the native
`SetThreadAffinityMask` call.

## Runtime data flow

```text
libxev accept/read
      |
      v
fixed connection slot ----> optional bounded TLS BIO pair
      |
      v
HTTP request accumulator --> strict parser --> middleware --> radix route
                                      |                       |
                                      |                       +--> bounded HTTP writer
                                      |                       +--> one-shot async token
                                      v
                             WebSocket upgrade
                                      |
                                      v
                          zslay frame state machine
                                      |
                     SIMD unmask + streaming UTF-8
                                      |
                                      v
                         callback / bounded pub-sub

UDP read/timer --> lsquic engine --> bounded QPACK header set --> same router
                                   |                           |
                                   v                           v
                            bounded body slab          structured H3 response
```

## Event loop and completions

`src/core/loop.zig` wraps one libxev loop with 4096 completion entries and runs
it `.until_done`. All completions are inline members of their owning connection,
server, transport, or engine; none is heap-allocated, and none outlives the
storage it borrows. Only `loop.zig` inspects the libxev backend; every other
module cancels through the backend-aware shim.

A closed pool slot returns to the freelist only through
`release_closed_connection` after close, read, write, and cancellation
completions have all drained. That gate prevents a stale completion from
observing a reused connection.

## Transports

### TCP, TLS, and HTTP/1.1

Plaintext sockets detect the HTTP/2 prior-knowledge preface before parsing
HTTP/1.1. TLS uses BoringSSL with ALPN preference `h2` then `http/1.1`.
Request bytes accumulate in the connection's bounded request buffer, the strict
parser proves completeness, and the router dispatches through middleware to a
handler.

### HTTP/2

`src/core/tcp.zig` embeds one eight-stream server session per connection and
routes decoded requests through the same middleware and sync/async handlers as
HTTP/1.1. The session owns its HPACK table, per-stream request/body/response
storage, and async tokens. SETTINGS, PING, GOAWAY, RST_STREAM, trailers,
partial DATA, and connection/stream flow control are handled without dynamic
allocation. RFC 8441 WebSocket tunneling is supported through extended CONNECT;
one connection permits one active tunnel.

### HTTP/3

`init_http3` creates isolated TLS 1.3 contexts so TCP advertises `h2` and
`http/1.1` while QUIC advertises only `h3`. The adapter decodes HTTP/3
pseudo-headers directly into the existing `Request` shape and writes structured
QPACK response headers without converting through HTTP/1.1 text. QUIC
connections, streams, header sets, packet buffers, and bodies come from
startup-allocated contiguous pools. The live listener rejects TLS 0-RTT so
replayable requests never reach a handler.

### Edge and kernel bypass

- `src/core/transport.zig` exposes a protocol-only core and a generic adapter
  driver used by the WASM edge builds.
- `wasm32-freestanding` exports linear memory for V8 isolate hosts;
  `wasm32-wasi` exports bounded `alloc`/`free` and generation-checked handles.
- `src/core/ktls.zig` configures Linux kTLS and offers zero-copy
  `sendfile`/`splice` helpers.
- `src/xdp/socket.zig` implements AF_XDP UMEM ownership rings, and the `ebpf`
  build step emits the XDP redirect object. Attaching it and populating its XSK
  map requires network-administration privileges.

## Shutdown ordering

Shutdown reverses the ownership graph deterministically:

1. Reject new work and mark the application unavailable.
2. Stop recurring timers, close the listener, and shut down the UDP/QUIC
   transport.
3. Cancel every connection completion and run the loop until all completions
   are disarmed.
4. Verify drained state: no active pool slots, a completed listener close, and
   an empty QUIC transport.
5. Release TLS state, QUIC state, the loop, and the slab through the original
   allocator.

`deinit` asserts drained state instead of guessing and panics if called from
inside the event loop.
