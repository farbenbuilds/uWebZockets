//! High-level server capacity configuration and contiguous slab planning.
//!
//! `ServerConfig` replaces byte-level capacity arithmetic with named limits.
//! `SlabLayout` translates one config into the exact per-connection strides
//! and the single contiguous region that the application allocates at startup.
//! Nothing in this module allocates; `carve` only partitions caller storage.

const std = @import("std");
const core_tcp = @import("../core/tcp.zig");
const http_parser = @import("../http/parser.zig");
const ws_deflate = @import("../ws/deflate.zig");
const rejection = @import("../http/rejection.zig");
const xdp_transport = @import("../xdp/transport.zig");
const datagram_ring = @import("../quic/datagram_ring.zig");
const metrics_module = @import("../observability/metrics.zig");
const file_watch = @import("../observability/file_watch.zig");

/// Request buffer stride alignment; keeps every body start SIMD-friendly.
pub const request_buffer_alignment = 16;
/// Write queue alignment; keeps each bounded ring on a cache line.
pub const write_queue_alignment = 64;
/// WebSocket message storage alignment.
pub const message_storage_alignment = 16;
/// Every carved region starts on at least a cache line.
pub const slab_alignment = @max(64, @alignOf(core_tcp.TcpConnection));

/// Transport backend selected by a configuration.
///
/// `kernel_bypass` is a request, not a guarantee: `xdp_transport.resolve_mode`
/// drops it on non-Linux targets and the runtime probe falls back to the
/// standard stack when the kernel or process privileges refuse AF_XDP.
pub const TransportMode = xdp_transport.Mode;

/// Failures raised while validating a configuration or planning its slab.
pub const Error = error{
    InvalidConnectionCapacity,
    InvalidWebSocketMessageCapacity,
    InvalidWriteQueueCapacity,
    InvalidBodyCapacity,
    InvalidIdleTimeout,
    InvalidDatagramCapacity,
    InvalidTransportConfiguration,
    InvalidMetricsPath,
    InvalidWatchConfiguration,
    WatchRequiresDevLog,
    WatchUnavailable,
    MisalignedSlab,
    SlabSizeOverflow,
    SlabTooSmall,
};

