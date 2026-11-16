const std = @import("std");
const c = @import("c");
const pool = @import("../core/pool.zig");
const Router = @import("../router/radix.zig").Router;
const api = @import("lsquic_api.zig");
const stream = @import("stream.zig");
const backend = @import("webtransport/backend.zig");
const runtime = @import("webtransport/runtime.zig");
const wt_binding = @import("webtransport/binding.zig");
const webtransport = @import("webtransport.zig");
const capsule_stream = @import("webtransport/capsule_stream.zig");
const pending = @import("webtransport/pending_datagrams.zig");
const child_runtime = @import("webtransport/child_runtime.zig");
const child_io = @import("webtransport/child_io.zig");
const Response = @import("../http/response.zig").Response;
const HeaderSet = stream.HeaderSet;

const log = std.log.scoped(.quic);

/// Reports that the build includes the lsquic-backed QUIC engine.
pub const available = true;

/// lsquic congestion controller identifier for BBRv1 (`es_cc_algo`).
const cc_algo_bbr: c_uint = 2;

const pending_per_connection = 4;
const pending_lifetime_us = std.time.us_per_s;

/// Startup-only binding and pending-storage failures.
pub const WebTransportBindError = runtime.PendingStorageError || error{
    QuicEngineAlreadyStarted,
    WebTransportAlreadyBound,
    InvalidDatagramLimit,
};

/// One fixed-size outbound UDP packet buffer owned by the engine packet pool.
pub const PacketSlot = struct {
    bytes: [api.max_udp_payload_size]u8,
};

