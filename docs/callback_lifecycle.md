# Callback life cycle

This page is the registration-to-handler map for every asynchronous entry
point in the native runtime. It complements [architecture.md](architecture.md)
(data flow and shutdown ordering), [memory_model.md](memory_model.md) (storage
ownership), and [protocols.md](protocols.md) (wire behavior) without repeating
them.

References are `file:line` against the current tree and move with the code.
Native libxev completion callbacks return `xev.CallbackAction`; callbacks
registered with C interfaces or invoked by a handler keep their own
signatures, noted at each entry point. The completion a libxev callback
receives is an inline field of the owning connection, server, timer, or
transport. `.rearm` keeps an operation registered; `.disarm` leaves re-arming
or cancellation to the handler. Every cancellation routes through
`core_loop.cancel` (`src/core/loop.zig:14`), which synthesizes the completion
on kqueue and IOCP instead of calling the backend directly.

## TCP accept path

- `AcceptCallback` (`src/core/tcp.zig:1453`) is the listener connection
  callback type. `init_server` (`src/core/tcp.zig:1468`) and
  `init_reuse_port_server` (`src/core/tcp.zig:1473`) store the callback passed
  by `App.listen` (`src/router/app.zig:883`) and `App.listen_reuse_port`
  (`src/router/app.zig:1111`) as `on_new_connection`
  (`src/router/app.zig:785`).
- `on_accept_complete` (`src/core/tcp.zig:1625`) is registered by
  `accept_start` (`src/core/tcp.zig:1574`) at `src/core/tcp.zig:1576`.
  Signature: `xev.AcceptError!xev.TCP` result plus `xev.CallbackAction`.
  Driven by a completed accept. It calls `server.on_connection`
  (`src/core/tcp.zig:1647`) and returns `.rearm`.
- `on_new_connection` (`src/router/app.zig:785`) acquires a pool slot
  (`src/router/app.zig:791`), resets protocol state
  (`src/router/app.zig:799`), attaches TLS (`src/router/app.zig:870`), and
  arms the first read (`src/router/app.zig:875`). Driven by the accept
  callback above.
- `on_accept_cancel_complete` (`src/core/tcp.zig:1613`) is registered by
  `close_server` (`src/core/tcp.zig:1586`) through `core_loop.cancel`
  (`src/core/tcp.zig:1590`). Driven by shutdown cancellation of accept.
- `on_server_close_complete` (`src/core/tcp.zig:1651`) is registered at
  `src/core/tcp.zig:1604` by `close_server`. It sets the flag
  `App.verify_shutdown` (`src/router/app.zig:424`) waits on. Driven by the
  listener close completion.

## TCP read, TLS, and dispatch

- `on_read_complete` (`src/core/tcp.zig:1137`) is registered by `arm_read`
  (`src/core/tcp.zig:831`) at `src/core/tcp.zig:834`. Signature:
  `xev.ReadError!usize` plus the read buffer. Driven by a readable socket; it
  returns `.rearm` (`src/core/tcp.zig:1189`) unless dispatch is suspended or
  the connection is closing.
- `read_start` (`src/core/tcp.zig:1132`) is the bootstrap called after pool
  acquire; it stores the loop and calls `arm_read`.
- `on_read_complete` calls `process_tls_data` (`src/core/tcp.zig:1178`) when
  TLS is attached, otherwise `route_decrypted_data`
  (`src/core/tcp.zig:1180`).
- `process_tls_data` (`src/core/tcp.zig:194`) drives the handshake
  `drive_tls_handshake` (`src/core/tcp.zig:223`) and then
  `drain_tls_plaintext` (`src/core/tcp.zig:253`); the drain loop feeds
  `route_decrypted_data` at `src/core/tcp.zig:260`.
- `route_decrypted_data` (`src/core/tcp.zig:279`) selects HTTP/1
  `route_http_data` (`src/core/tcp.zig:578`), HTTP/2 `route_http2_data`
  (`src/core/tcp.zig:313`), or `WebSocket.on_data` (`src/ws/socket.zig:239`).
- HTTP/2 runs synchronously inside the read callback: `route_http2_data`
  calls `h2.receive` (`src/core/tcp.zig:315`), whose entries come from
  `http2_callbacks` (`src/core/tcp.zig:322`): `write_http2_parts`
  (`src/core/tcp.zig:345`), `dispatch_http2_request`
  (`src/core/tcp.zig:365`), `ws_http2_data` (`src/core/tcp.zig:350`), and
  `close_http2_stream` (`src/core/tcp.zig:336`).
