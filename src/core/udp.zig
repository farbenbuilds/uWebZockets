const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const xev = @import("xev");
const core_loop = @import("loop.zig");
const tcp = @import("tcp.zig");
const Router = @import("../router/radix.zig").Router;
const max_udp_payload_size = @import("../quic/lsquic_api.zig").max_udp_payload_size;

const log = std.log.scoped(.udp);

/// Pure Linux receive-message validation and bounded datagram views.
pub const receive = @import("udp_receive.zig");

/// Linux GRO availability; unsupported kernels retain ordinary reception.
pub const GroStatus = union(enum) {
    enabled,
    unsupported: std.c.E,
    disabled,
};

/// Owner-loop wake failures; no engine operation runs during a request.
pub const WakeError = error{ NotStarted, ShuttingDown, WakeFailed };

const receive_attempts = 8;
const control_bytes = 256;

const Received = struct {
    batch: receive.Batch,
    peer: std.Io.net.IpAddress,
};

const ReceiveOutcome = union(enum) {
    received: Received,
    would_block,
    interrupted,
    dropped: receive.ReceiveError,
    failed: std.c.E,
};

/// Returns a bounded UDP/QUIC transport backed by completion-driven I/O.
///
/// `Engine` provides `init`, `start`, `process`, `next_timeout_ms`, `cooldown`,
/// `deinit`, and a datagram callback with the signatures used below.
/// `process_datagram(data, peer)` retains the legacy bound-address contract.
/// Optional `process_datagram_at(data, peer, local)` receives packet destinations.
/// Packet storage is embedded and the transport allocates no receive buffers.
/// Engine initialization may allocate according to the selected implementation.
pub fn quic_transport(comptime Engine: type) type {
    return struct {
        const Self = @This();

        /// Owned QUIC engine; callers must not move or mutate it directly.
        engine: Engine,
        /// Borrowed TLS context used when the stable transport starts.
        ssl_ctx: *c.SSL_CTX,
        /// Borrowed route table used by the QUIC engine callbacks.
        router: *const Router,
        /// Bound local address retained until engine startup.
        local_address: std.Io.net.IpAddress,
        /// Bound UDP socket owned by this transport.
        socket: xev.UDP,
        /// QUIC deadline timer owned by this transport.
        timer: xev.Timer,
        /// Borrowed event loop retained after `start`.
        loop: ?*xev.Loop = null,
        /// In-flight receive completion; callers must not access it.
        read_completion: xev.Completion = .{},
        /// In-flight receive-cancellation completion.
        read_cancel_completion: xev.Completion = .{},
        /// In-flight socket-close completion.
        close_completion: xev.Completion = .{},
        /// In-flight QUIC timer completion.
        timer_completion: xev.Completion = .{},
        /// In-flight timer-cancellation completion.
        timer_cancel_completion: xev.Completion = .{},
        /// Backend receive state owned by the active completion.
        read_state: xev.UDP.State = undefined,
        /// Fixed receive buffer reused after each callback returns.
        read_buffer: [if (builtin.os.tag == .linux) receive.aggregate_bytes else max_udp_payload_size]u8 = undefined,
        /// Linux ancillary storage reused only after the receive callback returns.
        read_control: [if (builtin.os.tag == .linux) control_bytes else 0]u8 align(@alignOf(usize)) = undefined,
        /// Kernel GRO support determined before reception starts.
        gro_status: GroStatus = .disabled,
        /// Successfully validated aggregates that carried UDP_GRO metadata.
        gro_batches: u64 = 0,
        /// Whether a receive completion can reference this value.
        read_active: bool = false,
        /// Whether a receive-cancellation completion is outstanding.
        read_cancel_active: bool = false,
        /// Whether asynchronous socket close was submitted.
        close_started: bool = false,
        /// Whether the socket-close completion has fired.
        close_complete: bool = false,
        /// Whether a timer completion can reference this value.
        timer_active: bool = false,
        /// Whether a timer-cancellation completion is outstanding.
        timer_cancel_active: bool = false,
        /// Coalesced work to service after the current timer retires.
        process_requested: bool = false,
        /// Public operations inside engine callbacks use the current pass.
        engine_processing: bool = false,
        /// Whether completions were armed on an event loop.
        started: bool = false,
        /// Whether shutdown has begun and no work may be rearmed.
        shutting_down: bool = false,

        /// Binds the UDP socket and initializes its bounded QUIC engine.
        ///
        /// `address` is consumed during the call. The selected engine may retain
        /// `ssl_ctx` and `router`, which must then outlive the transport. On
        /// failure, all successfully initialized resources are released.
        pub fn init(
            ssl_ctx: *c.SSL_CTX,
            router: *const Router,
            address: []const u8,
            port: u16,
        ) !Self {
            const parsed_address = try std.Io.net.IpAddress.parse(address, port);
            var socket = try xev.UDP.init(parsed_address);
            errdefer close_unregistered_socket(socket);
            try socket.bind(parsed_address);
            const local_address = if (builtin.os.tag == .linux)
                try linux_bound_address(xev.udp_fd(socket))
            else
                parsed_address;
            const gro_status = if (builtin.os.tag == .linux)
                try configure_linux_receive(xev.udp_fd(socket), local_address)
            else
                GroStatus.disabled;

            var engine = try Engine.init();
            errdefer engine.deinit();

            const timer = try xev.Timer.init();
            return .{
                .engine = engine,
                .ssl_ctx = ssl_ctx,
                .router = router,
                .local_address = local_address,
                .socket = socket,
                .timer = timer,
                .gro_status = gro_status,
            };
        }

        /// Fails a GRO-required verification run instead of accepting fallback.
        pub fn require_gro(self: *const Self) error{GroUnavailable}!void {
            if (self.gro_status != .enabled) return error.GroUnavailable;
        }

        /// Arms the UDP receive and QUIC timer completions.
        ///
        /// `loop` and the transport's address must remain stable through
        /// shutdown and until `is_drained` is true. Starting twice or after
        /// shutdown returns an error without arming new work.
        pub fn start(self: *Self, loop: *xev.Loop) !void {
            if (self.started) return error.TransportAlreadyStarted;
            if (self.shutting_down) return error.TransportShuttingDown;

            try self.engine.start(
                self.ssl_ctx,
                self.router,
                xev.udp_fd(self.socket),
                self.local_address,
            );
            self.loop = loop;
            self.started = true;
            self.read_active = true;
            if (builtin.os.tag == .linux) {
                self.socket.poll(loop, &self.read_completion, .read, Self, self, on_read_ready);
            } else {
                self.socket.read(
                    loop,
                    &self.read_completion,
                    &self.read_state,
                    .{ .slice = &self.read_buffer },
                    Self,
                    self,
                    on_read,
                );
            }
            self.start_timer();
        }

        /// Requests one deferred engine pass from the owning loop thread.
        ///
        /// Flush failures leave the wake and cancellation ownership unchanged.
        pub fn request_process(self: *Self) WakeError!void {
            if (self.shutting_down) return error.ShuttingDown;
            if (!self.started) return error.NotStarted;
            if (self.engine_processing or self.process_requested) return;
            try self.stop_timer();
            self.process_requested = true;
            self.start_timer();
        }

        /// Starts cooldown and cancels every completion that owns transport state.
        ///
        /// This operation is idempotent and asynchronous after `start`; continue
        /// driving the loop until `is_drained` reports true.
        pub fn shutdown(self: *Self) void {
            if (self.shutting_down) return;
            self.shutting_down = true;
            self.process_requested = false;
            self.engine.cooldown();
            self.stop_timer() catch |err| log.err("quic timer shutdown cancel failed: {}", .{err});
            self.close_socket();
        }

        /// Reports whether no kernel completion can still reference this transport.
        ///
        /// A transport that was never started is immediately drained.
        pub fn is_drained(self: *const Self) bool {
            if (!self.started) return true;
            return self.close_complete and
                !self.read_active and
                !self.read_cancel_active and
                !self.timer_active and
                !self.timer_cancel_active and
                !self.engine_processing;
        }

        /// Releases the engine, timer, and socket resources.
        ///
        /// After `start`, callers must first call `shutdown`, drive the loop, and
        /// observe `is_drained`. Violating this precondition asserts in safe
        /// builds and can leave callbacks referencing freed state. The value is
        /// invalid after return.
        pub fn deinit(self: *Self) void {
            if (self.started) {
                std.debug.assert(self.is_drained());
            } else {
                close_unregistered_socket(self.socket);
            }
            self.engine.deinit();
            self.timer.deinit();
            self.* = undefined;
        }

        fn on_read(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: *xev.UDP.State,
            peer: std.Io.net.IpAddress,
            _: xev.UDP,
            _: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.read_active = false;

            const bytes_read = result catch |err| {
                if (self.shutting_down or err == error.Canceled) return .disarm;
                log.warn("udp read error: {}", .{err});
                self.read_active = true;
                return .rearm;
            };
            if (self.shutting_down) return .disarm;
            if (bytes_read != 0) {
                self.dispatch_packet(self.read_buffer[0..bytes_read], peer, self.local_address);
            }
            // A handler may have started shutdown during datagram processing.
            if (self.shutting_down) return .disarm;
            self.read_active = true;
            return .rearm;
        }

        fn on_read_ready(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.UDP,
            result: xev.PollError!xev.PollEvent,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.read_active = false;
            _ = result catch |err| {
                if (self.shutting_down or err == error.Canceled) return .disarm;
                log.warn("udp readiness failed: {}", .{err});
                self.shutdown();
                return .disarm;
            };
            if (self.shutting_down) return .disarm;

            var attempt: usize = 0;
            while (attempt < receive_attempts) : (attempt += 1) {
                const outcome = receive_linux(
                    xev.udp_fd(self.socket),
                    self.local_address,
                    &self.read_buffer,
                    &self.read_control,
                );
                switch (outcome) {
                    .would_block => break,
                    .interrupted => continue,
                    .dropped => |err| {
                        log.debug("udp message rejected: {}", .{err});
                        continue;
                    },
                    .failed => |err| {
                        log.warn("udp receive failed: {}", .{err});
                        break;
                    },
                    .received => |received| {
                        if (!self.dispatch_received(received)) return .disarm;
                    },
                }
            }
            self.read_active = true;
            return .rearm;
        }

        fn dispatch_received(self: *Self, received: Received) bool {
            var batch = received.batch;
            if (batch.gro) self.gro_batches +|= 1;
            while (batch.next()) |packet| {
                self.dispatch_packet(packet, received.peer, batch.local_address);
                if (self.shutting_down) return false;
            }
            return true;
        }

        fn dispatch_packet(self: *Self, data: []const u8, peer: std.Io.net.IpAddress, local: std.Io.net.IpAddress) void {
            self.engine_processing = true;
            defer self.engine_processing = false;
            if (comptime @hasDecl(Engine, "process_datagram_at")) {
                self.engine.process_datagram_at(data, peer, local);
                return;
            }
            self.engine.process_datagram(data, peer);
        }

        fn close_socket(self: *Self) void {
            if (!self.started or self.close_started or self.close_complete) return;
            const loop = self.loop orelse return;

            // kqueue and IOCP must flush queued work before canceling so the
            // receive callback clears its own flag; epoll clears it on close.
            if (self.read_active and !self.read_cancel_active) {
                if (builtin.os.tag == .windows or xev.submit_before_cancel()) {
                    xev.submit(loop) catch |err| {
                        // Keep the receive flag set rather than reuse a slot
                        // whose queued callback may still fire.
                        log.err("udp submit before close failed: {}", .{err});
                    };
                }
                self.read_cancel_active = true;
                core_loop.cancel(
                    loop,
                    &self.read_completion,
                    &self.read_cancel_completion,
                    Self,
                    self,
                    on_read_cancel,
                );
            }
            self.close_started = true;
            if (builtin.os.tag == .windows) {
                tcp.close_socket(xev.udp_fd(self.socket));
                self.close_complete = true;
                // IOCP drops callbacks for completions canceled before
                // submission; clear a receive flag that can never clear.
                if (self.read_completion.state() != .active) self.read_active = false;
                return;
            }
            self.socket.close(
                loop,
                &self.close_completion,
                Self,
                self,
                on_close,
            );
        }

        fn on_read_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) log.debug("udp read cancel error: {}", .{err});
            };
            self.read_cancel_active = false;
            return .disarm;
        }

        fn on_close(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.UDP,
            result: xev.CloseError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| log.debug("udp close error: {}", .{err});
            self.close_complete = true;
            if (xev.cancel_abandons_target()) {
                // epoll drops the target receive callback; kqueue and io_uring
                // deliver it, so their callbacks own the read flag.
                self.read_active = false;
            }
            return .disarm;
        }

        fn start_timer(self: *Self) void {
            if (self.timer_active or self.timer_cancel_active or self.shutting_down) return;
            const loop = self.loop orelse return;
            self.timer_active = true;
            self.timer.run(
                loop,
                &self.timer_completion,
                if (self.process_requested) 0 else self.engine.next_timeout_ms(),
                Self,
                self,
                on_timer,
            );
        }

        fn stop_timer(self: *Self) WakeError!void {
            if (!self.timer_active or self.timer_cancel_active) return;
            const loop = self.loop orelse return error.NotStarted;
            // Queued kqueue/IOCP timers otherwise lose their target callback.
            // Root's watchers defer results; raw IOCP job objects are excluded.
            xev.submit(loop) catch |err| {
                log.err("quic timer submit before cancel failed: {}", .{err});
                return error.WakeFailed;
            };
            self.timer_cancel_active = true;
            self.timer.cancel(
                loop,
                &self.timer_completion,
                &self.timer_cancel_completion,
                Self,
                self,
                on_timer_cancel,
            );
        }

        fn on_timer(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.timer_active = false;
            _ = result catch |err| {
                if (self.shutting_down) return .disarm;
                if (err == error.Canceled) {
                    self.start_timer();
                    return .disarm;
                }
                log.err("quic timer error: {}", .{err});
                return .disarm;
            };
            if (self.shutting_down) return .disarm;

            self.process_requested = false;
            self.engine_processing = true;
            self.engine.process();
            self.engine_processing = false;
            // Both timer callbacks must retire before this completion is reused.
            self.start_timer();
            return .disarm;
        }

        fn on_timer_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) log.debug("quic timer cancel error: {}", .{err});
            };
            self.timer_cancel_active = false;
            self.start_timer();
            return .disarm;
        }
    };
}

