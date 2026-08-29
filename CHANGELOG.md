# Changelog

All notable changes to µWebZockets are documented in this file. The project
uses Semantic Versioning, with prerelease stability rules applying to alpha
versions.

## [Unreleased]

## [1.0.0-alpha] - 2026-08-30

### Added

- Added bounded `ConfiguredApp` storage for per-connection WebSocket messages
  and output queues.
- Added method-aware HTTP routes for GET, HEAD, POST, PUT, DELETE, PATCH,
  OPTIONS, and fallback handlers.
- Added query/path separation, duplicate-header inspection, HEAD fallback,
  automatic OPTIONS and `Allow`, `100 Continue`, and chunked responses.
- Added WebSocket upgrade authorization, frame/message limits, close handling,
  drain notification, buffered-byte reporting, streaming UTF-8 validation, and
  SIMD masking.
- Added HTTPS with BoringSSL TLS 1.3 and HTTP/1.1 ALPN.
- Added `ConfiguredAppWithTimeout`, a 120-second default idle policy, and the
  option to disable idle sweeping with a zero timeout.
- Added Autobahn and h1spec compliance servers and GitHub Actions workflows.
- Added bounded HTTP/zslay fuzz targets and a nightly/PR HTTP throughput
  regression workflow with a dedicated `Benchmarking` environment.
- Added Nix native/musl packages, six-target publishing, checksums, deployment
  environments, and third-party license packaging.

### Changed

- Updated zslay from 0.1.1 to 0.1.5 using the immutable v0.1.5 source archive.
- Migrated WebSocket parsing to zslay 0.1.5's role, frame-node, length-limit,
  and error APIs.
- Reworked connection ownership into a contiguous slab with an activity bitmap
  and deterministic release.
- Reworked routing as fixed-capacity parallel arrays and made duplicate,
  invalid, or excessive routes return errors.
- Reworked TCP and TLS writes to preserve partial writes in bounded queues and
  signal backpressure.
- Reworked pub/sub to own bounded topic names and remove stale subscribers.
- Mapped Zig optimization modes and target triples into isolated CMake/Ninja
  builds for BoringSSL, lsquic, and libdeflate.
- Pinned Nixpkgs 26.05 so GNU/Linux, musl/Linux, Apple Silicon macOS, and Intel
  macOS release outputs evaluate from one flake.

### Fixed

- Fixed connection-pool initialization, double release, stale-slot reuse, and
  inactive-slot sweeping defects. Pool reuse now waits for outstanding read,
  write, and close completions.
- Fixed application teardown leaks across sockets, TLS objects, timers,
  message storage, write storage, and pub/sub state.
- Fixed a recurring io_uring timer rearm that reused an expired absolute
  deadline and could spin a CPU core.
- Fixed HTTP request accumulation, pipelining, partial writes, close-after-drain,
  duplicate framing headers, oversized metadata/body handling, and response
  header injection. Empty header names, invalid chunk-size grammar, oversized
  trailers, invalid response statuses, and bodies on 204/304 are rejected.
- Fixed WebSocket masking, fragmented empty-final frames, fragmented large
  messages, invalid UTF-8 across frame boundaries, invalid close payloads,
  unbounded writes, and masked server output.
- Fixed plaintext handling in HTTPS mode and bounded the TLS BIO pair.
- Rejected sockets now close immediately before any I/O registration, avoiding
  completion-storage exhaustion.
- Removed the per-connection chunk scratch buffer and its 8 KiB chunk ceiling;
  chunk parts now enter the bounded output ring directly.
- Fixed outbound WebSocket UTF-8, control-length, close-code, and close-reason
  validation, including the RFC 6455 distinction between protocol errors and
  invalid UTF-8 close reasons.

### Security

- Added strict WebSocket handshake validation for method, upgrade tokens,
  version, unique key headers, and optional application authorization.
- Added finite limits for every peer-controlled HTTP and WebSocket buffer used
  by the public server path.
- Reject ambiguous HTTP framing and control characters in response status or
  header metadata.
- Disabled the incomplete HTTP/3 adapter and removed raw QUIC internals from
  the supported public API and live application state. Unsafe raw callbacks
  were replaced with fail-closed stubs.

### Breaking changes

- Route and WebSocket registration return errors and must be called with
  `try`, `catch`, or equivalent handling.
- Applications that need messages larger than 16 KiB must use
  `ConfiguredApp` and set matching `WsBehavior` limits.
- Output can now return `error.WouldBlock`; WebSocket producers should resume
  from the `drain` callback.
- `WebSocket.send` rejects continuation opcodes because the public API emits
  complete final messages. `send_close` closes the transport after the close
  frame drains; use `terminate` for an immediate close.
- HTTP/3 initialization now fails explicitly with
  `error.Http3NotImplemented`, and raw QUIC internals are no longer exported.
- Request route matching uses `Request.path`; the original request target and
  query are available separately as `Request.target` and `Request.query`.

### Known limitations

- RFC 7692 per-message deflate, HTTP/2, HTTP/3, Windows, route parameters,
  middleware, async handlers, and a stable C ABI are not available in this
  alpha.
- Autobahn groups 12 and 13 are excluded because compression is not
  negotiated. All 301 enabled cases complete with 298 strict passes and 3
  informational results.