- `resume_async_dispatch` (`src/core/tcp.zig:789`) re-enters `route_http_data`
  and can call `drain_tls_plaintext` (`src/core/tcp.zig:821`) before re-arming
  the read.

## TCP write path and file body

- `on_write_complete` (`src/core/tcp.zig:1192`) is registered by `start_write`
  (`src/core/tcp.zig:1008`) at `src/core/tcp.zig:1014`. Signature:
  `xev.WriteError!usize`. Driven by a writable socket.
- The handler advances the write ring and then calls `flush_tls_out`
  (`src/core/tcp.zig:1239`), `drive_tls_handshake`
  (`src/core/tcp.zig:1245`), `h2.flush_pending` (`src/core/tcp.zig:1252`),
  `WebSocket.notify_drain` (`src/core/tcp.zig:1260`),
  `tcp_file.pump_file_body` (`src/core/tcp.zig:1268`), and `start_write`
  (`src/core/tcp.zig:1269`).
- `pump_file_body` (`src/core/tcp_file.zig:54`) streams the response file at
  the kernel boundary; `dribble_file_body` (`src/core/tcp_file.zig:107`) is
  the bounded copy fallback and `finish_file_body`
  (`src/core/tcp_file.zig:32`) releases the handle and resumes dispatch.
  There is no file-body timer: each write completion is the pulse.

## TCP close and pool release

- `close_connection` (`src/core/tcp.zig:1301`) is idempotent teardown. It
  aborts the connection signal (`src/core/tcp.zig:1304`), cancels async
  tokens (`src/core/tcp.zig:1310`), releases file and TLS state
  (`src/core/tcp.zig:1314`, `src/core/tcp.zig:1315`), cancels read and write
  through `core_loop.cancel` (`src/core/tcp.zig:1325`,
  `src/core/tcp.zig:1336`), and submits `socket.close`
  (`src/core/tcp.zig:1358`) with the inline close callback
  (`src/core/tcp.zig:1364`). Windows closes synchronously and releases
  immediately (`src/core/tcp.zig:1347`).
- `on_read_cancel_complete` (`src/core/tcp.zig:1396`) and
  `on_write_cancel_complete` (`src/core/tcp.zig:1411`) clear their cancel
  flags and re-run the release gate. Driven by the cancellation completions.
- `release_closed_connection` (`src/core/tcp.zig:1427`) is the only path back
  to the freelist. Once close, read, write, and cancel flags are clear it
  invokes `on_close_cb` (`src/core/tcp.zig:1449`), the pool release closure
  installed at `src/router/app.zig:862`.
- `close_after_flush` (`src/core/tcp.zig:1286`) is the graceful variant: it
  starts the TLS shutdown and closes only when queued bytes drain.

## Timers

- `connection_sweeper` (`src/core/timer.zig:110`) is the periodic idle and
  WebSocket heartbeat sweep. `start` (`src/core/timer.zig:142`) registers
  `on_tick` (`src/core/timer.zig:174`) at `src/core/timer.zig:146`; the tick
  advances `WebSocket.heartbeat_tick` (`src/core/timer.zig:197`), closes idle
  connections through `tcp.close_connection` (`src/core/timer.zig:205`), and
  re-arms a fresh relative timeout (`src/core/timer.zig:212`). `stop`
  (`src/core/timer.zig:157`) cancels into `on_cancel`
  (`src/core/timer.zig:217`). Started by `App.listen`
  (`src/router/app.zig:897`) and `App.listen_reuse_port`
  (`src/router/app.zig:1121`); stopped by `App.begin_shutdown`
  (`src/router/app.zig:406`).
- `TimerContext` (`src/core/timer.zig:7`) is the generic repeating timer; its
  callback type is `*const fn () void` (`src/core/timer.zig:12`).
  `start_timer` (`src/core/timer.zig:33`) registers `on_timer_tick`
  (`src/core/timer.zig:64`) and `stop_timer` (`src/core/timer.zig:47`)
  cancels into `on_timer_cancel` (`src/core/timer.zig:91`). No production path
  uses it yet; tests exercise it from `src/tests/core_tests.zig`.
