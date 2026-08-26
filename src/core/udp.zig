const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const QuicEngine = @import("../quic/engine.zig").QuicEngine;

// static udp server, handling millions of packets via a single port
pub const UdpServer = struct {
    socket: xev.UDP,
    read_completion: xev.Completion = undefined,

    // static buffer to catch packets. according to quic standards, maximum mtu rarely exceeds 1500 bytes,
    // but we allocate a 64kb chunk (udp memory standard) on this struct's stack.
    read_buffer: [65536]u8 = undefined,

    // static embedded pointer to quic engine
    engine: *QuicEngine,

    // initialize and bind udp socket to network port
    pub fn init(ip: []const u8, port: u16, engine: *QuicEngine) !UdpServer {
        // use std.Io.net (zig 0.16.0) to initialize ip address
        const addr = try std.Io.net.IpAddress.parse(ip, port);

        // create udp socket via libxev
        var socket = try xev.UDP.init(addr);
        try socket.bind(addr);

        return UdpServer{
            .socket = socket,
            .engine = engine,
        };
    }

    // add udp socket to io_uring/epoll event loop
    pub fn start(self: *UdpServer, loop_ptr: *xev.Loop) void {
        self.socket.read(
            loop_ptr,
            &self.read_completion,
            .{ .slice = &self.read_buffer },
            UdpServer,
            self,
            on_read_complete,
        );
    }

    // callback triggered by kernel when a datagram arrives
    fn on_read_complete(
        user_data: ?*UdpServer,
        loop: *xev.Loop,
        completion: *xev.Completion,
        state: xev.State,
        result: xev.ReadBufferResult,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = state;
        const self = user_data.?;

        // with udp, if there's a read error, we do not close the socket like tcp.
        // simply ignore the corrupted packet (packet loss) and continue to catch the next one.
        if (result.err == .none and result.bytes_read > 0) {
            const datagram = self.read_buffer[0..result.bytes_read];

            // pump static byte array directly into quic engine
            // no memory copy, no dynamic allocation!
            self.engine.process_datagram(datagram);
        }

        // rearm for the kernel to continue tracking the next udp packet
        return .rearm;
    }

    // close socket when shutting down server
    pub fn deinit(self: *UdpServer) void {
        self.socket.close(.{}) catch {};
    }
};