/// Human-readable server capacities translated once into one startup slab.
///
/// Capacities are compile-time by design: they determine the type of the
/// generated application. Use `with` to derive a tweaked config and construct
/// the server through `router/builder.zig`.
pub const ServerConfig = struct {
    /// Maximum simultaneous connections held in the contiguous pool slab.
    max_connections: usize = 1024,
    /// Maximum complete WebSocket message stored per connection.
    max_ws_message_size: usize = 16 * 1024,
    /// Bounded pending-output bytes per connection.
    write_queue_size: usize = 64 * 1024,
    /// Largest accepted HTTP/1.1 request body.
    max_body_size: usize = http_parser.default_max_body_size,
    /// Inactivity timeout in milliseconds; zero disables the sweeper.
    idle_timeout_ms: u64 = 120_000,
    /// Reserves per-connection RFC 7692 scratch inside the startup slab.
    compression: bool = false,
    /// Requested transport backend; see `TransportMode`.
    transport: TransportMode = .standard,
    /// Largest single WebTransport datagram payload; zero disables datagrams.
    max_datagram_size: usize = 0,
    /// Pending datagram slots reserved per connection; zero disables datagrams.
    datagram_slots: usize = 0,
    /// AF_XDP UMEM chunk size in bytes; must be a power of two.
    xdp_frame_size: usize = 2048,
    /// AF_XDP UMEM frame count; must be a power of two.
    xdp_frame_count: usize = 1024,
    /// Serves the hidden Prometheus endpoint when enabled.
    observability: bool = false,
    /// Path of the observability endpoint; retained for the app lifetime.
    metrics_path: []const u8 = "/metrics",
    /// Writes the startup wordmark, ready summary, and colored event lines.
    ///
    /// Opt-in; leaving it false keeps every development-log write silent.
    enable_dev_log: bool = false,
    /// Directories watched recursively for the development log; empty is off.
    ///
    /// Nonempty paths require `enable_dev_log` and a Linux build. Paths are
    /// borrowed for the application lifetime, like `metrics_path`.
    watch_paths: []const []const u8 = &.{},

    /// Optional per-field replacements accepted by `with`.
    ///
    /// A null field leaves the matching `ServerConfig` field unchanged.
    pub const Overrides = struct {
        /// Replaces `max_connections` when non-null.
        max_connections: ?usize = null,
        /// Replaces `max_ws_message_size` when non-null.
        max_ws_message_size: ?usize = null,
        /// Replaces `write_queue_size` when non-null.
        write_queue_size: ?usize = null,
        /// Replaces `max_body_size` when non-null.
        max_body_size: ?usize = null,
        /// Replaces `idle_timeout_ms` when non-null.
        idle_timeout_ms: ?u64 = null,
        /// Replaces `compression` when non-null.
        compression: ?bool = null,
        /// Replaces `transport` when non-null.
        transport: ?TransportMode = null,
        /// Replaces `max_datagram_size` when non-null.
        max_datagram_size: ?usize = null,
        /// Replaces `datagram_slots` when non-null.
        datagram_slots: ?usize = null,
        /// Replaces `xdp_frame_size` when non-null.
        xdp_frame_size: ?usize = null,
        /// Replaces `xdp_frame_count` when non-null.
        xdp_frame_count: ?usize = null,
        /// Replaces `observability` when non-null.
        observability: ?bool = null,
        /// Replaces `metrics_path` when non-null.
        metrics_path: ?[]const u8 = null,
        /// Replaces `enable_dev_log` when non-null.
        enable_dev_log: ?bool = null,
        /// Replaces `watch_paths` when non-null.
        watch_paths: ?[]const []const u8 = null,
    };

    /// Returns a copy with every non-null override field replaced.
    pub fn with(self: ServerConfig, overrides: Overrides) ServerConfig {
        var result = self;
        if (overrides.max_connections) |value| result.max_connections = value;
        if (overrides.max_ws_message_size) |value| result.max_ws_message_size = value;
        if (overrides.write_queue_size) |value| result.write_queue_size = value;
        if (overrides.max_body_size) |value| result.max_body_size = value;
        if (overrides.idle_timeout_ms) |value| result.idle_timeout_ms = value;
        if (overrides.compression) |value| result.compression = value;
        if (overrides.transport) |value| result.transport = value;
        if (overrides.max_datagram_size) |value| result.max_datagram_size = value;
        if (overrides.datagram_slots) |value| result.datagram_slots = value;
        if (overrides.xdp_frame_size) |value| result.xdp_frame_size = value;
        if (overrides.xdp_frame_count) |value| result.xdp_frame_count = value;
        if (overrides.observability) |value| result.observability = value;
        if (overrides.metrics_path) |value| result.metrics_path = value;
        if (overrides.enable_dev_log) |value| result.enable_dev_log = value;
        if (overrides.watch_paths) |value| result.watch_paths = value;
        return result;
    }

    /// Rejects configurations that cannot produce a usable slab.
    pub fn validate(self: ServerConfig) Error!void {
        if (self.max_connections == 0) return error.InvalidConnectionCapacity;
        if (self.max_ws_message_size == 0) return error.InvalidWebSocketMessageCapacity;
        if (self.write_queue_size == 0) return error.InvalidWriteQueueCapacity;
        if (self.max_body_size == 0) return error.InvalidBodyCapacity;
        if (self.idle_timeout_ms > std.math.maxInt(i64)) return error.InvalidIdleTimeout;
        try self.validate_datagrams();
        try self.validate_transport();
        try self.validate_watch();
    }

    fn validate_datagrams(self: ServerConfig) Error!void {
        if (self.max_datagram_size == 0) {
            if (self.datagram_slots != 0) return error.InvalidDatagramCapacity;
            return;
        }
        if (self.datagram_slots == 0) return error.InvalidDatagramCapacity;
        // The ring stores lengths as u32 and addresses slots with u32 cursors.
        if (self.max_datagram_size > std.math.maxInt(u32)) return error.InvalidDatagramCapacity;
        if (self.datagram_slots > std.math.maxInt(u32)) return error.InvalidDatagramCapacity;
    }

    fn validate_transport(self: ServerConfig) Error!void {
        if (self.transport == .kernel_bypass) {
            if (!std.math.isPowerOfTwo(self.xdp_frame_size)) {
                return error.InvalidTransportConfiguration;
            }
            if (self.xdp_frame_size < 1024 or self.xdp_frame_size > 64 * 1024) {
                return error.InvalidTransportConfiguration;
            }
            if (!std.math.isPowerOfTwo(self.xdp_frame_count) or self.xdp_frame_count == 0) {
                return error.InvalidTransportConfiguration;
            }
            if (self.xdp_frame_count > xdp_transport.max_frames) {
                return error.InvalidTransportConfiguration;
            }
        }
        if (self.observability) {
            if (self.metrics_path.len == 0 or self.metrics_path[0] != '/') {
                return error.InvalidMetricsPath;
            }
        }
    }

    fn validate_watch(self: ServerConfig) Error!void {
        if (self.watch_paths.len == 0) return;
        if (!self.enable_dev_log) return error.WatchRequiresDevLog;
        if (self.watch_paths.len > file_watch.max_roots) {
            return error.InvalidWatchConfiguration;
        }
        for (self.watch_paths) |path| {
            if (path.len == 0 or path.len + 1 > file_watch.max_path_bytes) {
                return error.InvalidWatchConfiguration;
            }
        }
        if (!file_watch.available) return error.WatchUnavailable;
    }

    /// Bytes reserved per connection for all pending datagrams.
    pub fn datagram_stride(self: ServerConfig) Error!usize {
        if (self.max_datagram_size == 0) return 0;
        return std.math.mul(usize, self.datagram_slots, self.max_datagram_size) catch
            return error.SlabSizeOverflow;
    }

    /// AF_XDP UMEM bytes; zero when the standard transport is selected.
    pub fn xdp_umem_bytes(self: ServerConfig) Error!usize {
        if (self.transport != .kernel_bypass) return 0;
        return std.math.mul(usize, self.xdp_frame_count, self.xdp_frame_size) catch
            return error.SlabSizeOverflow;
    }

    /// Base alignment the owning allocation must satisfy for this configuration.
    ///
    /// AF_XDP registers the slab region itself as UMEM, and the kernel rejects
    /// any registration that is not page aligned.
    pub fn required_alignment(self: ServerConfig) usize {
        if (self.transport == .kernel_bypass) return std.heap.page_size_min;
        return slab_alignment;
    }

    /// Bytes reserved per connection for one HTTP/1.1 request.
    pub fn request_buffer_stride(self: ServerConfig) Error!usize {
        if (self.max_body_size == 0) return error.InvalidBodyCapacity;

        const fixed = std.math.add(
            usize,
            http_parser.max_request_line_size,
            http_parser.max_header_size,
        ) catch return error.SlabSizeOverflow;
        const fixed_with_slack = std.math.add(usize, fixed, 1024) catch
            return error.SlabSizeOverflow;
        const total = std.math.add(usize, self.max_body_size, fixed_with_slack) catch
            return error.SlabSizeOverflow;
        return align_checked(total, request_buffer_alignment);
    }

    /// Bytes reserved per connection for paired RFC 7692 scratch regions.
    pub fn compression_stride(self: ServerConfig) Error!usize {
        if (self.max_ws_message_size == 0) return error.InvalidWebSocketMessageCapacity;

        const per_direction = ws_deflate.worst_case_scratch_bound(self.max_ws_message_size) catch
            return error.SlabSizeOverflow;
        const both = std.math.mul(usize, per_direction, 2) catch
            return error.SlabSizeOverflow;
        return align_checked(both, request_buffer_alignment);
    }

    /// Total contiguous slab bytes required by this configuration.
    pub fn slab_bytes(self: ServerConfig) Error!usize {
        return (try layout_offsets(self)).total_bytes;
    }

    /// Fixed rejection policy rendered into transport error responses.
    pub fn rejection_policy(self: ServerConfig) rejection.RejectionPolicy {
        return .{ .max_body_size = self.max_body_size };
    }

    /// Named presets for common deployment shapes.
    ///
    /// Every preset is a plain `ServerConfig`, so any field remains overridable
    /// through `Server.builder(...)` and its `with_*` methods. The per-connection footprint is dominated by
    /// the HTTP/2 request slabs embedded in each connection, so these presets
    /// choose conservative connection counts and spend their bytes on the
    /// capacity that each workload actually exercises.
    pub const Preset = struct {
        /// Small JSON payloads, many routing nodes, moderate connection count.
        pub const microservice: ServerConfig = .{
            .max_connections = 256,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 16 * 1024,
            .max_body_size = 64 * 1024,
            .idle_timeout_ms = 30_000,
        };
        /// Maximum connection count with pre-reserved compression scratch.
        pub const websocket_chat: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 32 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 4 * 1024,
            .idle_timeout_ms = 120_000,
            .compression = true,
        };
        /// Large contiguous response rings, few concurrent connections.
        pub const file_server: ServerConfig = .{
            .max_connections = 128,
            .max_ws_message_size = 4 * 1024,
            .write_queue_size = 512 * 1024,
            .max_body_size = 8 * 1024,
            .idle_timeout_ms = 300_000,
        };
        /// AF_XDP kernel bypass with a page-aligned UMEM carved from the slab.
        ///
        /// The bypass is opportunistic: platforms without AF_XDP and processes
        /// without the required privileges transparently use the standard path.
        pub const kernel_bypass: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 16 * 1024,
            .idle_timeout_ms = 60_000,
            .transport = .kernel_bypass,
            .observability = true,
        };
        /// Unreliable WebTransport datagrams with one SoA ring per connection.
        pub const webtransport_realtime: ServerConfig = .{
            .max_connections = 512,
            .max_ws_message_size = 8 * 1024,
            .write_queue_size = 32 * 1024,
            .max_body_size = 4 * 1024,
            .idle_timeout_ms = 60_000,
            .max_datagram_size = 1200,
            .datagram_slots = 64,
            .observability = true,
        };
    };
};