- Cross-worker wakeup: `App.arm_cluster_wakeup` (`src/router/app.zig:1130`)
  submits `xev.Async.wait` (`src/router/app.zig:1134`) with
  `on_cluster_wakeup` (`src/router/app.zig:1153`), which drains the cluster
  inbox and re-arms (`src/router/app.zig:1179`). Driven by `notify_cluster`
  (`src/router/app.zig:1143`) from any worker.
- `abort_if_expired` (`src/http/abort.zig:101`) converts a monotonic deadline
  into a cooperative abort. It is a helper for callers that own a clock; no
  runtime timer currently drives it.
- The QUIC deadline timer is in the UDP/QUIC section below.

## Async response completion

- `AsyncResponseState.arm` (`src/http/response.zig:69`) stores an
  `AsyncTarget` (`src/http/response.zig:43`) whose `complete_fn` and `wake_fn`
  pointer types are declared at `src/http/response.zig:45` and
  `src/http/response.zig:46`.
- HTTP/1: `invoke_handler` (`src/core/tcp.zig:727`) arms
  `async_response_state` at `src/core/tcp.zig:738` and
  `src/core/tcp.zig:743` with `async_target` (`src/core/tcp.zig:760`), pairing
  `complete_async_response` (`src/core/tcp.zig:768`) with
  `wake_async_dispatch` (`src/core/tcp.zig:783`).
- HTTP/2: `arm_http2_async` (`src/core/tcp.zig:531`) arms one slot per stream
  at `src/core/tcp.zig:541`, pairing `complete_http2_async_response`
  (`src/core/tcp.zig:548`) with `wake_http2_async_response`
  (`src/core/tcp.zig:574`); the wake is intentionally empty because HTTP/2
  reads stay armed.
- `AsyncResponse.complete_with_headers` (`src/http/response.zig:110`) checks
  the generation, calls `complete_fn` (`src/http/response.zig:124`), then
  `wake_fn` (`src/http/response.zig:132`). Driven by application code on the
  owning event loop; cross-thread completion must be marshalled first.
- `wake_async_dispatch` calls `resume_async_dispatch`
  (`src/core/tcp.zig:789`), which restores dispatch and re-arms the read.
  Cancellation is generation-based: `close_connection`
  (`src/core/tcp.zig:1310`) cancels the HTTP/1 slot and all HTTP/2 slots,
  `reset_protocol` (`src/core/tcp.zig:135`) resets the HTTP/2 slots, and pool
  acquire cancels the HTTP/1 slot (`src/router/app.zig:828`).

## UDP and QUIC

- `quic_transport.start` (`src/core/udp.zig:100`) arms the receive completion
  `on_read` (`src/core/udp.zig:166`) at `src/core/udp.zig:113` and the engine
  timer at `src/core/udp.zig:122`. Driven by a readable UDP socket.
- `on_read` feeds `engine.process_datagram` (`src/core/udp.zig:187`); a
  handler that starts shutdown mid-datagram leaves the completion disarmed.
- `quic_transport.close_socket` (`src/core/udp.zig:195`) cancels receive
  (`src/core/udp.zig:204` into `on_read_cancel`, `src/core/udp.zig:231`) and
  closes the socket (`src/core/udp.zig:222` into `on_close`,
  `src/core/udp.zig:245`). Windows closes synchronously
  (`src/core/udp.zig:214`).
- Engine timer: `start_timer` (`src/core/udp.zig:263`) registers `on_timer`
  (`src/core/udp.zig:291`) at `src/core/udp.zig:267`; the tick calls
  `engine.process` (`src/core/udp.zig:306`) and re-arms with
  `engine.next_timeout_ms` (`src/core/udp.zig:310`). `stop_timer`
  (`src/core/udp.zig:277`) cancels into `on_timer_cancel`
  (`src/core/udp.zig:321`). Driven by the lsquic earliest-advance tick
  (`src/quic/engine.zig:308`).
- lsquic interfaces are registered once by `engine.start`
  (`src/quic/engine.zig:154`): stream callbacks at
  `src/quic/engine.zig:185`, header-set callbacks at
  `src/quic/engine.zig:194`, packet-memory callbacks at
  `src/quic/engine.zig:200`, and the engine API at
  `src/quic/engine.zig:204`. lsquic invokes all of them synchronously from
  `process_datagram` (`src/quic/engine.zig:244`) and `process`
  (`src/quic/engine.zig:265`), never from a completion.
