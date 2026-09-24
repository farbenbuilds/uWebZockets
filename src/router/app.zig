const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_pool = @import("../core/pool.zig");
const core_timer = @import("../core/timer.zig");
const core_affinity = @import("../core/affinity.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const DeflateContext = @import("../ws/deflate.zig").Context;
const TlsContext = @import("../crypto/tls.zig").TlsContext;
const quic = @import("../quic/engine.zig");
const udp = @import("../core/udp.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const json_rpc_http = @import("../rpc/http.zig");
const static_files_module = @import("../http/static_files.zig");
const cluster_module = @import("cluster.zig");
const config_module = @import("config.zig");
const datagram_module = @import("datagram.zig");
const datagram_ring_module = @import("../quic/datagram_ring.zig");
const metrics_module = @import("../observability/metrics.zig");
const dev_log_module = @import("../observability/dev_log.zig");
const terminal_module = @import("../observability/terminal.zig");
const file_watch_module = @import("../observability/file_watch.zig");
const ebpf_module = @import("../observability/ebpf.zig");
const xdp_transport_module = @import("../xdp/transport.zig");
const http_rejection = @import("../http/rejection.zig");

const log = std.log.scoped(.server);

/// Default maximum complete WebSocket message size per connection.
pub const default_max_ws_message_size = 16 * 1024;
/// Default bounded pending-output capacity per TCP connection.
pub const default_write_queue_size = core_tcp.default_write_queue_capacity;
/// Default inactivity timeout before an idle connection is closed.
pub const default_idle_timeout_ms: u64 = 120_000;
/// Reports whether the compiled lsquic transport is available.
pub const http3_available = quic.available;

/// Startup policy for `App.cluster` worker groups.
pub const ClusterOptions = struct {
    /// Pins worker `i` to the `i`-th allowed physical core.
    ///
    /// Pinning is best effort: restricted cpusets and platforms without a
    /// hard-affinity API leave the worker unpinned instead of failing startup.
    cpu_affinity: bool = true,
};

/// Returns the default fixed-capacity application type.
pub fn app(comptime max_connections: usize) type {
    return configured_app(max_connections, default_max_ws_message_size, default_write_queue_size);
}

/// Returns an application type with explicit message and write capacities.
pub fn configured_app(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
) type {
    return configured_app_with_timeout(
        max_connections,
        max_ws_message_size,
        write_queue_size,
        default_idle_timeout_ms,
    );
}

/// Returns an application type with an explicit idle timeout policy.
pub fn configured_app_with_timeout(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
    comptime idle_timeout_ms: u64,
) type {
    if (max_connections == 0) @compileError("connection capacity must be greater than zero");
    if (max_ws_message_size == 0) @compileError("WebSocket message capacity must be greater than zero");
    if (write_queue_size == 0) @compileError("write queue capacity must be greater than zero");
    if (max_connections > std.math.maxInt(usize) / max_ws_message_size) {
        @compileError("WebSocket message storage size overflows usize");
    }
    if (max_connections > std.math.maxInt(usize) / write_queue_size) {
        @compileError("write queue storage size overflows usize");
    }

    return struct {
        const Self = @This();
        const Pool = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections);
        const QuicEngine = quic.quic_engine(max_connections, write_queue_size);
        const QuicTransport = udp.quic_transport(QuicEngine);
        const static_file_capacity = if (write_queue_size > 4096) write_queue_size - 4096 else write_queue_size;
        const StaticFiles = static_files_module.static_files(static_file_capacity);
        const ClusterInbox = cluster_module.message_queue(max_ws_message_size);
        const DatagramRing = datagram_ring_module.DatagramRing;
        const DatagramRouter = datagram_module.Router;
        const XdpTransport = xdp_transport_module.XdpTransport;
        const max_static_routes = 8;
        const default_config = config_module.ServerConfig{
            .max_connections = max_connections,
            .max_ws_message_size = max_ws_message_size,
            .write_queue_size = write_queue_size,
            .idle_timeout_ms = idle_timeout_ms,
        };

        io: std.Io,
        loop: core_loop.Loop,
        pool: Pool,
        // One contiguous startup slab backs the pool, request, message, and
        // queue regions so deinit releases exactly one allocation.
        slab: []u8,
        slab_allocator: std.mem.Allocator,
        request_buffers: []u8,
        request_buffer_stride: usize,
        max_body_size: usize,
        reject_policy: http_rejection.RejectionPolicy = .{},
        ws_message_storage: []u8,
        ws_compression_storage: []u8 = &.{},
        ws_compression_capacity: usize = 0,
        ws_compression_owned: bool = false,
        ws_deflate: ?DeflateContext = null,
        write_queue_storage: []u8,
        router: radix.Router,
        // WebTransport datagram state. The metadata arrays are SoA and the
        // payload slab is one fixed stride per connection, all carved from the
        // startup slab so no datagram ever allocates.
        datagram_router: DatagramRouter = .{},
        datagram_session_ids: []u64 = &.{},
        datagram_sequences: []u64 = &.{},
        datagram_payload_lengths: []u32 = &.{},
        datagram_rings: []DatagramRing = &.{},
        datagram_payloads: []u8 = &.{},
        datagram_stride: usize = 0,
        // Kernel-bypass observability state.
        xdp_transport: ?*XdpTransport = null,
        transport_availability: xdp_transport_module.Availability = .{
            .mode = .standard,
            .reason = .none,
        },
        metrics_registry: ?*metrics_module.Registry = null,
        metrics_enabled: bool = false,
        metrics_installed: bool = false,
        metrics_path: []const u8 = "/metrics",
        dev_log_enabled: bool = false,
        dev_log_file: ?std.Io.File = null,
        watch_paths: []const []const u8 = &.{},
        ready_started_ns: u64 = 0,
        ebpf_map_fd: i32 = -1,
        static_handlers: [max_static_routes]?*StaticFiles = .{null} ** max_static_routes,
        static_handler_count: u8 = 0,
        cluster_inbox: ?*ClusterInbox = null,
        cluster_wakeup: ?xev.Async = null,
        cluster_completion: xev.Completion = .{},
        cluster_stop_requested: std.atomic.Value(bool) = .init(false),
        cluster_wakeup_active: bool = false,
        server: ?core_tcp.TcpServer = null,
        sweeper: ?core_timer.connection_sweeper(Pool, idle_timeout_ms) = null,
        watcher: ?file_watch_module.Watcher = null,
        tls_ctx: ?TlsContext = null,
        quic_tls_ctx: ?TlsContext = null,
        quic_transport: ?QuicTransport = null,
        http3_enabled: bool = false,
        routes_locked: bool = false,
        shutting_down: bool = false,
        running: bool = false,
        deinitialized: bool = false,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        /// Initializes a plaintext application and its single fixed-capacity slab.
        pub fn init(io: std.Io) !Self {
            return init_configured(io, std.heap.page_allocator, default_config);
        }

        /// Allocates the whole startup slab once, then initializes from it.
        ///
        /// Every pool, request, message, queue, and optional compression region
        /// comes from this one allocation; the runtime I/O loop never allocates.
        pub fn init_configured(
            io: std.Io,
            allocator: std.mem.Allocator,
            comptime config: config_module.ServerConfig,
        ) !Self {
            const total = try config_module.required_bytes(config);
            const alignment = comptime std.mem.Alignment.fromByteUnits(
                config.required_alignment(),
            );
            const slab = try allocator.alignedAlloc(u8, alignment, total);
            errdefer allocator.free(slab);
            return init_from_slab(io, allocator, slab, config);
        }

        /// Initializes from caller-provided storage; ownership transfers on success.
        ///
        /// `slab` must be aligned to `config.required_alignment()` and hold at
        /// least `config_module.required_bytes(config)` bytes. The application
        /// releases the full slice through `allocator` in `deinit`; on failure
        /// the caller keeps ownership.
        pub fn init_from_slab(
            io: std.Io,
            allocator: std.mem.Allocator,
            slab: []u8,
            comptime config: config_module.ServerConfig,
        ) !Self {
            // The connection setup path slices regions with type-level
            // capacities, so a mismatched runtime config would index out of
            // bounds. Reject the mismatch where it originates.
            comptime {
                if (config.max_connections != max_connections) @compileError(
                    "ServerConfig.max_connections must match the generated App capacity",
                );
                if (config.max_ws_message_size != max_ws_message_size) @compileError(
                    "ServerConfig.max_ws_message_size must match the generated App capacity",
                );
                if (config.write_queue_size != write_queue_size) @compileError(
                    "ServerConfig.write_queue_size must match the generated App capacity",
                );
                if (config.idle_timeout_ms != idle_timeout_ms) @compileError(
                    "ServerConfig.idle_timeout_ms must match the generated App timeout",
                );
            }

            const layout = try config_module.carve(slab, config);

            var loop = try core_loop.init();
            errdefer core_loop.deinit(&loop);

            const pool = try Pool.from_slices(layout.pool_storage, layout.freelist);

            var instance = Self{
                .io = io,
                .loop = loop,
                .pool = pool,
                .slab = slab,
                .slab_allocator = allocator,
                .request_buffers = layout.request_buffers,
                .request_buffer_stride = layout.request_buffer_stride,
                .max_body_size = config.max_body_size,
                .reject_policy = config.rejection_policy(),
                .ws_message_storage = layout.ws_messages,
                .ws_compression_storage = layout.compression_scratch,
                .ws_compression_capacity = if (layout.compression_stride == 0)
                    0
                else
                    layout.compression_stride / 2,
                .write_queue_storage = layout.write_queues,
                .router = radix.Router.init(),
                .datagram_session_ids = layout.datagram_session_ids,
                .datagram_sequences = layout.datagram_sequences,
                .datagram_payload_lengths = layout.datagram_payload_lengths,
                .datagram_rings = layout.datagram_rings,
                .datagram_payloads = layout.datagram_payloads,
                .datagram_stride = layout.datagram_stride,
                .metrics_registry = layout.metrics_registry,
                .metrics_enabled = config.observability,
                .metrics_path = if (config.observability) config.metrics_path else "/metrics",
                .dev_log_enabled = config.enable_dev_log,
                .watch_paths = config.watch_paths,
                .pubsub = .{},
            };

            if (instance.metrics_registry) |registry| registry.* = .{};
            // Monotonic start mark for the ready summary; the clock is
            // non-negative on every supported target.
            instance.ready_started_ns = @intCast(@max(std.Io.Clock.now(.awake, io).nanoseconds, 0));

            if (layout.datagram_rings.len != 0) {
                const slots = config.datagram_slots;
                const payload_stride = config.max_datagram_size;
                for (layout.datagram_rings, 0..) |*ring, index| {
                    const metadata_start = index * slots;
                    const payload_start = index * layout.datagram_stride;
                    // Validation bounded the slot count and stride, and the
                    // slab carved exactly `stride * connections` payload bytes.
                    ring.* = DatagramRing.init(
                        layout.datagram_session_ids[metadata_start .. metadata_start + slots],
                        layout.datagram_sequences[metadata_start .. metadata_start + slots],
                        layout.datagram_payload_lengths[metadata_start .. metadata_start + slots],
                        layout.datagram_payloads[payload_start .. payload_start + layout.datagram_stride],
                        payload_stride,
                    ) catch unreachable;
                }
            }

            // The bypass is requested at compile time but confirmed at runtime;
            // a refused probe or a failed ring setup leaves the standard
            // transport active and records why.
            if (comptime config.transport == .kernel_bypass) {
                instance.transport_availability = xdp_transport_module.probe();
                if (instance.transport_availability.mode == .kernel_bypass) {
                    const storage: *XdpTransport = @ptrCast(
                        @alignCast(layout.xdp_transport_bytes.ptr),
                    );
                    if (XdpTransport.init(layout.xdp_umem, .{
                        .chunk_size = @intCast(config.xdp_frame_size),
                        .frame_count = @intCast(config.xdp_frame_count),
                    })) |transport| {
                        storage.* = transport;
                        instance.xdp_transport = storage;
                    } else |err| {
                        instance.transport_availability = .{
                            .mode = .standard,
                            .reason = map_xdp_error(err),
                        };
                    }
                }
                if (instance.metrics_registry) |registry| {
                    if (instance.xdp_transport == null) {
                        registry.set(.xdp_kernel_bypass_fallbacks, 1);
                    } else {
                        registry.set(.kernel_bypass_active, 1);
                    }
                }
            }

            if (config.observability and ebpf_module.available()) {
                instance.ebpf_map_fd = ebpf_module.open_pinned(ebpf_map_path) catch -1;
            }
            return instance;
        }

        /// Initializes an HTTPS application from NUL-terminated certificate paths.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            return instance;
        }

        /// Initializes isolated TCP/TLS and HTTP/3/QUIC server contexts.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            instance.quic_tls_ctx = try TlsContext.init_http3(cert_path, key_path);
            instance.http3_enabled = true;
            return instance;
        }

        /// Releases all application resources after shutdown has drained completions.
        pub fn deinit(self: *Self) void {
            if (self.deinitialized) return;
            if (self.running) {
                std.debug.panic("cannot deinitialize an application from its event loop", .{});
            }
            self.shutdown() catch |err| {
                // Returning would leave kernel completions pointing at storage
                // the caller is about to release.
                std.debug.panic("application shutdown failed: {}", .{err});
            };

            if (self.sweeper) |*sw| {
                sw.deinit();
            }
            self.sweeper = null;
            if (self.watcher) |*watch| watch.deinit();
            self.watcher = null;
            self.server = null;

            if (self.quic_transport) |*transport| transport.deinit();
            self.quic_transport = null;
            if (self.quic_tls_ctx) |*tls| tls.deinit();
            self.quic_tls_ctx = null;
            if (self.tls_ctx) |*tls| tls.deinit();
            self.tls_ctx = null;
            if (self.ws_deflate) |*context| context.deinit();
            self.ws_deflate = null;
            for (self.static_handlers[0..self.static_handler_count]) |maybe_handler| {
                const handler = maybe_handler orelse continue;
                handler.deinit();
                std.heap.page_allocator.destroy(handler);
            }
            self.static_handler_count = 0;
            if (self.cluster_wakeup) |*wakeup| wakeup.deinit();
            self.cluster_wakeup = null;
            core_loop.deinit(&self.loop);
            // Carved pools stay inside the slab; lazily allocated RFC 7692
            // scratch is the only separately owned per-connection region.
            self.pool.deinit();
            if (self.ws_compression_owned and self.ws_compression_storage.len != 0) {
                std.heap.page_allocator.free(self.ws_compression_storage);
            }
            self.ws_compression_storage = &.{};
            self.ws_compression_owned = false;
            // The transport lives inside the slab; its rings must be unmapped
            // before the backing storage is released.
            if (self.xdp_transport) |transport| {
                transport.deinit();
                self.xdp_transport = null;
            }
            if (self.ebpf_map_fd >= 0) {
                ebpf_module.close(self.ebpf_map_fd);
                self.ebpf_map_fd = -1;
            }
            self.slab_allocator.free(self.slab);
            self.slab = &.{};
            self.deinitialized = true;
        }

        /// Stops recurring work and drains completions that borrow application slabs.
        pub fn shutdown(self: *Self) !void {
            if (self.deinitialized) return error.ApplicationDeinitialized;

            self.begin_shutdown();
            if (self.running) return;

            try self.drive_shutdown();
        }

        /// Reports whether this application currently owns an active loop run.
        pub fn is_running(self: *const Self) bool {
            return self.running;
        }

        fn begin_shutdown(self: *Self) void {
            if (self.shutting_down) return;

            self.shutting_down = true;
            self.cluster_stop_requested.store(true, .release);
            // Shutdown continues even if the cross-thread wakeup is already closed.
            if (self.cluster_wakeup) |*wakeup| wakeup.notify() catch {};
            if (self.sweeper) |*sw| sw.stop(&self.loop);
            if (self.watcher) |*watch| watch.stop(self.loop.get_xev_loop());
            if (self.server) |*server| core_tcp.close_server(server, &self.loop);
            if (self.quic_transport) |*transport| transport.shutdown();

            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index)) continue;
                core_tcp.close_connection(conn);
            }
        }

        fn drive_shutdown(self: *Self) !void {
            std.debug.assert(!self.running);
            self.running = true;
            defer self.running = false;
            try core_loop.run(&self.loop);
            try self.verify_shutdown();
        }

        fn verify_shutdown(self: *const Self) !void {
            if (self.pool.count_active() != 0) return error.ShutdownIncomplete;
            if (self.watcher) |*watch| {
                if (!watch.is_drained()) return error.ShutdownIncomplete;
            }
            if (self.server) |server| {
                if (!server.close_complete) return error.ShutdownIncomplete;
            }
            if (self.quic_transport) |*transport| if (!transport.is_drained()) {
                return error.ShutdownIncomplete;
            };
        }

        /// Registers a synchronous GET route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.get(path, handler);
            return self;
        }

        /// Registers a synchronous HEAD route.
        pub fn head(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.head(path, handler);
            return self;
        }

        /// Registers a synchronous POST route.
        pub fn post(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.post(path, handler);
            return self;
        }

        /// Registers a synchronous PUT route.
        pub fn put(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.put(path, handler);
            return self;
        }

        /// Registers a synchronous DELETE route.
        pub fn delete(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.delete(path, handler);
            return self;
        }

        /// Registers a synchronous PATCH route.
        pub fn patch(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.patch(path, handler);
            return self;
        }

        /// Registers a synchronous OPTIONS route.
        pub fn options(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.options(path, handler);
            return self;
        }

        /// Registers a safe, idempotent RFC 10008 QUERY route.
        pub fn query(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.query(path, handler);
            return self;
        }

        /// Registers a synchronous fallback-method route.
        pub fn any(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.any(path, handler);
            return self;
        }

        /// Registers a GET endpoint serving the current OpenAPI 3.1 document.
        pub fn openapi(self: *Self, path: []const u8) !*Self {
            return self.get_context(path, &self.router, serve_openapi);
        }

        /// Mounts a fixed-capacity JSON-RPC 2.0 service on one POST route.
        ///
        /// `service` accepts any mutable single-item pointer to a
        /// `configured_service` or `comptime_service` value that outlives the
        /// App and belongs to exactly one event loop.
        pub fn rpc(self: *Self, path: []const u8, service: anytype) !*Self {
            const Pointer = @TypeOf(service);
            const pointer = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => @compileError("RPC service must be passed by mutable pointer"),
            };
            if (pointer.size != .one or pointer.is_const) {
                @compileError("RPC service must be passed by mutable single-item pointer");
            }
            const Service = pointer.child;
            if (!@hasDecl(Service, "dispatch") or
                !@hasDecl(Service, "response_buffer") or
                !@hasDecl(Service, "seal"))
            {
                @compileError("RPC service must be created by json_rpc.configured_service");
            }

            try self.ensure_routes_mutable();
            try self.router.route_context(
                .post,
                path,
                service,
                json_rpc_http.route_handler(Service),
            );
            service.seal();
            return self;
        }

        /// Mounts one bounded, traversal-safe static asset directory.
        pub fn static(
            self: *Self,
            prefix: []const u8,
            root: []const u8,
            static_options: static_files_module.Options,
        ) !*Self {
            try self.ensure_routes_mutable();
            if (self.static_handler_count == max_static_routes) return error.StaticRouteCapacityReached;
            if (prefix.len == 0 or prefix[0] != '/' or
                std.mem.indexOfAny(u8, prefix, "?#\r\n:*") != null)
            {
                return error.InvalidRoutePath;
            }

            var route_buffer: [2048]u8 = undefined;
            const base = if (prefix.len > 1) std.mem.trimRight(u8, prefix, "/") else "";
            const route = std.fmt.bufPrint(&route_buffer, "{s}/*path", .{base}) catch {
                return error.InvalidRoutePath;
            };
            const index = self.static_handler_count;
            const handler = try std.heap.page_allocator.create(StaticFiles);
            errdefer std.heap.page_allocator.destroy(handler);
            handler.* = try StaticFiles.init(self.io, root, static_options);
            errdefer handler.deinit();
            try self.router.route_context(
                .get,
                route,
                handler,
                StaticFiles.handler,
            );
            self.static_handlers[index] = handler;
            self.static_handler_count += 1;
            return self;
        }

        /// Appends one ordered global middleware callback.
        pub fn use(
            self: *Self,
            context: *anyopaque,
            middleware: radix.MiddlewareHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.use(context, middleware);
            return self;
        }

        /// Registers a context-aware callback for one method.
        pub fn route_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_context(method, path, context, handler);
            return self;
        }

        /// Registers a deferred callback for one method.
        pub fn route_async(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async(method, path, handler);
            return self;
        }

        /// Registers a context-aware deferred callback for one method.
        pub fn route_async_context(
            self: *Self,
            method: radix.HttpMethod,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.router.route_async_context(method, path, context, handler);
            return self;
        }

        /// Registers a context-aware GET route.
        pub fn get_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextHandler,
        ) !*Self {
            return self.route_context(.get, path, context, handler);
        }

        /// Registers a deferred GET route.
        pub fn get_async(
            self: *Self,
            path: []const u8,
            handler: radix.AsyncHandler,
        ) !*Self {
            return self.route_async(.get, path, handler);
        }

        /// Registers a context-aware deferred GET route.
        pub fn get_async_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: radix.ContextAsyncHandler,
        ) !*Self {
            return self.route_async_context(.get, path, context, handler);
        }

        /// Registers a WebSocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) !*Self {
            try self.ensure_routes_mutable();
            if (!radix.valid_ws_limits(behavior, max_ws_message_size)) {
                return error.InvalidWebSocketLimits;
            }
            if (behavior.compression == .permessage_deflate) try self.ensure_ws_compression();
            try self.router.ws(path, behavior);
            return self;
        }

        /// Registers a WebTransport datagram handler for one session path.
        ///
        /// `path` must stay valid for the application lifetime; string literals
        /// are the intended form. The application itself is the handler context
        /// unless `datagram_context` supplies another.
        pub fn datagram(
            self: *Self,
            path: []const u8,
            handler: datagram_module.Handler,
        ) !*Self {
            return self.datagram_context(path, self, handler);
        }

        /// Registers a datagram handler with explicit caller-owned context.
        pub fn datagram_context(
            self: *Self,
            path: []const u8,
            context: *anyopaque,
            handler: datagram_module.Handler,
        ) !*Self {
            try self.ensure_routes_mutable();
            try self.datagram_router.register(path, handler, context);
            return self;
        }

        /// Delivers one inbound WebTransport datagram to its registered path.
        ///
        /// The payload is copied into the connection ring before the handler
        /// runs; the handler receives the caller's slice, which stays valid
        /// only for the call. Returns false for an unregistered path or a full
        /// ring, and a rejected datagram increments `datagrams_dropped`.
        pub fn dispatch_datagram(
            self: *Self,
            connection_index: usize,
            session_id: u64,
            sequence_number: u64,
            path: []const u8,
            payload: []const u8,
        ) bool {
            const route = self.datagram_router.find(path) orelse return false;
            const ring = self.datagram_ring_for(connection_index) orelse return false;
            ring.push(.{
                .session_id = session_id,
                .sequence_number = sequence_number,
                .payload = payload,
            }) catch |err| switch (err) {
                error.Full => {
                    ring.note_dropped();
                    if (self.metrics_registry) |registry| registry.add(.datagrams_dropped, 1);
                    return false;
                },
                error.PayloadTooLarge, error.InvalidCapacity, error.InvalidStride => {
                    if (self.metrics_registry) |registry| registry.add(.datagrams_dropped, 1);
                    return false;
                },
            };
            if (self.metrics_registry) |registry| registry.add(.datagrams_received, 1);
            route.handler(route.context, session_id, payload);
            return true;
        }

        /// Removes the oldest queued datagram for one connection.
        pub fn next_datagram(
            self: *Self,
            connection_index: usize,
        ) ?datagram_ring_module.DatagramView {
            const ring = self.datagram_ring_for(connection_index) orelse return null;
            return ring.pop();
        }

        /// Returns the fixed-capacity registry, or null when observability is
        /// disabled in the configuration.
        pub fn metrics(self: *Self) ?*metrics_module.Registry {
            return self.metrics_registry;
        }

        fn datagram_ring_for(self: *Self, connection_index: usize) ?*DatagramRing {
            if (connection_index >= self.datagram_rings.len) return null;
            return &self.datagram_rings[connection_index];
        }

        fn ensure_routes_mutable(self: *const Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.routes_locked) return error.RoutesLocked;
        }

        /// Installs the hidden metrics route once, before routes are locked.
        fn install_observability(self: *Self) !void {
            if (!self.metrics_enabled or self.metrics_registry == null) return;
            if (self.metrics_installed) return;
            _ = try self.get_context(self.metrics_path, self, serve_metrics);
            self.metrics_installed = true;
        }

        fn ensure_ws_compression(self: *Self) !void {
            if (self.ws_deflate != null) return;

            var context = try DeflateContext.init(6);
            errdefer context.deinit();
            const per_connection = try context.scratch_bound(max_ws_message_size);

            if (self.ws_compression_storage.len != 0) {
                // ServerConfig pre-reserved paired scratch inside the startup slab.
                if (per_connection > self.ws_compression_capacity) {
                    return error.CompressionScratchTooSmall;
                }
                self.ws_deflate = context;
                return;
            }

            const per_connection_storage = std.math.mul(
                usize,
                per_connection,
                2,
            ) catch return error.SizeOverflow;
            const storage_len = std.math.mul(
                usize,
                max_connections,
                per_connection_storage,
            ) catch return error.SizeOverflow;
            const storage = try std.heap.page_allocator.alloc(u8, storage_len);

            self.ws_compression_capacity = per_connection;
            self.ws_compression_storage = storage;
            self.ws_compression_owned = true;
            self.ws_deflate = context;
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            if (self.shutting_down) {
                close_socket_now(socket);
                return;
            }
            const conn = self.pool.acquire() orelse {
                // No I/O was registered for this descriptor, so direct close is safe.
                close_socket_now(socket);
                return;
            };

            conn.req = .{};
            conn.parser = .{ .max_body_size = self.max_body_size };
            conn.reset_protocol() catch {
                _ = self.pool.release(conn);
                close_socket_now(socket);
                return;
            };
            // HTTP/2 bodies share the HTTP/1 configured ceiling; the compiled
            // session slab remains the hard capacity when the config is larger.
            conn.h2.request_body_limit = self.max_body_size;
            conn.ssl = null;
            conn.network_bio = null;
            conn.is_tls_handshake_done = false;
            conn.tls_shutdown_started = false;
            conn.read_active = false;
            conn.read_cancel_active = false;
            conn.write_cancel_active = false;
            conn.request_len = 0;
            conn.write_head = 0;
            conn.write_len = 0;
            conn.write_in_flight_len = 0;
            conn.is_writing = false;
            conn.close_complete = false;
            conn.was_backpressured = false;
            conn.close_when_drained = false;
            conn.closing = false;
            conn.expect_continue_sent = false;
            conn.suppress_response_body = false;
            conn.dispatch_suspended = false;
            conn.pending_request_consumed = 0;
            conn.pending_close_requested = false;
            conn.async_response_state.cancel();

            const now = std.Io.Clock.now(.awake, self.io);
            conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

            conn.socket = socket;
            conn.loop = &self.loop.xev_loop;
            // acquire only returns pointers into this pool's contiguous slab.
            const connection_index = self.pool.index_of(conn) orelse unreachable;
            const request_start = connection_index * self.request_buffer_stride;
            conn.request_buffer = self.request_buffers[request_start .. request_start + self.request_buffer_stride];
            conn.reject_policy = &self.reject_policy;
            const message_start = connection_index * max_ws_message_size;
            conn.ws_message_buffer = self.ws_message_storage[message_start .. message_start + max_ws_message_size];
            if (self.ws_deflate) |*context| {
                const buffers = compression_buffers(
                    self.ws_compression_storage,
                    self.ws_compression_capacity,
                    connection_index,
                ) orelse unreachable;
                conn.ws_compression_buffer = buffers.incoming;
                conn.ws_compression_output_buffer = buffers.outgoing;
                conn.ws_deflate = context;
            } else {
                conn.ws_compression_buffer = &.{};
                conn.ws_compression_output_buffer = &.{};
                conn.ws_deflate = null;
            }
            const write_start = connection_index * write_queue_size;
            conn.write_queue = self.write_queue_storage[write_start .. write_start + write_queue_size];
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            conn.pool_ptr = &self.pool;
            conn.io = self.io;
            conn.metrics = self.metrics_registry;
            if (self.metrics_registry) |registry| registry.add(.connections_accepted, 1);
            if (self.dev_log_enabled) {
                const sink = dev_log_module.thread_sink();
                conn.dev_log = sink;
                sink.record(.{
                    .timestamp_ms = dev_log_module.now_ms(self.io),
                    .level = .info,
                    .direction = .data_in,
                    .event = .{ .connection_opened = .{ .index = connection_index } },
                });
            } else {
                conn.dev_log = null;
            }
            conn.on_close_cb = (struct {
                fn cb(pool_ptr: *anyopaque, c: *core_tcp.TcpConnection) void {
                    const pool: *Pool = @ptrCast(@alignCast(pool_ptr));
                    if (c.metrics) |registry| registry.add(.connections_closed, 1);
                    if (c.dev_log) |sink| {
                        sink.record(.{
                            .timestamp_ms = dev_log_module.now_ms(c.io),
                            .level = .info,
                            .direction = .data_out,
                            .event = .{
                                .connection_closed = .{
                                    .index = pool.index_of(c) orelse 0,
                                },
                            },
                        });
                    }
                    _ = pool.release(c);
                }
            }).cb;

            if (self.tls_ctx) |tls| {
                conn.init_tls(tls.ctx) catch {
                    core_tcp.close_connection(conn);
                    return;
                };
            }
            core_tcp.read_start(conn, &self.loop);
        }

        /// Binds and starts the POSIX TCP listener, locking route mutation.
        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.server != null) return error.AlreadyListening;

            const server = try core_tcp.init_server(address, port, on_new_connection, self);
            errdefer close_socket_now(server.listener);

            var sweeper: ?core_timer.connection_sweeper(Pool, idle_timeout_ms) = null;
            if (idle_timeout_ms != 0 or self.router.has_ws_heartbeats()) {
                sweeper = try core_timer.connection_sweeper(Pool, idle_timeout_ms).init(self.io, &self.pool);
            }

            try self.install_observability();
            self.routes_locked = true;
            self.server = server;
            self.sweeper = sweeper;
            core_tcp.accept_start(&self.server.?, &self.loop);
            if (self.sweeper) |*sw| {
                sw.start(&self.loop);
            }

            if (self.dev_log_enabled) {
                self.write_ready_summary(
                    if (self.tls_ctx != null) "https" else "http",
                    address,
                    port,
                );
            } else {
                log.info("server listening on {s}:{d}", .{ address, port });
            }
        }

        /// Binds and starts the UDP/QUIC listener, locking route mutation.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (!self.http3_enabled or self.quic_tls_ctx == null) return error.Http3NotInitialized;
            if (self.quic_transport != null) return error.AlreadyListening;

            self.quic_transport = try QuicTransport.init(
                self.quic_tls_ctx.?.ctx,
                &self.router,
                address,
                port,
            );
            errdefer {
                if (self.quic_transport) |*transport| transport.deinit();
                self.quic_transport = null;
            }
            try self.quic_transport.?.start(self.loop.get_xev_loop());

            try self.install_observability();
            self.routes_locked = true;

            if (self.dev_log_enabled) {
                self.write_ready_summary("https", address, port);
            } else {
                log.info("http/3 server listening on {s}:{d}", .{ address, port });
            }
        }

        /// Runs the event loop until shutdown completes or no work remains.
        pub fn run(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.running) return error.ApplicationAlreadyRunning;

            self.running = true;
            defer self.running = false;
            // Apps that never call a listen function still get the wordmark.
            self.write_startup_banner();
            try self.start_file_watch();
            self.arm_cluster_wakeup();
            try core_loop.run(&self.loop);
            self.flush_dev_log();
            if (self.shutting_down) try self.verify_shutdown();
        }

        /// Arms the recursive file watcher configured for the dev log.
        fn start_file_watch(self: *Self) !void {
            if (self.watch_paths.len == 0) return;
            self.watcher = .{};
            self.watcher.?.start(self.io, self.loop.get_xev_loop(), self.watch_paths) catch |err| {
                self.watcher = null;
                return err;
            };
        }

        /// Writes this worker's startup wordmark once, before the first
        /// listening line and sized to the output terminal.
        fn write_startup_banner(self: *Self) void {
            if (!self.dev_log_enabled) return;
            const sink = dev_log_module.thread_sink();
            sink.enable(self.io, self.dev_log_file orelse std.Io.File.stderr());
            sink.record_banner(terminal_module.columns(sink.file));
        }

        /// Writes the wordmark and the Vite-style ready summary for one bound
        /// listener.
        fn write_ready_summary(self: *Self, scheme: []const u8, address: []const u8, port: u16) void {
            if (!self.dev_log_enabled) return;
            self.write_startup_banner();
            const host = dev_log_module.display_host(address);
            dev_log_module.thread_sink().record_ready(.{
                .elapsed_ns = self.ready_elapsed_ns(),
                .scheme = scheme,
                .host = host,
                .host_is_ipv6 = std.mem.indexOfScalar(u8, host, ':') != null,
                .port = port,
                .log_target = if (self.dev_log_file == null) "stderr" else "bound file",
            });
        }

        /// Nanoseconds between application construction and listener startup.
        fn ready_elapsed_ns(self: *const Self) u64 {
            const now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
            if (now_ns <= 0) return 0;
            const now: u64 = @intCast(now_ns);
            return now -| self.ready_started_ns;
        }

        /// Overrides the development-log output file; defaults to stderr.
        ///
        /// Call it before `listen` or `run` so the startup wordmark uses it.
        pub fn set_dev_log_file(self: *Self, file: std.Io.File) void {
            self.dev_log_file = file;
        }

        /// Writes any pending development-log bytes for this worker.
        pub fn flush_dev_log(self: *Self) void {
            if (!self.dev_log_enabled) return;
            _ = dev_log_module.thread_sink().flush();
        }

        /// Records every counter of the hidden registry in this worker's log.
        pub fn log_metrics(self: *Self) void {
            if (!self.dev_log_enabled) return;
            const registry = self.metrics_registry orelse return;
            const sink = dev_log_module.thread_sink();
            sink.record_metrics(dev_log_module.now_ms(self.io), .data_out, registry);
        }

        /// Publishes one message to every matching bounded subscription.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) usize {
            return self.pubsub.publish(topic, message, is_text);
        }

        /// Returns a heap-backed thread-per-core manager for this App type.
        pub fn cluster(comptime worker_count: usize) type {
            if (worker_count == 0) @compileError("cluster worker count must be greater than zero");

            return struct {
                const Cluster = @This();

                /// Concrete application type every worker owns.
                pub const Worker = Self;

                allocator: std.mem.Allocator,
                workers: []Self,
                inboxes: []ClusterInbox,
                threads: []std.Thread,
                thread_count: usize = 0,
                worker_failed: std.atomic.Value(bool) = .init(false),
                startup_options: ClusterOptions = .{},
                cores: core_affinity.CoreSelection = .{},
                deinitialized: bool = false,

                pub fn init(allocator: std.mem.Allocator, io: std.Io) !Cluster {
                    return init_with_options(allocator, io, .{});
                }

                /// Builds every worker slab on this thread; each worker then owns
                /// its slab exclusively for its whole lifetime.
                pub fn init_with_options(
                    allocator: std.mem.Allocator,
                    io: std.Io,
                    startup_options: ClusterOptions,
                ) !Cluster {
                    const workers = try allocator.alloc(Self, worker_count);
                    errdefer allocator.free(workers);
                    const inboxes = try allocator.alloc(ClusterInbox, worker_count);
                    errdefer allocator.free(inboxes);
                    const threads = try allocator.alloc(std.Thread, worker_count);
                    errdefer allocator.free(threads);
                    for (inboxes) |*inbox| inbox.* = .{};

                    var initialized: usize = 0;
                    errdefer {
                        for (workers[0..initialized]) |*app_worker| app_worker.deinit();
                    }
                    for (workers, 0..) |*app_worker, index| {
                        app_worker.* = try Self.init(io);
                        initialized += 1;
                        try app_worker.attach_cluster_inbox(&inboxes[index]);
                    }
                    return .{
                        .allocator = allocator,
                        .workers = workers,
                        .inboxes = inboxes,
                        .threads = threads,
                        .startup_options = startup_options,
                        .cores = core_affinity.CoreSelection.init(),
                    };
                }

                pub fn deinit(self: *Cluster) void {
                    if (self.deinitialized) return;
                    if (self.thread_count != 0) {
                        std.debug.panic("cannot deinitialize a running cluster", .{});
                    }
                    for (self.workers) |*app_worker| app_worker.deinit();
                    self.allocator.free(self.threads);
                    self.allocator.free(self.inboxes);
                    self.allocator.free(self.workers);
                    self.workers = &.{};
                    self.inboxes = &.{};
                    self.threads = &.{};
                    self.deinitialized = true;
                }

                /// Applies the same route configuration callback to every worker.
                ///
                /// `callback` accepts any comptime function callable as
                /// `fn (*Worker, usize) !void`.
                pub fn configure(self: *Cluster, comptime callback: anytype) !void {
                    for (self.workers, 0..) |*app_worker, index| try callback(app_worker, index);
                }

                pub fn worker(self: *Cluster, index: usize) ?*Self {
                    if (index >= self.workers.len) return null;
                    return &self.workers[index];
                }

                /// Binds every worker to one shared kernel port.
                pub fn listen(self: *Cluster, address: []const u8, port: u16) !void {
                    var listening: usize = 0;
                    errdefer {
                        // Preserve the original bind error during partial cleanup.
                        for (self.workers[0..listening]) |*app_worker| app_worker.shutdown() catch {};
                    }
                    for (self.workers) |*app_worker| {
                        try app_worker.listen_reuse_port(address, port);
                        listening += 1;
                    }
                }

                /// Broadcasts through bounded per-worker queues and wakes each loop.
                pub fn publish(
                    self: *Cluster,
                    topic: []const u8,
                    message: []const u8,
                    is_text: bool,
                ) !usize {
                    if (topic.len == 0) return error.EmptyTopic;
                    if (topic.len > @import("../ws/pubsub.zig").max_topic_length) return error.TopicTooLong;
                    if (message.len > max_ws_message_size) return error.ClusterMessageTooLarge;

                    var queued: usize = 0;
                    for (self.inboxes, self.workers) |*inbox, *app_worker| {
                        inbox.push(topic, message, is_text) catch continue;
                        app_worker.notify_cluster();
                        queued += 1;
                    }
                    return queued;
                }

                /// Runs all workers on native threads and joins them on shutdown.
                pub fn run(self: *Cluster) !void {
                    self.worker_failed.store(false, .release);
                    for (0..worker_count) |index| {
                        self.threads[index] = std.Thread.spawn(.{}, worker_main, .{ self, index }) catch |err| {
                            self.request_shutdown();
                            for (self.threads[0..self.thread_count]) |thread| thread.join();
                            self.thread_count = 0;
                            return err;
                        };
                        self.thread_count += 1;
                    }
                    for (self.threads[0..self.thread_count]) |thread| thread.join();
                    self.thread_count = 0;
                    if (self.worker_failed.load(.acquire)) return error.ClusterWorkerFailed;
                }

                /// Requests event-loop-confined shutdown for every worker.
                pub fn request_shutdown(self: *Cluster) void {
                    for (self.workers) |*app_worker| app_worker.request_cluster_shutdown();
                }

                fn worker_main(self: *Cluster, index: usize) void {
                    pin_worker(self, index);
                    self.workers[index].run() catch {
                        self.worker_failed.store(true, .release);
                        self.request_shutdown();
                    };
                }

                /// Pins one worker to its core; failure keeps startup graceful.
                fn pin_worker(self: *Cluster, index: usize) void {
                    if (!self.startup_options.cpu_affinity) return;
                    const cpu = self.cores.cpu(index) orelse return;
                    core_affinity.pin_current_thread(cpu) catch |err| {
                        // Restricted cpusets and affinity-less platforms are
                        // expected; only the first worker reports them.
                        if (index == 0) {
                            log.debug("worker affinity unavailable: {}", .{err});
                        }
                    };
                }
            };
        }

        fn listen_reuse_port(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.server != null) return error.AlreadyListening;

            const server = try core_tcp.init_reuse_port_server(address, port, on_new_connection, self);
            errdefer close_socket_now(server.listener);
            var sweeper: ?core_timer.connection_sweeper(Pool, idle_timeout_ms) = null;
            if (idle_timeout_ms != 0 or self.router.has_ws_heartbeats()) {
                sweeper = try core_timer.connection_sweeper(Pool, idle_timeout_ms).init(self.io, &self.pool);
            }
            self.routes_locked = true;
            self.server = server;
            self.sweeper = sweeper;
            core_tcp.accept_start(&self.server.?, &self.loop);
            if (self.sweeper) |*sw| sw.start(&self.loop);
        }

        fn attach_cluster_inbox(self: *Self, inbox: *ClusterInbox) !void {
            if (self.cluster_inbox != null) return error.ClusterAlreadyAttached;
            self.cluster_wakeup = try xev.Async.init();
            self.cluster_inbox = inbox;
        }

        fn arm_cluster_wakeup(self: *Self) void {
            if (self.cluster_wakeup_active) return;
            if (self.cluster_wakeup == null) return;
            self.cluster_wakeup_active = true;
            self.cluster_wakeup.?.wait(
                self.loop.get_xev_loop(),
                &self.cluster_completion,
                Self,
                self,
                on_cluster_wakeup,
            );
        }

        fn notify_cluster(self: *Self) void {
            // A full or stopping loop will observe the queue on its next wakeup.
            if (self.cluster_wakeup) |*wakeup| wakeup.notify() catch {};
        }

        fn request_cluster_shutdown(self: *Self) void {
            self.cluster_stop_requested.store(true, .release);
            self.notify_cluster();
        }

        fn on_cluster_wakeup(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch {
                self.cluster_wakeup_active = false;
                return .disarm;
            };
            if (self.cluster_stop_requested.load(.acquire)) {
                self.cluster_wakeup_active = false;
                self.begin_shutdown();
                return .disarm;
            }

            const inbox = self.cluster_inbox orelse {
                self.cluster_wakeup_active = false;
                return .disarm;
            };
            var topic_buffer: [@import("../ws/pubsub.zig").max_topic_length]u8 = undefined;
            var message_buffer: [max_ws_message_size]u8 = undefined;
            while (inbox.pop_copy(&topic_buffer, &message_buffer)) |message| {
                _ = self.pubsub.publish(message.topic, message.payload, message.is_text);
            }
            return .rearm;
        }

        /// Serves the hidden Prometheus endpoint from a fixed stack buffer.
        ///
        /// The formatter writes straight into the buffer and the response
        /// engine copies it to the transport, so metric serving performs no
        /// heap allocation at all.
        fn serve_metrics(context: *anyopaque, _: *Request, response: *Response) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const registry = self.metrics_registry orelse {
                response.end("404 Not Found", "") catch {};
                return;
            };

            var histogram: ?ebpf_module.Histogram = null;
            if (self.ebpf_map_fd >= 0) {
                if (ebpf_module.read_latency_histogram(self.ebpf_map_fd)) |observed| {
                    histogram = observed;
                } else |_| {
                    // A transient kernel read still leaves the counters usable.
                }
            }
            const buckets: ?[]const u64 = if (histogram) |observed|
                observed.buckets[0..]
            else
                null;

            var buffer: [4096]u8 = undefined;
            const body = registry.write_prometheus(buckets, &buffer) catch {
                response.end("500 Internal Server Error", "metrics buffer exhausted") catch {};
                return;
            };
            response.end_with_headers(
                "200 OK",
                "Content-Type: text/plain; version=0.0.4\r\n",
                body,
            ) catch {};
        }

        fn serve_openapi(context: *anyopaque, _: *Request, response: *Response) void {
            const router: *const radix.Router = @ptrCast(@alignCast(context));
            var buffer: [32 * 1024]u8 = undefined;
            const document = router.write_openapi(&buffer, .{}) catch {
                // The handler ABI cannot propagate a response write failure.
                response.end("500 Internal Server Error", "OpenAPI document exceeds capacity") catch {};
                return;
            };
            // A disconnected peer cannot receive a late handler error.
            response.end_with_headers(
                "200 OK",
                "Content-Type: application/json\r\n",
                document,
            ) catch {};
        }
    };
}