/// Defaults used by `App` and the builder entry point.
pub const default_config: ServerConfig = .{};

/// Field offsets of the single contiguous startup slab.
///
/// Both `required_bytes` and `carve` derive from one computation so sizing and
/// partitioning cannot drift apart.
const LayoutOffsets = struct {
    pool_start: usize,
    pool_end: usize,
    freelist_start: usize,
    freelist_end: usize,
    request_start: usize,
    request_end: usize,
    write_start: usize,
    write_end: usize,
    message_start: usize,
    message_end: usize,
    compression_start: usize,
    compression_end: usize,
    datagram_session_start: usize,
    datagram_session_end: usize,
    datagram_sequence_start: usize,
    datagram_sequence_end: usize,
    datagram_length_start: usize,
    datagram_length_end: usize,
    datagram_ring_start: usize,
    datagram_ring_end: usize,
    datagram_payload_start: usize,
    datagram_payload_end: usize,
    xdp_umem_start: usize,
    xdp_umem_end: usize,
    xdp_transport_start: usize,
    xdp_transport_end: usize,
    metrics_start: usize,
    metrics_end: usize,
    total_bytes: usize,
};

/// Views over one carved slab. Every slice borrows the slab storage.
pub const SlabLayout = struct {
    /// The whole startup block; the owner frees exactly this slice.
    slab: []u8,
    /// Contiguous connection state array (the hot SoA region).
    pool_storage: []core_tcp.TcpConnection,
    /// LIFO freelist indices paired with `pool_storage`.
    freelist: []usize,
    /// One HTTP/1.1 request buffer per connection, `request_buffer_stride` apart.
    request_buffers: []u8,
    /// One bounded response ring per connection, `write_queue_size` apart.
    write_queues: []u8,
    /// One WebSocket message region per connection, `max_ws_message_size` apart.
    ws_messages: []u8,
    /// Optional paired DEFLATE scratch, zero-length when compression is off.
    compression_scratch: []u8,
    /// Per-connection datagram session ids, `datagram_slots` per connection.
    datagram_session_ids: []u64,
    /// Per-connection datagram sequence numbers.
    datagram_sequences: []u64,
    /// Per-connection datagram payload lengths.
    datagram_payload_lengths: []u32,
    /// One persistent ring cursor struct per connection.
    datagram_rings: []datagram_ring.DatagramRing,
    /// Per-connection fixed-stride datagram payload storage.
    datagram_payloads: []u8,
    /// Byte distance between consecutive connections' datagram payload slabs.
    datagram_stride: usize,
    /// AF_XDP UMEM region; zero-length unless kernel bypass is selected.
    xdp_umem: []align(std.heap.page_size_min) u8,
    /// Storage for the optional `xdp_transport.XdpTransport`; zero-length
    /// unless kernel bypass is selected. The consumer casts it after checking
    /// the configuration because the region may be empty.
    xdp_transport_bytes: []u8,
    /// Cache-line-aligned metrics registry; null unless observability is on.
    metrics_registry: ?*metrics_module.Registry,
    /// Byte distance between consecutive request buffers.
    request_buffer_stride: usize,
    /// Byte distance between consecutive paired compression scratch regions.
    compression_stride: usize,
    /// Total bytes consumed inside `slab`.
    total_bytes: usize,
    /// Required base alignment of `slab`.
    alignment: usize,

    /// Partitions `slab` into typed views without allocating.
    pub fn carve(slab: []u8, config: ServerConfig) Error!SlabLayout {
        const offsets = try layout_offsets(config);
        if (slab.len < offsets.total_bytes) return error.SlabTooSmall;
        if (@intFromPtr(slab.ptr) % config.required_alignment() != 0) {
            return error.MisalignedSlab;
        }

        return .{
            .slab = slab[0..offsets.total_bytes],
            .pool_storage = std.mem.bytesAsSlice(
                core_tcp.TcpConnection,
                region_bytes(core_tcp.TcpConnection, slab, offsets.pool_start, offsets.pool_end),
            ),
            .freelist = std.mem.bytesAsSlice(
                usize,
                region_bytes(usize, slab, offsets.freelist_start, offsets.freelist_end),
            ),
            .request_buffers = slab[offsets.request_start..offsets.request_end],
            .write_queues = slab[offsets.write_start..offsets.write_end],
            .ws_messages = slab[offsets.message_start..offsets.message_end],
            .compression_scratch = slab[offsets.compression_start..offsets.compression_end],
            .datagram_session_ids = std.mem.bytesAsSlice(
                u64,
                region_bytes(u64, slab, offsets.datagram_session_start, offsets.datagram_session_end),
            ),
            .datagram_sequences = std.mem.bytesAsSlice(
                u64,
                region_bytes(u64, slab, offsets.datagram_sequence_start, offsets.datagram_sequence_end),
            ),
            .datagram_payload_lengths = std.mem.bytesAsSlice(
                u32,
                region_bytes(u32, slab, offsets.datagram_length_start, offsets.datagram_length_end),
            ),
            .datagram_rings = if (config.max_datagram_size != 0)
                std.mem.bytesAsSlice(
                    datagram_ring.DatagramRing,
                    region_bytes(
                        datagram_ring.DatagramRing,
                        slab,
                        offsets.datagram_ring_start,
                        offsets.datagram_ring_end,
                    ),
                )
            else
                empty_datagram_rings(),
            .datagram_payloads = slab[offsets.datagram_payload_start..offsets.datagram_payload_end],
            .datagram_stride = try config.datagram_stride(),
            .xdp_umem = if (config.transport == .kernel_bypass)
                @alignCast(slab[offsets.xdp_umem_start..offsets.xdp_umem_end])
            else
                empty_page_region(),
            .xdp_transport_bytes = slab[offsets.xdp_transport_start..offsets.xdp_transport_end],
            .metrics_registry = if (config.observability)
                @ptrCast(@alignCast(slab[offsets.metrics_start..offsets.metrics_end].ptr))
            else
                null,
            .request_buffer_stride = try config.request_buffer_stride(),
            .compression_stride = if (config.compression) try config.compression_stride() else 0,
            .total_bytes = offsets.total_bytes,
            .alignment = config.required_alignment(),
        };
    }
};