- Stream entry points: `on_new_connection` (`src/quic/engine.zig:358`),
  `on_connection_closed` (`src/quic/engine.zig:369`), `on_new_stream`
  (`src/quic/engine.zig:377`), `on_stream_read` (`src/quic/engine.zig:388`),
  `on_stream_write` (`src/quic/engine.zig:393`), `on_stream_close`
  (`src/quic/engine.zig:398`), and `on_header_set_available`
  (`src/quic/engine.zig:403`). All use `callconv(.c)` and forward to
  `QuicStream` methods.
- Header and packet hooks: `create_header_set` (`src/quic/engine.zig:417`),
  `prepare_header_decode` (`src/quic/engine.zig:432`), `process_header`
  (`src/quic/engine.zig:441`), `discard_header_set`
  (`src/quic/engine.zig:446`), `allocate_packet` (`src/quic/engine.zig:468`),
  and `release_packet` (`src/quic/engine.zig:481`).
- Transmit boundary: `packets_out` (`src/quic/engine.zig:451`) calls
  `api.send_packets` (`src/quic/engine.zig:457`), implemented at
  `src/quic/lsquic_api.zig:94` as a synchronous non-blocking send on the
  engine UDP socket; it queues no completion. `src/quic/lsquic_shim.c` only
  pins C struct layout ABI.

## Server lifecycle

- Startup: `App.init` creates the loop with `core_loop.init`
  (`src/router/app.zig:216`). `App.listen` and `App.listen_reuse_port` bind
  and call `accept_start` (`src/router/app.zig:895`,
  `src/router/app.zig:1120`); `App.listen_udp` starts the QUIC transport
  (`src/router/app.zig:920`).
- Run: `App.run` (`src/router/app.zig:930`) arms the cluster wakeup
  (`src/router/app.zig:936`) and enters `core_loop.run`
  (`src/router/app.zig:937`), which drives libxev `.until_done`
  (`src/core/loop.zig:78`).
- Shutdown request: `App.begin_shutdown` (`src/router/app.zig:399`) stops the
  sweeper (`src/router/app.zig:406`), closes the listener
  (`src/router/app.zig:407`), shuts the QUIC transport down
  (`src/router/app.zig:408`), and calls `close_connection` for every active
  pool slot (`src/router/app.zig:412`).
- Drain: `App.drive_shutdown` (`src/router/app.zig:416`) runs the loop until
  every cancellation and close completion disarms, then
  `App.verify_shutdown` (`src/router/app.zig:424`) requires an empty pool, a
  completed listener close, and a drained QUIC transport. `App.deinit`
  (`src/router/app.zig:327`) panics if called from inside the loop
  (`src/router/app.zig:330`) and frees through the original allocator.
- Cluster: `Cluster.run` (`src/router/app.zig:1063`) runs one `App` per worker
  thread and joins them; `request_cluster_shutdown`
  (`src/router/app.zig:1148`) notifies every worker through the async wakeup.

## TCP connection life cycle

```text
                 accept_start (tcp.zig:1574)
                        |
                        v
  listener.accept ---> on_accept_complete (tcp.zig:1625)
                        |
                        | server.on_connection
                        v
               on_new_connection (app.zig:785) ---> read_start (tcp.zig:1132)
                        |
                        v
  socket readable ---> on_read_complete (tcp.zig:1137)
                        |
          +-------------+-------------+
          | TLS                       | plaintext
          v                           v
  process_tls_data (tcp.zig:194)   route_decrypted_data (tcp.zig:279)
          |                           |
          +-------------+-------------+
                        v
         HTTP/1 route -> handler -> write_data_parts
         HTTP/2 receive -> dispatch
         WebSocket on_data
                        |
                        | start_write (tcp.zig:1008)
                        v
  socket writable --> on_write_complete (tcp.zig:1192)
                        |
                        | flush / pump_file_body / start_write
                        v
  close_after_flush (tcp.zig:1286) or close_connection (tcp.zig:1301)
                        |
                        | cancel read/write -> socket.close -> cancel and
                        | close callbacks
                        v
  release_closed_connection (tcp.zig:1427) -> on_close_cb -> pool.release
```

## Outside the native loop

`src/core/transport.zig` exposes `protocol_core` and `driver` for the WASM edge
builds: the host loop calls `driver.read` and `driver.write` directly, so those
builds register no libxev completions. The C ABI drives the same protocol core
through an `App` (`src/c_api/app.zig:259`).
