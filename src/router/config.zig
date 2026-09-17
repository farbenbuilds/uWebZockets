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

/// Request buffer stride alignment; keeps every body start SIMD-friendly.
pub const request_buffer_alignment = 16;
/// Write queue alignment; keeps each bounded ring on a cache line.
pub const write_queue_alignment = 64;
/// WebSocket message storage alignment.
pub const message_storage_alignment = 16;
/// Every carved region starts on at least a cache line.
pub const slab_alignment = @max(64, @alignOf(core_tcp.TcpConnection));

/// Failures raised while validating a configuration or planning its slab.
pub const Error = error{
    InvalidConnectionCapacity,
    InvalidWebSocketMessageCapacity,
    InvalidWriteQueueCapacity,
    InvalidBodyCapacity,
    InvalidIdleTimeout,
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

    /// Returns a copy with the named fields replaced.
    pub fn with(self: ServerConfig, overrides: anytype) ServerConfig {
        var result = self;
        inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |field| {
            if (!@hasField(ServerConfig, field.name)) {
                @compileError("unknown ServerConfig field: " ++ field.name);
            }
            @field(result, field.name) = @field(overrides, field.name);
        }
        return result;
    }

    /// Rejects configurations that cannot produce a usable slab.
    pub fn validate(self: ServerConfig) Error!void {
        if (self.max_connections == 0) return error.InvalidConnectionCapacity;
        if (self.max_ws_message_size == 0) return error.InvalidWebSocketMessageCapacity;
        if (self.write_queue_size == 0) return error.InvalidWriteQueueCapacity;
        if (self.max_body_size == 0) return error.InvalidBodyCapacity;
        if (self.idle_timeout_ms > std.math.maxInt(i64)) return error.InvalidIdleTimeout;
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
            .request_buffer_stride = try config.request_buffer_stride(),
            .compression_stride = if (config.compression) try config.compression_stride() else 0,
            .total_bytes = offsets.total_bytes,
            .alignment = slab_alignment,
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

    offsets.total_bytes = cursor;
    return offsets;
}

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