/// Returns a bounded QUIC server engine type.
///
/// `capacity` bounds concurrent connections and request streams;
/// `response_capacity` reserves response body bytes per stream during `init`;
/// `route_param_extra_capacity` reserves capture slots per stream beyond the
/// inline `Request` arrays (zero keeps every capture inline);
/// `stream_capacities` fixes every per-stream HTTP/3 storage region and field
/// cap. The engine allocates its pools and byte slabs once in `init`, and
/// `deinit` releases them; nothing on the datagram path allocates.
pub fn quic_engine(
    comptime capacity: usize,
    comptime response_capacity: usize,
    comptime route_param_extra_capacity: usize,
    comptime stream_capacities: stream.Capacities,
) type {
    if (capacity == 0) @compileError("QUIC capacity must be greater than zero");
    if (capacity > std.math.maxInt(c_uint)) @compileError("QUIC capacity exceeds lsquic limits");
    if (response_capacity == 0) @compileError("HTTP/3 response capacity must be greater than zero");
    if (stream_capacities.request_header_size == 0) {
        @compileError("HTTP/3 request header capacity must be greater than zero");
    }
    // `es_max_header_list_size` is a u32; a larger field list cannot be carried.
    if (stream_capacities.request_header_size > std.math.maxInt(c_uint)) {
        @compileError("HTTP/3 request header capacity exceeds lsquic limits");
    }
    if (stream_capacities.request_body_size == 0) {
        @compileError("HTTP/3 request body capacity must be greater than zero");
    }
    if (stream_capacities.response_header_size == 0 or
        stream_capacities.response_header_size > std.math.maxInt(u16))
    {
        @compileError("HTTP/3 response header capacity must fit u16 offsets");
    }
    if (stream_capacities.response_header_count == 0) {
        @compileError("HTTP/3 response header count must be greater than zero");
    }
    if (stream_capacities.decoded_header_count == 0) {
        @compileError("HTTP/3 decoded header count must be greater than zero");
    }
    if (capacity > std.math.maxInt(usize) / 4) @compileError("QUIC packet capacity overflows usize");
    if (capacity > std.math.maxInt(usize) / 2) @compileError("HTTP/3 header slot count overflows usize");
    if (route_param_extra_capacity > std.math.maxInt(usize) / 2) {
        @compileError("HTTP/3 route parameter capacity overflows usize");
    }
    const route_param_pointer_count = route_param_extra_capacity * 2;
    if (route_param_pointer_count != 0 and
        capacity > std.math.maxInt(usize) / route_param_pointer_count)
    {
        @compileError("HTTP/3 route parameter storage size overflows usize");
    }
    const route_param_slot_count = capacity * route_param_pointer_count;
    const header_slot_count = capacity * 2;
    if (header_slot_count > std.math.maxInt(usize) / stream_capacities.request_header_size) {
        @compileError("HTTP/3 header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream_capacities.request_body_size) {
        @compileError("HTTP/3 request storage size overflows usize");
    }
    if (stream_capacities.request_body_size >
        std.math.maxInt(usize) - stream_capacities.request_header_size)
    {
        @compileError("HTTP/3 receive capacity overflows usize");
    }
    const stream_receive_capacity =
        stream_capacities.request_header_size + stream_capacities.request_body_size;
    // `es_init_max_stream_data_bidi_remote` is a u32 as well.
    if (stream_receive_capacity > std.math.maxInt(c_uint)) {
        @compileError("HTTP/3 receive capacity exceeds lsquic limits");
    }
    if (capacity > std.math.maxInt(usize) / stream_receive_capacity) {
        @compileError("HTTP/3 connection flow-control capacity overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream_capacities.response_header_size) {
        @compileError("HTTP/3 response header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / response_capacity) {
        @compileError("HTTP/3 response storage size overflows usize");
    }
    if (stream_capacities.header_extra_capacity > std.math.maxInt(usize) / 2) {
        @compileError("HTTP/3 header extra capacity overflows usize");
    }
    const header_extra_pointer_count = stream_capacities.header_extra_capacity * 2;
    if (header_extra_pointer_count != 0 and
        capacity > std.math.maxInt(usize) / header_extra_pointer_count)
    {
        @compileError("HTTP/3 header extra storage size overflows usize");
    }
    const header_extra_slot_count = capacity * header_extra_pointer_count;

    const packet_slot_count = @max(@as(usize, 16), capacity * 4);
    const QuicStream = stream.stream_with(stream.lsquic_stream_io, stream_capacities);
    const StreamPool = pool.freelist_pool(QuicStream, capacity);
    const HeaderPool = pool.freelist_pool(HeaderSet, header_slot_count);
    const PacketPool = pool.freelist_pool(PacketSlot, packet_slot_count);
    const Connections = runtime.connection_table(capacity);

    return struct {
        const Self = @This();

        /// One sidecar per global stream slot, independent of connection count.
        const StreamContext = struct {
            http: *QuicStream,
            state: runtime.StreamState = .{},
            capsules: capsule_stream.Decoder = .init(.{ .ignore_flow_control = true }),
            close_received: bool = false,
            pending_reset: ?u64 = null,
            child: ?child_runtime.State = null,
            child_actions: child_io.Actions = .{},
            child_retry_counted: bool = false,
        };

        engine: ?*c.lsquic_engine = null,
        ssl_ctx: *c.SSL_CTX = undefined,
        router: *const Router = undefined,
        udp_fd: std.posix.socket_t = api.invalid_socket,
        local_address: api.Sockaddr = .{},
        settings: c.lsquic_engine_settings = std.mem.zeroes(c.lsquic_engine_settings),
        stream_interface: c.lsquic_stream_if = std.mem.zeroes(c.lsquic_stream_if),
        header_interface: c.lsquic_hset_if = std.mem.zeroes(c.lsquic_hset_if),
        packet_interface: c.lsquic_packout_mem_if = std.mem.zeroes(c.lsquic_packout_mem_if),
        engine_api: c.lsquic_engine_api = std.mem.zeroes(c.lsquic_engine_api),
        stream_pool: StreamPool,
        connections: Connections,
        stream_contexts: []StreamContext,
        binding: ?wt_binding.Binding = null,
        pending_datagrams: ?runtime.PendingDatagramStorage = null,
        header_pool: HeaderPool,
        packet_pool: PacketPool,
        header_storage: []u8,
        request_body_storage: []u8,
        response_header_storage: []u8,
        response_body_storage: []u8,
        /// Per-stream capture slots beyond the inline `Request` arrays;
        /// empty when `route_param_extra_capacity` is zero.
        route_param_storage: [][]const u8,
        /// Per-stream request-field slots beyond the inline `Request` arrays;
        /// empty when `stream_capacities.header_extra_capacity` is zero.
        header_extra_storage: [][]const u8,
        active_connections: usize = 0,
        pending_reset_count: usize = 0,
        pending_child_count: usize = 0,
        child_retry_count: usize = 0,
        children_shutdown: bool = false,
        global_acquired: bool = false,
        /// Depth of active lsquic callbacks; cooldown must not re-enter them.
        callback_depth: usize = 0,
        /// Cooldown requested while an engine callback was active.
        cooldown_pending: bool = false,
        in_cooldown: bool = false,

        /// Allocates all stream, header, packet, and payload slabs.
        pub fn init() !Self {
            // lsxpack field lengths are u16. Keep the shared HTTP/1 limit free
            // to exceed this, but never allocate an HTTP/3 engine that cannot
            // represent its own request-header storage.
            if (stream_capacities.request_header_size > std.math.maxInt(u16)) {
                return error.InvalidHttp3Capacity;
            }
            var stream_pool = try StreamPool.init();
            errdefer stream_pool.deinit();
            var connections = try Connections.init();
            errdefer connections.deinit();
            const stream_contexts = try std.heap.page_allocator.alloc(StreamContext, capacity);
            errdefer std.heap.page_allocator.free(stream_contexts);
            var header_pool = try HeaderPool.init();
            errdefer header_pool.deinit();
            var packet_pool = try PacketPool.init();
            errdefer packet_pool.deinit();

            const header_storage = try std.heap.page_allocator.alloc(
                u8,
                header_slot_count * stream_capacities.request_header_size,
            );
            errdefer std.heap.page_allocator.free(header_storage);
            const request_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream_capacities.request_body_size,
            );
            errdefer std.heap.page_allocator.free(request_body_storage);
            const response_header_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream_capacities.response_header_size,
            );
            errdefer std.heap.page_allocator.free(response_header_storage);
            const response_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * response_capacity,
            );
            errdefer std.heap.page_allocator.free(response_body_storage);
            // A zero slot count allocates nothing; the allocator returns an
            // empty slice whose free is a no-op.
            const route_param_storage = try std.heap.page_allocator.alloc(
                []const u8,
                route_param_slot_count,
            );
            errdefer std.heap.page_allocator.free(route_param_storage);
            const header_extra_storage = try std.heap.page_allocator.alloc(
                []const u8,
                header_extra_slot_count,
            );
            errdefer std.heap.page_allocator.free(header_extra_storage);

            return .{
                .stream_pool = stream_pool,
                .connections = connections,
                .stream_contexts = stream_contexts,
                .header_pool = header_pool,
                .packet_pool = packet_pool,
                .header_storage = header_storage,
                .request_body_storage = request_body_storage,
                .response_header_storage = response_header_storage,
                .response_body_storage = response_body_storage,
                .route_param_storage = route_param_storage,
                .header_extra_storage = header_extra_storage,
            };
        }

        /// Applies the fixed engine policy over lsquic's defaults.
        ///
        /// BBRv1 paces against the bottleneck bandwidth estimate, which keeps
        /// queues short and tail latency low on lossy paths; lsquic's default
        /// adaptive controller drops to CUBIC at low RTT.
        pub fn apply_settings(settings: *c.lsquic_engine_settings) void {
            c.lsquic_engine_init_settings(settings, c.LSENG_HTTP_SERVER);
            settings.es_cc_algo = cc_algo_bbr;
            // BBR depends on pacing; pin it so a future default cannot weaken it.
            settings.es_pace_packets = 1;
            settings.es_max_streams_in = @intCast(capacity);
            settings.es_max_inchoate = @intCast(capacity);
            settings.es_max_header_list_size = @intCast(stream_capacities.request_header_size);
            settings.es_max_header_sets = 1;
            settings.es_qpack_dec_max_size = 0;
            settings.es_qpack_dec_max_blocked = 0;
            settings.es_init_max_streams_bidi = @intCast(capacity);
            settings.es_init_max_stream_data_bidi_remote = @intCast(stream_receive_capacity);
            settings.es_init_max_data = @intCast(@min(
                capacity * stream_receive_capacity,
                std.math.maxInt(c_uint),
            ));
            settings.es_max_udp_payload_size_rx = api.max_udp_payload_size;
            settings.es_base_plpmtu = 1200;
            settings.es_max_plpmtu = 1472;
            settings.es_max_batch_size = 16;
            // TLS rejects 0-RTT, so retaining replayable packets has no application value.
            settings.es_max_delayed_0rtt_packets = 0;
            settings.es_rw_once = 1;
            settings.es_proc_time_thresh = 10_000;
        }

        /// Binds application callbacks before native engine construction.
        pub fn bind_webtransport(self: *Self, binding: wt_binding.Binding) WebTransportBindError!void {
            if (self.engine != null) return error.QuicEngineAlreadyStarted;
            if (self.binding != null) return error.WebTransportAlreadyBound;
            if (binding.max_payload == 0) return error.InvalidDatagramLimit;
            if (comptime backend.available) {
                self.pending_datagrams = try runtime.PendingDatagramStorage.init(
                    std.heap.page_allocator,
                    capacity * pending_per_connection,
                    .{
                        .payload_stride = api.max_udp_payload_size,
                        .per_connection_limit = pending_per_connection,
                        .lifetime_us = pending_lifetime_us,
                    },
                );
            }
            self.binding = binding;
        }

        /// Starts the engine and borrows its TLS context and router until `deinit`.
        pub fn start(
            self: *Self,
            ssl_ctx: *c.SSL_CTX,
            router: *const Router,
            udp_fd: std.posix.socket_t,
            local_address: std.Io.net.IpAddress,
        ) !void {
            if (self.engine != null) return error.QuicEngineAlreadyStarted;
            try api.acquire_global();
            self.global_acquired = true;
            errdefer {
                api.release_global();
                self.global_acquired = false;
            }

            self.ssl_ctx = ssl_ctx;
            self.router = router;
            self.udp_fd = udp_fd;
            self.local_address = api.Sockaddr.init(local_address);

            Self.apply_settings(&self.settings);
            if (self.binding != null and comptime backend.available) {
                std.debug.assert(backend.configure(&self.settings, .{}) == .ok);
                // Three HTTP critical streams must leave credit for bounded children.
                self.settings.es_init_max_streams_uni = std.math.add(c_uint, @intCast(capacity), 3) catch
                    std.math.maxInt(c_uint);
            }

            var settings_error: [256]u8 = undefined;
            if (c.lsquic_engine_check_settings(
                &self.settings,
                c.LSENG_HTTP_SERVER,
                &settings_error,
                settings_error.len,
            ) != 0) return error.InvalidLsquicSettings;

            self.stream_interface = std.mem.zeroes(c.lsquic_stream_if);
            self.stream_interface.on_new_conn = on_new_connection;
            self.stream_interface.on_conn_closed = on_connection_closed;
            self.stream_interface.on_new_stream = on_new_stream;
            self.stream_interface.on_read = on_stream_read;
            self.stream_interface.on_write = on_stream_write;
            self.stream_interface.on_close = on_stream_close;
            self.stream_interface.on_hset_in = on_header_set_available;
            self.stream_interface.on_datagram = on_datagram;
            self.stream_interface.on_reset = on_stream_reset;
            _ = backend.install_callbacks(&self.stream_interface, .{
                .settings = on_peer_settings,
                .child = on_webtransport_stream,
            });

            self.header_interface = std.mem.zeroes(c.lsquic_hset_if);
            self.header_interface.hsi_create_header_set = create_header_set;
            self.header_interface.hsi_prepare_decode = prepare_header_decode;
            self.header_interface.hsi_process_header = process_header;
            self.header_interface.hsi_discard_header_set = discard_header_set;

            self.packet_interface = std.mem.zeroes(c.lsquic_packout_mem_if);
            self.packet_interface.pmi_allocate = allocate_packet;
            self.packet_interface.pmi_release = release_packet;
            self.packet_interface.pmi_return = release_packet;

            self.engine_api = std.mem.zeroes(c.lsquic_engine_api);
            self.engine_api.ea_settings = &self.settings;
            self.engine_api.ea_stream_if = &self.stream_interface;
            self.engine_api.ea_stream_if_ctx = self;
            self.engine_api.ea_packets_out = packets_out;
            self.engine_api.ea_packets_out_ctx = self;
            self.engine_api.ea_get_ssl_ctx = get_ssl_context;
            self.engine_api.ea_hsi_if = &self.header_interface;
            self.engine_api.ea_hsi_ctx = self;
            self.engine_api.ea_pmi = &self.packet_interface;
            self.engine_api.ea_pmi_ctx = self;

            self.engine = c.lsquic_engine_new(c.LSENG_HTTP_SERVER, &self.engine_api) orelse {
                return error.LsquicEngineCreationFailed;
            };
        }

        /// Destroys the engine and releases every setup-time slab.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.callback_depth == 0);
            const native = self.engine;
            self.engine = null;
            if (native) |engine| {
                self.callback_depth += 1;
                c.lsquic_engine_destroy(engine);
                self.callback_depth -= 1;
            }
            self.udp_fd = api.invalid_socket;

            std.debug.assert(self.stream_pool.count_active() == 0);
            std.debug.assert(self.header_pool.count_active() == 0);
            std.debug.assert(self.packet_pool.count_active() == 0);
            std.debug.assert(self.active_connections == 0);
            std.debug.assert(self.pending_reset_count == 0);
            std.debug.assert(self.pending_child_count == 0);
            std.debug.assert(self.child_retry_count == 0);
            std.debug.assert(self.connections.pool.count_active() == 0);
            if (self.global_acquired) api.release_global();
            self.global_acquired = false;

            if (self.pending_datagrams) |*storage| storage.deinit(std.heap.page_allocator);
            self.pending_datagrams = null;
            std.heap.page_allocator.free(self.response_body_storage);
            std.heap.page_allocator.free(self.response_header_storage);
            std.heap.page_allocator.free(self.request_body_storage);
            std.heap.page_allocator.free(self.header_storage);
            std.heap.page_allocator.free(self.route_param_storage);
            std.heap.page_allocator.free(self.header_extra_storage);
            self.packet_pool.deinit();
            self.header_pool.deinit();
            std.heap.page_allocator.free(self.stream_contexts);
            self.connections.deinit();
            self.stream_pool.deinit();
        }

        /// Submits a datagram using the listener's bound local address.
        pub fn process_datagram(self: *Self, data: []const u8, peer: std.Io.net.IpAddress) void {
            self.process_datagram_native(data, peer, &self.local_address);
        }

        /// Submits a datagram with its actual packet-info destination.
        pub fn process_datagram_at(self: *Self, data: []const u8, peer: std.Io.net.IpAddress, local: std.Io.net.IpAddress) void {
            const address = api.Sockaddr.init(local);
            self.process_datagram_native(data, peer, &address);
        }

        fn process_datagram_native(self: *Self, data: []const u8, peer: std.Io.net.IpAddress, local: *const api.Sockaddr) void {
            const engine = self.engine orelse return;
            if (data.len == 0 or data.len > api.max_udp_payload_size) return;
            if (self.callback_depth != 0 or self.in_cooldown) return;

            self.callback_depth += 1;
            defer self.leave_callback();

            const peer_address = api.Sockaddr.init(peer);
            const result = c.lsquic_engine_packet_in(
                engine,
                data.ptr,
                data.len,
                local.ptr(),
                peer_address.ptr(),
                self,
                0,
            );
            if (result < 0) {
                log.warn("packet_in failed for {d}-byte datagram; dropping", .{data.len});
                return;
            }
            self.process_ready(engine);
        }

        /// Flushes pending packets and advances ready lsquic connections.
        pub fn process(self: *Self) void {
            const engine = self.engine orelse return;
            if (self.callback_depth != 0 or self.in_cooldown) return;
            self.callback_depth += 1;
            defer self.leave_callback();
            self.process_ready(engine);
        }

        fn process_ready(self: *Self, engine: *c.lsquic_engine) void {
            self.expire_pending_datagrams();
            self.expire_pending_children();
            if (c.lsquic_engine_has_unsent_packets(engine) != 0) {
                c.lsquic_engine_send_unsent_packets(engine);
            }
            c.lsquic_engine_process_conns(engine);
            self.retry_pending_resets();
            self.retry_child_actions();
        }

        /// Begins graceful engine shutdown and advances affected connections.
        ///
        /// Safe to call from inside an H3 callback: the engine defers the
        /// cooldown until the active `lsquic_engine_process_conns` unwinds,
        /// because lsquic asserts on nested processing.
        pub fn cooldown(self: *Self) void {
            if (self.engine == null) return;
            if (self.callback_depth != 0) {
                self.cooldown_pending = true;
                return;
            }
            self.run_cooldown();
        }

        fn leave_callback(self: *Self) void {
            self.callback_depth -= 1;
            if (self.callback_depth == 0 and self.cooldown_pending) {
                self.cooldown_pending = false;
                self.run_cooldown();
            }
        }

        fn run_cooldown(self: *Self) void {
            const engine = self.engine orelse return;
            if (self.in_cooldown) return;
            self.in_cooldown = true;
            defer self.in_cooldown = false;
            self.children_shutdown = true;
            self.cancel_children(null, null, .shutdown);
            self.cancel_pending_datagrams();
            c.lsquic_engine_cooldown(engine);
            c.lsquic_engine_process_conns(engine);
            self.retry_pending_resets();
            self.retry_child_actions();
        }

        /// Returns a bounded delay until the next engine service call.
        ///
        /// lsquic's earliest-advance tick still pulls the timer back in when
        /// work is pending; the one-second ceiling only keeps an idle listener
        /// from waking twenty times per second.
        pub fn next_timeout_ms(self: *Self) u64 {
            const engine = self.engine orelse return 1000;
            var microseconds: c_int = 0;
            var delay: u64 = 1000;
            if (c.lsquic_engine_earliest_adv_tick(engine, &microseconds) != 0) {
                if (microseconds <= 0) return 1;
                delay = std.math.clamp(@divTrunc(@as(u64, @intCast(microseconds)) + 999, 1000), 1, 1000);
            }
            var deadline: ?u64 = if (self.pending_datagrams) |*active| active.store.next_deadline() else null;
            if (self.pending_child_count != 0) {
                var streams = self.stream_pool.active.iterator(.{});
                while (streams.next()) |index| {
                    const state = if (self.stream_contexts[index].child) |*active| active else continue;
                    if (!state.pending_reserved) continue;
                    deadline = @min(deadline orelse state.deadline_us, state.deadline_us);
                }
            }
            const earliest = deadline orelse return delay;
            const binding = self.binding orelse return delay;
            const remaining = earliest -| binding.clock(binding.context);
            const rounded = remaining / 1000 + @intFromBool(remaining % 1000 != 0);
            return @min(delay, std.math.clamp(rounded, 1, 1000));
        }

        fn expire_pending_datagrams(self: *Self) void {
            const storage = if (self.pending_datagrams) |*active| active else return;
            if (storage.store.pending_count == 0) return;
            const binding = self.binding orelse return;
            storage.store.expire(binding.clock(binding.context));
        }

        fn cancel_pending_datagrams(self: *Self) void {
            const storage = if (self.pending_datagrams) |*active| active else return;
            var connections = self.connections.pool.active.iterator(.{});
            while (connections.next()) |index| {
                const slot = &self.connections.pool.storage[index];
                slot.unknown_early_disabled = true;
                storage.store.clear_connection(slot.handle);
            }
            std.debug.assert(storage.store.pending_count == 0);
            std.debug.assert(storage.store.terminal_count == 0);
        }

        fn retire_datagrams(self: *Self, connection: runtime.ConnectionHandle, id: u64) void {
            if (id & 3 != 0) return;
            const slot = self.connections.find(connection) orelse return;
            if (slot.native == null) return;
            const reason: child_runtime.CloseReason = if (native_connection_live(slot.native)) .session_closed else .connection_closed;
            self.cancel_children(connection, id, reason);
            const storage = if (self.pending_datagrams) |*active| active else return;
            if (slot.unknown_early_disabled and storage.store.pending_count == 0) return;
            if (storage.store.retire(.{ .connection = connection, .session_id = id }) == .exhausted) {
                slot.unknown_early_disabled = true;
            }
        }

        fn retire_stream_datagrams(self: *Self, context: *StreamContext) void {
            if (self.pending_datagrams == null) return;
            if (!context.state.lease.active) return;
            self.retire_datagrams(context.state.lease.connection, c.lsquic_stream_id(context.http.stream));
        }

        fn sync_child_retry(self: *Self, context: *StreamContext) void {
            const pending_action = context.child_actions.stop or context.child_actions.reset;
            if (context.child_retry_counted == pending_action) return;
            context.child_retry_counted = pending_action;
            if (pending_action) {
                self.child_retry_count += 1;
                return;
            }
            std.debug.assert(self.child_retry_count != 0);
            self.child_retry_count -= 1;
        }

        fn release_child_pending(self: *Self, context: *StreamContext) void {
            const state = if (context.child) |*active| active else return;
            if (!state.take_pending()) return;
            std.debug.assert(self.pending_child_count != 0);
            self.pending_child_count -= 1;
            const slot = self.connections.find(state.metadata.connection) orelse {
                log.err("child reservation lost its connection lease", .{});
                return;
            };
            std.debug.assert(slot.pending_child_count != 0);
            slot.pending_child_count -= 1;
        }

        fn cancel_child(self: *Self, context: *StreamContext, reason: child_runtime.CloseReason, code: u64) void {
            const state = if (context.child) |*active| active else return;
            if (state.phase == .closed) return;
            self.release_child_pending(context);
            const slot = self.connections.find(context.state.lease.connection);
            if (self.engine == null or slot == null or slot.?.native == null) {
                _ = state.begin_close(reason, code);
                context.child_actions = .{};
                self.sync_child_retry(context);
                return;
            }
            child_io.cancel(context.http.stream, state, &context.child_actions, reason, code);
            self.sync_child_retry(context);
        }

        fn cancel_children(self: *Self, connection: ?runtime.ConnectionHandle, id: ?u64, reason: child_runtime.CloseReason) void {
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                const context = &self.stream_contexts[index];
                const state = if (context.child) |*active| active else continue;
                if (state.phase == .closed) continue;
                if (connection != null and !std.meta.eql(connection.?, state.metadata.connection)) continue;
                if (id != null and id.? != state.metadata.session_id) continue;
                self.cancel_child(context, reason, webtransport.wt_session_gone);
            }
        }

        fn expire_pending_children(self: *Self) void {
            if (self.pending_child_count == 0) return;
            const binding = self.binding orelse return;
            const now = binding.clock(binding.context);
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                const context = &self.stream_contexts[index];
                const state = if (context.child) |*active| active else continue;
                if (!state.pending_reserved or state.deadline_us > now) continue;
                self.cancel_child(context, .expired, webtransport.wt_buffered_stream_rejected);
            }
        }

        fn retry_child_actions(self: *Self) void {
            if (self.child_retry_count == 0) return;
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                const context = &self.stream_contexts[index];
                if (!context.child_retry_counted) continue;
                const state = if (context.child) |*active| active else continue;
                child_io.retry(context.http.stream, state, &context.child_actions);
                self.sync_child_retry(context);
            }
        }

        fn child_live(context_ptr: *anyopaque, state: *const child_runtime.State) bool {
            const context: *StreamContext = @ptrCast(@alignCast(context_ptr));
            if (!context.state.lease.active or context.child == null or &context.child.? != state) return false;
            const self: *Self = @ptrCast(@alignCast(context.http.owner));
            if (self.children_shutdown or self.cooldown_pending or self.in_cooldown) return false;
            const key = state.key orelse return false;
            if (!std.meta.eql(key.connection, context.state.lease.connection)) return false;
            const slot = self.connections.find(key.connection) orelse return false;
            if (slot.native == null or slot.session_route != state.route) return false;
            const current_parent = slot.sessions.find(key.session_id) orelse return false;
            if (!std.meta.eql(current_parent, key.session)) return false;
            const session_state = slot.sessions.state(key.session) catch return false;
            if (session_state != .established and session_state != .draining) return false;
            const parent_index = slot.session_stream orelse return false;
            if (!self.stream_pool.is_active(parent_index)) return false;
            const parent = &self.stream_contexts[parent_index];
            if (parent.state.session == null or !std.meta.eql(parent.state.session.?, key.session)) return false;
            if (!std.meta.eql(parent.state.lease.connection, key.connection)) return false;
            if (backend.admission_canceled(parent.http.stream)) return false;
            if (c.lsquic_stream_id(context.http.stream) != key.stream_id) return false;
            return c.lsquic_stream_get_ctx(context.http.stream) == @as(?*c.lsquic_stream_ctx, @ptrCast(context));
        }

        fn handle_child_result(self: *Self, context: *StreamContext, result: child_io.Result) void {
            self.sync_child_retry(context);
            if (result != .not_live) return;
            const slot = self.connections.find(context.state.lease.connection);
            const reason: child_runtime.CloseReason = if (slot == null or !native_connection_live(slot.?.native))
                .connection_closed
            else if (self.children_shutdown or self.cooldown_pending or self.in_cooldown)
                .shutdown
            else
                .session_closed;
            self.cancel_child(context, reason, webtransport.wt_session_gone);
        }

        fn associate_child(self: *Self, context: *StreamContext) void {
            const state = if (context.child) |*active| active else return;
            if (state.phase != .waiting_parent) return;
            const binding = self.binding orelse return;
            if (binding.child_consumer == null) {
                self.cancel_child(context, .rejected, webtransport.application_error_to_http3(0));
                return;
            }
            const slot = self.connections.find(state.metadata.connection) orelse return;
            if (self.children_shutdown or self.cooldown_pending or self.in_cooldown) {
                self.cancel_child(context, .shutdown, webtransport.wt_session_gone);
                return;
            }
            if (self.pending_datagrams) |*storage| if (storage.store.is_retired(.{
                .connection = state.metadata.connection,
                .session_id = state.metadata.session_id,
            })) {
                self.cancel_child(context, .session_closed, webtransport.wt_session_gone);
                return;
            };
            if (slot.sessions.find(state.metadata.session_id)) |parent| {
                const phase = slot.sessions.state(parent) catch return;
                if (phase == .established or phase == .draining) {
                    self.release_child_pending(context);
                    const info = state.begin_open(parent, slot.session_route orelse return) catch return;
                    const result = child_io.open(context.http.stream, state, &context.child_actions, info, binding.child_consumer.?, .{ .context = context, .live = child_live });
                    self.handle_child_result(context, result);
                    if (state.phase == .active) _ = c.lsquic_stream_wantread(context.http.stream, 1);
                    return;
                }
            } else if (slot.unknown_early_disabled) {
                self.cancel_child(context, .rejected, webtransport.wt_buffered_stream_rejected);
                return;
            }
            if (state.pending_reserved) return;
            if (slot.pending_child_count >= pending_per_connection) {
                self.cancel_child(context, .rejected, webtransport.wt_buffered_stream_rejected);
                return;
            }
            std.debug.assert(state.reserve_pending());
            slot.pending_child_count += 1;
            self.pending_child_count += 1;
            _ = c.lsquic_stream_wantread(context.http.stream, 0);
        }

        fn register_child(self: *Self, context: *StreamContext) void {
            if (context.child != null) return;
            const info = context.state.info orelse return;
            if (info.initiator != .peer) {
                const code = webtransport.application_error_to_http3(0);
                _ = backend.reset_stream(context.http.stream, code);
                _ = c.lsquic_stream_close(context.http.stream);
                return;
            }
            const binding = self.binding orelse return;
            context.child = child_runtime.State.init(.{
                .connection = context.state.lease.connection,
                .session_id = info.session_id,
                .stream_id = c.lsquic_stream_id(context.http.stream),
                .receive_prefix_size = info.receive_prefix_size,
                .direction = if (info.direction == .uni) .uni else .bidi,
            }, binding.clock(binding.context) +| pending_lifetime_us) catch {
                _ = c.lsquic_stream_close(context.http.stream);
                return;
            };
            var received: backend.ReceiveSnapshot = .{};
            if (backend.read_receive(context.http.stream, &received) == .ok and
                (received.read_cancelled or received.reset_visible))
            {
                self.cancel_child(context, .peer_reset, received.reset_error orelse webtransport.wt_session_gone);
                return;
            }
            self.associate_child(context);
        }

        fn read_child(self: *Self, context: *StreamContext) void {
            self.register_child(context);
            const state = if (context.child) |*active| active else return;
            if (state.phase == .waiting_parent) self.associate_child(context);
            if (state.phase != .active and state.phase != .closing) return;
            const consumer = (self.binding orelse return).child_consumer orelse return;
            const result = child_io.read(context.http.stream, state, &context.child_actions, consumer, .{ .context = context, .live = child_live });
            self.handle_child_result(context, result);
        }

        fn resume_session_children(self: *Self, connection: runtime.ConnectionHandle, id: u64) void {
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                const context = &self.stream_contexts[index];
                const state = if (context.child) |*active| active else continue;
                if (!std.meta.eql(state.metadata.connection, connection) or state.metadata.session_id != id) continue;
                if (state.phase != .waiting_parent) continue;
                self.associate_child(context);
                if (state.phase != .active) continue;
                _ = c.lsquic_stream_wantread(context.http.stream, 1);
                self.read_child(context);
            }
        }

        fn acquire_header_set(
            self: *Self,
            is_trailer: bool,
            header_extra_names: [][]const u8,
            header_extra_values: [][]const u8,
        ) ?*HeaderSet {
            const header_set = self.header_pool.acquire() orelse return null;
            const index = self.header_pool.index_of(header_set) orelse unreachable;
            const storage_start = index * stream_capacities.request_header_size;
            const storage = self.header_storage[storage_start .. storage_start + stream_capacities.request_header_size];
            if (is_trailer) {
                header_set.reset_trailer(
                    self,
                    release_header_set,
                    storage,
                    header_extra_names,
                    header_extra_values,
                    stream_capacities,
                );
            } else {
                header_set.reset(
                    self,
                    release_header_set,
                    storage,
                    header_extra_names,
                    header_extra_values,
                    stream_capacities,
                );
            }
            return header_set;
        }

        fn release_header_set(context: *anyopaque, header_set: *HeaderSet) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.header_pool.release(header_set));
        }

        fn acquire_stream(self: *Self, lsquic_stream: *c.lsquic_stream, connection: *runtime.Connection) ?*StreamContext {
            const quic_stream = self.stream_pool.acquire() orelse return null;
            const index = self.stream_pool.index_of(quic_stream) orelse unreachable;
            const context = &self.stream_contexts[index];
            context.* = .{ .http = quic_stream };
            if (!self.connections.retain(connection.handle, &context.state.lease)) {
                std.debug.assert(self.stream_pool.release(quic_stream));
                return null;
            }
            const body_start = index * stream_capacities.request_body_size;
            const response_header_start = index * stream_capacities.response_header_size;
            const response_body_start = index * response_capacity;
            const route_param_start = index * route_param_pointer_count;
            const header_extra_start = index * header_extra_pointer_count;
            const route_param_names: [][]const u8 = if (route_param_extra_capacity == 0)
                &.{}
            else
                self.route_param_storage[route_param_start .. route_param_start + route_param_extra_capacity];
            const route_param_values: [][]const u8 = if (route_param_extra_capacity == 0)
                &.{}
            else
                self.route_param_storage[route_param_start + route_param_extra_capacity .. route_param_start + route_param_pointer_count];
            const header_extra_names: [][]const u8 = if (stream_capacities.header_extra_capacity == 0)
                &.{}
            else
                self.header_extra_storage[header_extra_start .. header_extra_start + stream_capacities.header_extra_capacity];
            const header_extra_values: [][]const u8 = if (stream_capacities.header_extra_capacity == 0)
                &.{}
            else
                self.header_extra_storage[header_extra_start + stream_capacities.header_extra_capacity .. header_extra_start + header_extra_pointer_count];
            quic_stream.reset(
                self,
                release_stream,
                lsquic_stream,
                self.router,
                self.request_body_storage[body_start .. body_start + stream_capacities.request_body_size],
                self.response_body_storage[response_body_start .. response_body_start + response_capacity],
                self.response_header_storage[response_header_start .. response_header_start + stream_capacities.response_header_size],
                route_param_names,
                route_param_values,
                header_extra_names,
                header_extra_values,
            );
            var info: backend.StreamInfo = .{};
            switch (backend.read_stream(lsquic_stream, &info)) {
                .ok => std.debug.assert(context.state.classify(info)),
                .unsupported => context.state.role = .http,
                .pending => {},
                .invalid => {
                    quic_stream.on_close();
                    return null;
                },
            }
            return context;
        }

        fn release_stream(context: *anyopaque, quic_stream: *QuicStream) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const index = self.stream_pool.index_of(quic_stream) orelse unreachable;
            self.retire_stream_datagrams(&self.stream_contexts[index]);
            self.close_session(&self.stream_contexts[index]);
            std.debug.assert(self.connections.release(&self.stream_contexts[index].state.lease));
            std.debug.assert(self.stream_pool.release(quic_stream));
        }

        fn on_new_connection(context: ?*anyopaque, connection: ?*c.lsquic_conn) callconv(.c) ?*c.lsquic_conn_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const conn = connection orelse return null;
            const slot = self.connections.acquire(self, conn) orelse {
                c.lsquic_conn_abort(conn);
                return null;
            };
            self.active_connections += 1;
            self.cache_peer(slot);
            return @ptrCast(slot);
        }

        fn on_connection_closed(connection: ?*c.lsquic_conn) callconv(.c) void {
            const conn = connection orelse return;
            const context = c.lsquic_conn_get_ctx(conn) orelse return;
            const slot: *runtime.Connection = @ptrCast(@alignCast(context));
            const self: *Self = @ptrCast(@alignCast(slot.owner));
            if (self.connection_slot(conn) != slot) return;
            const handle = slot.handle;
            c.lsquic_conn_set_ctx(conn, null);
            if (self.pending_datagrams) |*storage| storage.store.clear_connection(handle);
            if (self.binding) |binding| binding.clear(binding.context, handle);
            std.debug.assert(self.connections.close(handle));
            self.cancel_children(handle, null, .connection_closed);
            std.debug.assert(self.active_connections > 0);
            self.active_connections -= 1;
        }

        fn connection_slot(self: *Self, connection: *c.lsquic_conn) ?*runtime.Connection {
            const raw = c.lsquic_conn_get_ctx(connection) orelse return null;
            const slot: *runtime.Connection = @ptrCast(@alignCast(raw));
            const index = self.connections.pool.index_of(slot) orelse return null;
            if (!self.connections.pool.is_active(index)) return null;
            if (slot.owner != @as(*anyopaque, @ptrCast(self)) or slot.native != connection) return null;
            return slot;
        }

        fn cache_peer(self: *Self, slot: *runtime.Connection) void {
            if (slot.peer != null) return;
            const native = slot.native orelse return;
            var peer: backend.Peer = .{};
            if (backend.read_peer(native, &peer) == .ok) {
                std.debug.assert(self.connections.cache_peer(slot.handle, peer));
            }
        }

        fn on_peer_settings(connection: ?*c.lsquic_conn) callconv(.c) void {
            const native = connection orelse return;
            const raw = c.lsquic_conn_get_ctx(native) orelse return;
            const slot: *runtime.Connection = @ptrCast(@alignCast(raw));
            const self: *Self = @ptrCast(@alignCast(slot.owner));
            if (self.connection_slot(native) != slot) return;
            self.cache_peer(slot);
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                const context = &self.stream_contexts[index];
                if (!context.state.pending_settings) continue;
                if (!std.meta.eql(context.state.lease.connection, slot.handle)) continue;
                context.state.pending_settings = false;
                self.admit_connect(context);
            }
        }

        fn on_datagram(connection: ?*c.lsquic_conn, data: ?*const anyopaque, size: usize) callconv(.c) void {
            const native = connection orelse return;
            const raw_context = c.lsquic_conn_get_ctx(native) orelse return;
            const slot: *runtime.Connection = @ptrCast(@alignCast(raw_context));
            const self: *Self = @ptrCast(@alignCast(slot.owner));
            if (self.connection_slot(native) != slot or size > api.max_udp_payload_size) return;
            if (self.binding == null) return;
            const bytes: [*]const u8 = @ptrCast(data orelse return);
            const datagram = webtransport.decode_datagram(bytes[0..size]) catch return;
            if (slot.peer) |peer| if (!backend.peer_requirements_met(peer, .server)) return;
            if (slot.sessions.find(datagram.session_id)) |session| {
                const state = slot.sessions.state(session) catch return;
                if (state == .established or state == .draining) {
                    _ = self.dispatch_associated_datagram(slot, datagram.session_id, datagram.payload);
                    return;
                }
                if (state != .accepting) return;
                self.enqueue_pending_datagram(slot, datagram, true);
                return;
            }
            self.enqueue_pending_datagram(slot, datagram, false);
        }

        fn enqueue_pending_datagram(self: *Self, slot: *runtime.Connection, datagram: webtransport.Datagram, accepting: bool) void {
            if (self.cooldown_pending or self.in_cooldown) return;
            if (slot.unknown_early_disabled and !accepting) return;
            const binding = self.binding orelse return;
            if (datagram.payload.len > @min(binding.max_payload, api.max_udp_payload_size)) return;
            const storage = if (self.pending_datagrams) |*active| active else return;
            // Early unreliable traffic drops when any fixed admission bound rejects it.
            storage.store.enqueue(.{
                .connection = slot.handle,
                .session_id = datagram.session_id,
            }, datagram.payload, binding.clock(binding.context)) catch return;
        }

        fn dispatch_associated_datagram(self: *Self, slot: *runtime.Connection, session_id: u64, payload: []const u8) bool {
            if (slot.native == null or self.cooldown_pending or self.in_cooldown) return false;
            const binding = self.binding orelse return false;
            const index = slot.session_stream orelse return false;
            const context = &self.stream_contexts[index];
            if (backend.admission_canceled(context.http.stream)) {
                self.close_session(context);
                return false;
            }
            const route = slot.session_route orelse return false;
            if (slot.receive_ordinal == std.math.maxInt(u64)) return false;
            const ordinal = slot.receive_ordinal;
            slot.receive_ordinal += 1;
            _ = binding.deliver(binding.context, slot.handle, route, session_id, ordinal, payload);
            return true;
        }

        fn drain_pending_datagrams(self: *Self, connection: runtime.ConnectionHandle, session_id: u64) void {
            const storage = if (self.pending_datagrams) |*active| active else return;
            const binding = self.binding orelse return;
            const key = pending.SessionKey{ .connection = connection, .session_id = session_id };
            var payload: [api.max_udp_payload_size]u8 = undefined;
            while (true) {
                if (self.cooldown_pending or self.in_cooldown) return;
                const slot = self.connections.find(connection) orelse return;
                if (slot.native == null) return;
                const session = slot.sessions.find(session_id) orelse return;
                const state = slot.sessions.state(session) catch return;
                if (state != .established and state != .draining) return;
                // Every stored payload fits this fixed physical stride.
                const taken = storage.store.take_into(key, binding.clock(binding.context), &payload) catch unreachable;
                const datagram = taken orelse return;
                if (!self.dispatch_associated_datagram(slot, session_id, payload[0..datagram.payload_length])) return;
            }
        }

        fn on_new_stream(context: ?*anyopaque, lsquic_stream: ?*c.lsquic_stream) callconv(.c) ?*c.lsquic_stream_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const raw_stream = lsquic_stream orelse return null;
            const native_connection = c.lsquic_stream_conn(raw_stream) orelse return null;
            const connection = self.connection_slot(native_connection) orelse {
                _ = c.lsquic_stream_close(raw_stream);
                return null;
            };
            const stream_context = self.acquire_stream(raw_stream, connection) orelse {
                self.retire_datagrams(connection.handle, c.lsquic_stream_id(raw_stream));
                var info: backend.StreamInfo = .{};
                const result = backend.read_stream(raw_stream, &info);
                if (result == .ok and reject_unowned_child(raw_stream, info)) return null;
                if (backend.available and self.binding != null and result == .pending and
                    c.lsquic_stream_id(raw_stream) & 3 == 2)
                {
                    // The UNI interface switches before native typed publication.
                    _ = c.lsquic_stream_wantread(raw_stream, 0);
                    return null;
                }
                _ = c.lsquic_stream_close(raw_stream);
                return null;
            };
            // Native readability drives buffered HEADERS and child prefixes.
            _ = c.lsquic_stream_wantread(raw_stream, 1);
            return @ptrCast(stream_context);
        }

        fn reject_unowned_child(raw: *c.lsquic_stream, info: backend.StreamInfo) bool {
            if (info.association != .child or info.initiator != .peer) return false;
            switch (backend.stop_receiving(raw, webtransport.wt_buffered_stream_rejected)) {
                .ok => {},
                // A consumed prefix plus FIN still leaves the app read half open.
                .closed => _ = c.lsquic_stream_shutdown(raw, 0),
                .blocked, .invalid, .unsupported => |status| {
                    log.warn("unowned child receive cancellation failed: {s}", .{@tagName(status)});
                    _ = c.lsquic_stream_close(raw);
                },
            }
            if (info.direction == .bidi) _ = backend.reset_stream(raw, webtransport.wt_buffered_stream_rejected);
            return true;
        }

        fn native_connection_live(connection: ?*c.lsquic_conn) bool {
            const native = connection orelse return false;
            return switch (c.lsquic_conn_status(native, null, 0)) {
                c.LSCONN_ST_CONNECTED,
                c.LSCONN_ST_HSK_IN_PROGRESS,
                c.LSCONN_ST_GOING_AWAY,
                c.LSCONN_ST_PEER_GOING_AWAY,
                => true,
                else => false,
            };
        }

        fn on_stream_read(native: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const raw = native orelse return;
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            const self: *Self = @ptrCast(@alignCast(active.http.owner));
            if (active.pending_reset != null) return;
            if (active.state.role == .unresolved and !resolve_unresolved(raw, active)) return;
            if (active.state.pending_settings) return;
            if (active.state.role == .child) {
                self.read_child(active);
                return;
            }
            if (active.state.role == .connect) {
                self.read_connect(active);
                return;
            }
            if (active.state.role != .http) {
                _ = c.lsquic_stream_close(raw);
                return;
            }
            active.http.on_read();
        }

        fn on_stream_write(native: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            if (active.state.role == .child) {
                const self: *Self = @ptrCast(@alignCast(active.http.owner));
                self.register_child(active);
                if (active.child) |*state| child_io.retry(active.http.stream, state, &active.child_actions);
                self.sync_child_retry(active);
                return;
            }
            if (active.pending_reset != null) {
                const self: *Self = @ptrCast(@alignCast(active.http.owner));
                self.retry_reset(active);
                return;
            }
            if (active.state.role == .connect) {
                const self: *Self = @ptrCast(@alignCast(active.http.owner));
                self.write_connect(active);
                return;
            }
            if (active.state.role != .http) {
                _ = c.lsquic_stream_close(native);
                return;
            }
            active.http.on_write();
        }

        fn on_stream_close(native: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            active.state.pending_settings = false;
            const self: *Self = @ptrCast(@alignCast(active.http.owner));
            self.release_child_pending(active);
            if (active.child) |*state| {
                const slot = self.connections.find(active.state.lease.connection);
                if (self.engine == null or slot == null or !native_connection_live(slot.?.native)) {
                    _ = state.begin_close(.connection_closed, null);
                }
                child_io.close(native orelse active.http.stream, state, if (self.binding) |binding| binding.child_consumer else null);
            }
            active.child_actions = .{};
            self.sync_child_retry(active);
            self.retire_stream_datagrams(active);
            self.clear_pending_reset(active);
            active.http.on_close();
        }

        fn on_stream_reset(native: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx, _: c_int) callconv(.c) void {
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            const self: *Self = @ptrCast(@alignCast(active.http.owner));
            self.retire_stream_datagrams(active);
            if (active.state.role == .unresolved) {
                var info: backend.StreamInfo = .{};
                if (backend.read_stream(active.http.stream, &info) == .ok) _ = active.state.classify(info);
            }
            if (active.state.role == .child) {
                self.read_child(active);
                return;
            }
            if (active.state.pending_settings) {
                active.state.pending_settings = false;
                active.http.abort_connect();
                return;
            }
            if (active.pending_reset != null) {
                self.retry_reset(active);
                return;
            }
            if (active.state.role != .connect) return;
            self.close_session(active);
            _ = c.lsquic_stream_close(native);
        }

        fn on_webtransport_stream(native: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const raw = native orelse return;
            if (context == null) {
                const connection = c.lsquic_stream_conn(raw) orelse return;
                const raw_owner = c.lsquic_conn_get_ctx(connection) orelse return;
                const slot: *runtime.Connection = @ptrCast(@alignCast(raw_owner));
                const self: *Self = @ptrCast(@alignCast(slot.owner));
                if (self.connection_slot(connection) != slot) return;
                var orphan_info: backend.StreamInfo = .{};
                if (backend.read_stream(raw, &orphan_info) != .ok or !reject_unowned_child(raw, orphan_info)) {
                    _ = c.lsquic_stream_close(raw);
                }
                return;
            }
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            var info: backend.StreamInfo = .{};
            if (backend.read_stream(raw, &info) != .ok or !active.state.classify(info)) {
                _ = c.lsquic_stream_close(raw);
                return;
            }
            const self: *Self = @ptrCast(@alignCast(active.http.owner));
            self.read_child(active);
        }

        fn probe_read(_: ?*anyopaque, _: [*c]const u8, _: usize, _: c_int) callconv(.c) usize {
            return 0;
        }

        fn resolve_unresolved(raw: *c.lsquic_stream, context: *StreamContext) bool {
            var info: backend.StreamInfo = .{};
            if (backend.read_stream(raw, &info) == .ok) return context.state.classify(info);
            if (attach_native_headers(raw, context)) return true;
            // Native prefix/header parsing may advance; no application bytes do.
            std.c._errno().* = 0;
            const size = c.lsquic_stream_readf(raw, probe_read, null);
            const read_error = if (size < 0) std.c.errno(size) else .SUCCESS;
            if (backend.read_stream(raw, &info) == .ok) return context.state.classify(info);
            if (context.state.role != .unresolved or attach_native_headers(raw, context)) return true;
            if (size == 0 or (size < 0 and read_error != .SUCCESS and read_error != .AGAIN and read_error != .INTR)) {
                _ = c.lsquic_stream_close(raw);
            }
            return false;
        }

        fn on_header_set_available(
            lsquic_stream: ?*c.lsquic_stream,
            context: ?*c.lsquic_stream_ctx,
        ) callconv(.c) void {
            const raw_stream = lsquic_stream orelse return;
            const active: *StreamContext = @ptrCast(@alignCast(context orelse return));
            if (!attach_native_headers(raw_stream, active)) {
                _ = c.lsquic_stream_close(raw_stream);
            }
        }

        fn attach_native_headers(raw_stream: *c.lsquic_stream, context: *StreamContext) bool {
            const raw_header_set = c.lsquic_stream_get_hset(raw_stream) orelse return false;
            const header_set: *HeaderSet = @ptrCast(@alignCast(raw_header_set));
            if (!context.state.mark_http()) {
                header_set.release();
                return false;
            }
            context.http.attach_headers(header_set);
            const self: *Self = @ptrCast(@alignCast(context.http.owner));
            if (self.binding != null and backend.available and !header_set.is_trailer and
                std.mem.eql(u8, header_set.request.method, "CONNECT") and
                header_set.protocol != null and std.mem.eql(u8, header_set.protocol.?, "webtransport-h3"))
            {
                self.admit_connect(context);
                return true;
            }
            if (!header_set.is_trailer) self.retire_stream_datagrams(context);
            return true;
        }

        fn admit_connect(self: *Self, context: *StreamContext) void {
            const binding = self.binding orelse return;
            const headers = context.http.header_set orelse return;
            const slot = self.connections.find(context.state.lease.connection) orelse return;
            if (backend.admission_canceled(context.http.stream)) {
                context.state.pending_settings = false;
                self.retire_stream_datagrams(context);
                context.http.abort_connect();
                return;
            }
            _ = c.lsquic_stream_wantread(context.http.stream, 0);
            const peer = slot.peer orelse {
                context.state.pending_settings = true;
                return;
            };
            context.state.pending_settings = false;
            if (!backend.peer_requirements_met(peer, .server)) {
                self.reset_connect(context, webtransport.h3_message_error);
                return;
            }
            if (slot.sessions.open_count() != 0) {
                self.reset_connect(context, webtransport.h3_request_rejected);
                return;
            }
            const origin = headers.request.get_unique_header("origin") orelse {
                self.retire_stream_datagrams(context);
                context.http.refuse_connect("400 Bad Request", "Exactly one Origin is required");
                return;
            };
            if (origin.len == 0) {
                self.retire_stream_datagrams(context);
                context.http.refuse_connect("400 Bad Request", "Origin is empty");
                return;
            }
            headers.request.extra_param_names = context.http.extra_param_names;
            headers.request.extra_param_values = context.http.extra_param_values;
            headers.request.extra_param_count = 0;
            var response = Response{ .target = .{ .http3 = context.http.target() }, .request_body_complete = false };
            const result = binding.admit(binding.context, &headers.request, &response);
            if (!context.state.lease.active or self.connections.find(context.state.lease.connection) != slot or
                slot.native == null or self.cooldown_pending or self.in_cooldown or
                backend.admission_canceled(context.http.stream))
            {
                self.retire_stream_datagrams(context);
                context.http.abort_connect();
                return;
            }
            const route = switch (result) {
                .accepted => |id| id,
                .rejected => {
                    self.finish_admission_refusal(context, response.is_complete());
                    return;
                },
            };
            if (!response.is_complete() or !context.http.connect_response_ready()) {
                self.finish_admission_refusal(context, response.is_complete());
                return;
            }
            const id = c.lsquic_stream_id(context.http.stream);
            const session = slot.sessions.open(id, false) catch {
                self.retire_stream_datagrams(context);
                context.http.abort_connect();
                return;
            };
            context.state.session = session;
            slot.session_route = route;
            slot.session_stream = self.stream_pool.index_of(context.http).?;
            if (backend.accept_connect(context.http.stream) != .ok) {
                self.close_session(context);
                context.http.abort_connect();
                return;
            }
            var info: backend.StreamInfo = .{};
            if (backend.read_stream(context.http.stream, &info) != .ok or !context.state.classify(info)) {
                self.close_session(context);
                context.http.abort_connect();
                return;
            }
            context.http.dispatched = true;
        }

        fn finish_admission_refusal(self: *Self, context: *StreamContext, completed: bool) void {
            self.retire_stream_datagrams(context);
            const code = context.http.response_status_code;
            if (completed and code >= 300 and code <= 599 and context.http.response_body_offset == 0) {
                context.http.finish_connect_refusal();
                return;
            }
            context.http.refuse_connect("403 Forbidden", "CONNECT was not explicitly accepted");
        }

        fn write_connect(self: *Self, context: *StreamContext) void {
            const slot = self.connections.find(context.state.lease.connection) orelse return;
            const session = context.state.session orelse {
                _ = c.lsquic_stream_wantwrite(context.http.stream, 0);
                return;
            };
            const state = slot.sessions.state(session) catch return;
            if (state != .accepting) {
                if (!context.http.flush_connect_head()) {
                    self.close_session(context);
                    context.http.abort_connect();
                }
                return;
            }
            if (!context.http.send_connect_head()) {
                self.close_session(context);
                context.http.abort_connect();
                return;
            }
            slot.sessions.establish(session) catch {
                self.reset_connect(context, webtransport.h3_message_error);
                return;
            };
            context.http.release_connect_request();
            _ = c.lsquic_stream_wantread(context.http.stream, 1);
            self.drain_pending_datagrams(slot.handle, c.lsquic_stream_id(context.http.stream));
            self.resume_session_children(slot.handle, c.lsquic_stream_id(context.http.stream));
        }

        fn close_session(self: *Self, context: *StreamContext) void {
            if (context.state.role == .child) {
                std.debug.assert(context.state.session == null);
                return;
            }
            const session = context.state.session orelse return;
            self.retire_stream_datagrams(context);
            context.state.session = null;
            const slot = self.connections.find(context.state.lease.connection) orelse return;
            slot.sessions.close(session) catch return;
            slot.session_route = null;
            slot.session_stream = null;
            if (self.binding) |binding| binding.clear(binding.context, slot.handle);
        }

        fn reset_connect(self: *Self, context: *StreamContext, code: u64) void {
            self.retire_stream_datagrams(context);
            self.close_session(context);
            if (context.pending_reset == null) {
                context.pending_reset = code;
                self.pending_reset_count += 1;
            }
            self.retry_reset(context);
        }

        fn retry_pending_resets(self: *Self) void {
            if (self.pending_reset_count == 0) return;
            var streams = self.stream_pool.active.iterator(.{});
            while (streams.next()) |index| {
                if (self.pending_reset_count == 0) return;
                const context = &self.stream_contexts[index];
                if (context.pending_reset != null) self.retry_reset(context);
            }
        }

        fn clear_pending_reset(self: *Self, context: *StreamContext) void {
            if (context.pending_reset == null) return;
            context.pending_reset = null;
            std.debug.assert(self.pending_reset_count > 0);
            self.pending_reset_count -= 1;
        }

        fn retry_reset(self: *Self, context: *StreamContext) void {
            const code = context.pending_reset orelse return;
            const result = backend.reset_stream(context.http.stream, code);
            if (result == .blocked) {
                _ = c.lsquic_stream_wantread(context.http.stream, 0);
                _ = c.lsquic_stream_wantwrite(context.http.stream, 1);
                return;
            }
            if (result != .ok and result != .closed) {
                log.debug("CONNECT reset became unavailable: {s}", .{@tagName(result)});
            }
            // A terminal native write side cannot accept another error code.
            self.clear_pending_reset(context);
            _ = c.lsquic_stream_shutdown(context.http.stream, 0);
            context.http.abort_connect();
        }

        fn read_connect(self: *Self, context: *StreamContext) void {
            if (context.state.session) |session| {
                const slot = self.connections.find(context.state.lease.connection) orelse return;
                if ((slot.sessions.state(session) catch return) == .accepting) return;
            }
            var buffer: [2048]u8 = undefined;
            while (true) {
                const size = c.lsquic_stream_read(context.http.stream, &buffer, buffer.len);
                if (size < 0) {
                    if (std.c.errno(size) != .AGAIN) self.reset_connect(context, webtransport.wt_session_gone);
                    return;
                }
                if (size == 0) {
                    context.capsules.finish() catch {
                        self.reset_connect(context, webtransport.h3_message_error);
                        return;
                    };
                    self.close_session(context);
                    _ = c.lsquic_stream_shutdown(context.http.stream, 0);
                    _ = c.lsquic_stream_shutdown(context.http.stream, 1);
                    return;
                }
                if (!self.consume_capsules(context, buffer[0..@intCast(size)])) return;
            }
        }

        fn consume_capsules(self: *Self, context: *StreamContext, bytes: []const u8) bool {
            var offset: usize = 0;
            while (offset < bytes.len) {
                if (context.close_received) {
                    self.reset_connect(context, webtransport.h3_message_error);
                    return false;
                }
                const result = context.capsules.consume(bytes[offset..]) catch {
                    self.reset_connect(context, webtransport.h3_message_error);
                    return false;
                };
                offset += result.consumed;
                if (result.event) |event| if (!self.apply_capsule(context, event)) return false;
            }
            return true;
        }

        fn apply_capsule(self: *Self, context: *StreamContext, event: capsule_stream.Event) bool {
            switch (event) {
                .unknown => |kind| if (kind == 0x190b4d3e or kind == 0x190b4d42) {
                    // Draft-16 section 5.4 prohibits HTTP/2 stream-credit capsules.
                    self.reset_connect(context, webtransport.h3_message_error);
                    return false;
                },
                .capsule => |capsule| switch (capsule) {
                    .close_session => {
                        context.close_received = true;
                        self.close_session(context);
                        _ = c.lsquic_stream_shutdown(context.http.stream, 1);
                    },
                    .drain_session => {
                        const slot = self.connections.find(context.state.lease.connection) orelse return false;
                        const session = context.state.session orelse return false;
                        slot.sessions.drain(session) catch return false;
                    },
                    // Zero local limits leave session flow control disabled.
                    else => {},
                },
            }
            return true;
        }

        fn create_header_set(
            context: ?*anyopaque,
            lsquic_stream: ?*c.lsquic_stream,
            is_push_promise: c_int,
        ) callconv(.c) ?*anyopaque {
            if (is_push_promise != 0) return null;
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            var quic_stream: ?*QuicStream = null;
            if (lsquic_stream) |raw_stream| {
                if (c.lsquic_stream_get_ctx(raw_stream)) |raw_context| {
                    const active: *StreamContext = @ptrCast(@alignCast(raw_context));
                    if (active.state.role == .child or active.state.role == .connect) return null;
                    quic_stream = active.http;
                }
            }
            const is_trailer = if (quic_stream) |active|
                active.request_phase != .waiting_headers
            else
                false;
            const header_extra_names: [][]const u8 = if (quic_stream) |active|
                active.header_extra_names
            else
                &.{};
            const header_extra_values: [][]const u8 = if (quic_stream) |active|
                active.header_extra_values
            else
                &.{};
            return self.acquire_header_set(is_trailer, header_extra_names, header_extra_values);
        }

        fn prepare_header_decode(
            context: ?*anyopaque,
            existing: ?*c.lsxpack_header,
            required: usize,
        ) callconv(.c) ?*c.lsxpack_header {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return null));
            return header_set.prepare_decode(existing, required);
        }

        fn process_header(context: ?*anyopaque, header: ?*c.lsxpack_header) callconv(.c) c_int {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return -1));
            return if (header_set.process_header(header)) 0 else 1;
        }

        fn discard_header_set(context: ?*anyopaque) callconv(.c) void {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return));
            header_set.release();
        }

        fn packets_out(
            context: ?*anyopaque,
            specs: [*c]const c.lsquic_out_spec,
            count: c_uint,
        ) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(context orelse return -1));
            return api.send_packets(self.udp_fd, specs, count);
        }

        fn get_ssl_context(
            peer_context: ?*anyopaque,
            _: [*c]const c.struct_sockaddr,
        ) callconv(.c) ?*c.SSL_CTX {
            const self: *Self = @ptrCast(@alignCast(peer_context orelse return null));
            return self.ssl_ctx;
        }

        fn allocate_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            _: ?*c.lsquic_conn_ctx,
            size: c_ushort,
            _: u8,
        ) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            if (size == 0 or size > api.max_udp_payload_size) return null;
            const slot = self.packet_pool.acquire() orelse return null;
            return &slot.bytes;
        }

        fn release_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            buffer: ?*anyopaque,
            _: u8,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            const raw_buffer = buffer orelse return;
            const slot: *PacketSlot = @ptrCast(@alignCast(raw_buffer));
            std.debug.assert(self.packet_pool.release(slot));
        }
    };
}
