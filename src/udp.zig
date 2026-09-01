const std = @import("std");
const c = @import("c");
const xev = @import("xev");
const Router = @import("router/radix.zig").Router;
const max_udp_payload_size = @import("quic/lsquic_api.zig").max_udp_payload_size;

/// Returns a bounded UDP/QUIC transport backed by completion-driven I/O.
///
/// `Engine` must provide `init`, `start`, `process_datagram`, `process`,
/// `next_timeout_ms`, `cooldown`, and `deinit` with the signatures used below.
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
        read_buffer: [max_udp_payload_size]u8 = undefined,
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

            var engine = try Engine.init();
            errdefer engine.deinit();

            const timer = try xev.Timer.init();
            return .{
                .engine = engine,
                .ssl_ctx = ssl_ctx,
                .router = router,
                .local_address = parsed_address,
                .socket = socket,
                .timer = timer,
            };
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
                self.socket.fd,
                self.local_address,
            );
            self.loop = loop;
            self.started = true;
            self.read_active = true;
            self.socket.read(
                loop,
                &self.read_completion,
                &self.read_state,
                .{ .slice = &self.read_buffer },
                Self,
                self,
                on_read,
            );
            self.start_timer();
        }

        /// Starts cooldown and cancels every completion that owns transport state.
        ///
        /// This operation is idempotent and asynchronous after `start`; continue
        /// driving the loop until `is_drained` reports true.
        pub fn shutdown(self: *Self) void {
            if (self.shutting_down) return;
            self.shutting_down = true;
            self.engine.cooldown();
            self.stop_timer();
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
                !self.timer_cancel_active;
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
                std.debug.print("udp read error: {}\n", .{err});
                self.read_active = true;
                return .rearm;
            };
            if (self.shutting_down) return .disarm;
            if (bytes_read != 0) {
                self.engine.process_datagram(self.read_buffer[0..bytes_read], peer);
            }
            self.read_active = true;
            return .rearm;
        }

        fn close_socket(self: *Self) void {
            if (!self.started or self.close_started or self.close_complete) return;
            const loop = self.loop orelse return;

            if (self.read_active and !self.read_cancel_active) {
                self.read_cancel_active = true;
                loop.cancel(
                    &self.read_completion,
                    &self.read_cancel_completion,
                    Self,
                    self,
                    on_read_cancel,
                );
            }
            self.close_started = true;
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
                if (err != error.NotFound) std.debug.print("udp read cancel error: {}\n", .{err});
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
            _ = result catch |err| std.debug.print("udp close error: {}\n", .{err});
            self.close_complete = true;
            return .disarm;
        }

        fn start_timer(self: *Self) void {
            if (self.timer_active or self.shutting_down) return;
            const loop = self.loop orelse return;
            self.timer_active = true;
            self.timer.run(
                loop,
                &self.timer_completion,
                self.engine.next_timeout_ms(),
                Self,
                self,
                on_timer,
            );
        }

        fn stop_timer(self: *Self) void {
            if (!self.timer_active or self.timer_cancel_active) return;
            const loop = self.loop orelse return;
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
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.timer_active = false;
            _ = result catch |err| {
                if (self.shutting_down or err == error.Canceled) return .disarm;
                std.debug.print("quic timer error: {}\n", .{err});
                return .disarm;
            };
            if (self.shutting_down) return .disarm;

            self.engine.process();
            self.timer_active = true;
            self.timer.run(
                loop,
                completion,
                self.engine.next_timeout_ms(),
                Self,
                self,
                on_timer,
            );
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
                if (err != error.NotFound) std.debug.print("quic timer cancel error: {}\n", .{err});
            };
            self.timer_cancel_active = false;
            return .disarm;
        }
    };
}

fn close_unregistered_socket(socket: xev.UDP) void {
    _ = std.posix.system.close(socket.fd);
}