/// Separate borrowed scratch slices for inbound and outbound compression.
pub const CompressionBuffers = struct {
    /// Scratch storage for compressed client messages and decode tails.
    incoming: []u8,
    /// Scratch storage for compressed server messages.
    outgoing: []u8,
};

/// Selects one connection's disjoint compression buffers from caller storage.
pub fn compression_buffers(
    storage: []u8,
    direction_capacity: usize,
    connection_index: usize,
) ?CompressionBuffers {
    if (direction_capacity == 0) return null;
    const stride = std.math.mul(usize, direction_capacity, 2) catch return null;
    const start = std.math.mul(usize, connection_index, stride) catch return null;
    const incoming_end = std.math.add(usize, start, direction_capacity) catch return null;
    const outgoing_end = std.math.add(usize, incoming_end, direction_capacity) catch return null;
    if (outgoing_end > storage.len) return null;

    return .{
        .incoming = storage[start..incoming_end],
        .outgoing = storage[incoming_end..outgoing_end],
    };
}

/// bpffs path where the latency histogram map is pinned by the loader.
const ebpf_map_path = "/sys/fs/bpf/uwz_latency";

/// Narrows a bypass startup error into the reported fallback reason.
fn map_xdp_error(err: anyerror) xdp_transport_module.FallbackReason {
    return switch (err) {
        error.PermissionDenied => .permission_denied,
        error.InvalidConfiguration, error.InvalidArgument => .invalid_configuration,
        else => .kernel_unavailable,
    };
}

fn close_socket_now(socket: xev.TCP) void {
    core_tcp.close_socket(socket.fd);
}