/// Computes the single contiguous slab size for `config`.
pub fn required_bytes(config: ServerConfig) Error!usize {
    return (try layout_offsets(config)).total_bytes;
}

/// Partitions caller storage according to `config`.
pub fn carve(slab: []u8, config: ServerConfig) Error!SlabLayout {
    return SlabLayout.carve(slab, config);
}

fn layout_offsets(config: ServerConfig) Error!LayoutOffsets {
    try config.validate();

    const request_stride = try config.request_buffer_stride();
    const compression_stride = if (config.compression) try config.compression_stride() else 0;

    var offsets: LayoutOffsets = undefined;
    var cursor: usize = 0;

    // Hot connection state first so request dispatch stays on the same pages.
    cursor = try align_checked(cursor, @alignOf(core_tcp.TcpConnection));
    offsets.pool_start = cursor;
    cursor = try add_product(cursor, @sizeOf(core_tcp.TcpConnection), config.max_connections);
    offsets.pool_end = cursor;

    cursor = try align_checked(cursor, @alignOf(usize));
    offsets.freelist_start = cursor;
    cursor = try add_product(cursor, @sizeOf(usize), config.max_connections);
    offsets.freelist_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.request_start = cursor;
    cursor = try add_product(cursor, request_stride, config.max_connections);
    offsets.request_end = cursor;

    cursor = try align_checked(cursor, write_queue_alignment);
    offsets.write_start = cursor;
    cursor = try add_product(cursor, config.write_queue_size, config.max_connections);
    offsets.write_end = cursor;

    cursor = try align_checked(cursor, message_storage_alignment);
    offsets.message_start = cursor;
    cursor = try add_product(cursor, config.max_ws_message_size, config.max_connections);
    offsets.message_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.compression_start = cursor;
    cursor = try add_product(cursor, compression_stride, config.max_connections);
    offsets.compression_end = cursor;

    // Datagram metadata stays in its own arrays so a queue drain touches only
    // the hot length/round-trip fields and never the payload pages.
    const datagram_stride = try config.datagram_stride();
    const datagram_slot_count = std.math.mul(
        usize,
        config.datagram_slots,
        config.max_connections,
    ) catch return error.SlabSizeOverflow;

    cursor = try align_checked(cursor, @alignOf(u64));
    offsets.datagram_session_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u64), datagram_slot_count);
    offsets.datagram_session_end = cursor;

    offsets.datagram_sequence_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u64), datagram_slot_count);
    offsets.datagram_sequence_end = cursor;

    cursor = try align_checked(cursor, @alignOf(u32));
    offsets.datagram_length_start = cursor;
    cursor = try add_product(cursor, @sizeOf(u32), datagram_slot_count);
    offsets.datagram_length_end = cursor;

    // The cursors must outlive any single call, so the ring structs are carved
    // per connection instead of being rebuilt from the metadata arrays.
    cursor = try align_checked(cursor, @alignOf(datagram_ring.DatagramRing));
    offsets.datagram_ring_start = cursor;
    cursor = try add_product(
        cursor,
        @sizeOf(datagram_ring.DatagramRing),
        config.max_connections,
    );
    offsets.datagram_ring_end = cursor;

    cursor = try align_checked(cursor, request_buffer_alignment);
    offsets.datagram_payload_start = cursor;
    cursor = try add_product(cursor, datagram_stride, config.max_connections);
    offsets.datagram_payload_end = cursor;

    // UMEM is registered directly from the slab, so the bypass path pays for a
    // page-aligned region while the standard path carves nothing at all.
    if (config.transport == .kernel_bypass) {
        const umem_bytes = try config.xdp_umem_bytes();
        cursor = try align_checked(cursor, std.heap.page_size_min);
        offsets.xdp_umem_start = cursor;
        cursor = std.math.add(usize, cursor, umem_bytes) catch return error.SlabSizeOverflow;
        offsets.xdp_umem_end = cursor;

        cursor = try align_checked(cursor, @alignOf(xdp_transport.XdpTransport));
        offsets.xdp_transport_start = cursor;
        cursor = std.math.add(
            usize,
            cursor,
            @sizeOf(xdp_transport.XdpTransport),
        ) catch return error.SlabSizeOverflow;
        offsets.xdp_transport_end = cursor;
    } else {
        offsets.xdp_umem_start = cursor;
        offsets.xdp_umem_end = cursor;
        offsets.xdp_transport_start = cursor;
        offsets.xdp_transport_end = cursor;
    }

    // The registry is always carved with its cache-line alignment so the
    // owning App struct never has to embed a 64-byte-aligned value.
    cursor = try align_checked(cursor, @alignOf(metrics_module.Registry));
    offsets.metrics_start = cursor;
    if (config.observability) {
        cursor = std.math.add(
            usize,
            cursor,
            @sizeOf(metrics_module.Registry),
        ) catch return error.SlabSizeOverflow;
    }
    offsets.metrics_end = cursor;

    offsets.total_bytes = cursor;
    return offsets;
}