fn close_unregistered_socket(socket: xev.UDP) void {
    tcp.close_socket(xev.udp_fd(socket));
}

fn configure_linux_receive(fd: std.posix.socket_t, local: std.Io.net.IpAddress) !GroStatus {
    const enabled: c_int = 1;
    const level: c_int = if (local == .ip4) c.IPPROTO_IP else c.IPPROTO_IPV6;
    const option: c_int = if (local == .ip4) c.IP_PKTINFO else c.IPV6_RECVPKTINFO;
    if (c.setsockopt(fd, level, option, &enabled, @sizeOf(c_int)) != 0) return error.PacketInfoSetupFailed;
    if (c.setsockopt(fd, receive.udp_level, receive.gro_type, &enabled, @sizeOf(c_int)) == 0) {
        log.info("UDP receive GRO enabled", .{});
        return .enabled;
    }
    const err: std.c.E = @enumFromInt(std.c._errno().*);
    switch (err) {
        .NOPROTOOPT, .OPNOTSUPP, .INVAL => {
            log.warn("UDP receive GRO unavailable: {}; retaining ordinary datagrams", .{err});
            return .{ .unsupported = err };
        },
        else => return error.GroSetupFailed,
    }
}

fn linux_bound_address(fd: std.posix.socket_t) !std.Io.net.IpAddress {
    var address: std.posix.sockaddr.storage = undefined;
    var length: c.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    if (c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.SocketAddressFailed;
    return decode_native_address(&address, length);
}

fn decode_native_address(address: *const std.posix.sockaddr.storage, length: usize) receive.ReceiveError!std.Io.net.IpAddress {
    if (length < @sizeOf(std.posix.sa_family_t) or length > @sizeOf(std.posix.sockaddr.storage)) return error.InvalidPeer;
    switch (address.family) {
        std.posix.AF.INET => {
            if (length < @sizeOf(std.posix.sockaddr.in)) return error.InvalidPeer;
            const value: *const std.posix.sockaddr.in = @ptrCast(address);
            return .{ .ip4 = .{ .bytes = @bitCast(value.addr), .port = std.mem.bigToNative(u16, value.port) } };
        },
        std.posix.AF.INET6 => {
            if (length < @sizeOf(std.posix.sockaddr.in6)) return error.InvalidPeer;
            const value: *const std.posix.sockaddr.in6 = @ptrCast(address);
            return .{ .ip6 = .{
                .bytes = value.addr,
                .port = std.mem.bigToNative(u16, value.port),
                .flow = value.flowinfo,
                .interface = .{ .index = value.scope_id },
            } };
        },
        else => return error.InvalidPeer,
    }
}

fn receive_linux(
    fd: std.posix.socket_t,
    local: std.Io.net.IpAddress,
    payload: []u8,
    control: []u8,
) ReceiveOutcome {
    var address: std.posix.sockaddr.storage = undefined;
    var iov = c.struct_iovec{ .iov_base = payload.ptr, .iov_len = payload.len };
    // recvmsg mutates these lengths and flags; each receive starts afresh.
    var message = c.struct_msghdr{
        .msg_name = &address,
        .msg_namelen = @sizeOf(std.posix.sockaddr.storage),
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control.ptr,
        .msg_controllen = @intCast(control.len),
        .msg_flags = 0,
    };
    // io_uring UDP descriptors are blocking even though readiness is asynchronous.
    const result = c.recvmsg(fd, &message, c.MSG_DONTWAIT);
    if (result < 0) {
        const err: std.c.E = @enumFromInt(std.c._errno().*);
        return switch (err) {
            .AGAIN => .would_block,
            .INTR => .interrupted,
            else => .{ .failed = err },
        };
    }
    const length: usize = @intCast(result);
    if (length > payload.len) return .{ .dropped = error.TruncatedDatagram };
    if (message.msg_controllen > control.len) return .{ .dropped = error.TruncatedControl };
    const peer = decode_native_address(&address, message.msg_namelen) catch |err| return .{ .dropped = err };
    const batch = receive.decode(payload[0..length], control[0..message.msg_controllen], message.msg_flags, local) catch |err| return .{ .dropped = err };
    return .{ .received = .{ .batch = batch, .peer = peer } };
}