/// Page-aligned empty region returned when the bypass layout is not carved.
pub fn empty_page_region() []align(std.heap.page_size_min) u8 {
    return empty_page_storage[0..];
}

/// Empty ring slice returned when datagrams are disabled.
pub fn empty_datagram_rings() []datagram_ring.DatagramRing {
    return empty_datagram_ring_storage[0..];
}

var empty_page_storage: [0]u8 align(std.heap.page_size_min) = .{};
var empty_datagram_ring_storage: [0]datagram_ring.DatagramRing = .{};

fn add_product(cursor: usize, element_size: usize, count: usize) Error!usize {
    const bytes = std.math.mul(usize, element_size, count) catch return error.SlabSizeOverflow;
    return std.math.add(usize, cursor, bytes) catch return error.SlabSizeOverflow;
}

/// Re-tags an aligned slab region; `layout_offsets` guarantees the alignment.
fn region_bytes(comptime T: type, slab: []u8, start: usize, end: usize) []align(@alignOf(T)) u8 {
    return @alignCast(slab[start..end]);
}

fn align_checked(value: usize, alignment: usize) Error!usize {
    if (value > std.math.maxInt(usize) - (alignment - 1)) return error.SlabSizeOverflow;
    return std.mem.alignForward(usize, value, alignment);
}
