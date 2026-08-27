const std = @import("std");
const c = @import("c");
const lsquic_api = @import("lsquic_api.zig");
pub const QuicStream = @import("stream.zig").QuicStream;

// callback invoked by lsquic when it needs to dispatch udp packets to the network.
// the `specs` parameter is an array containing pre-encoded packets ready for dispatch.
export fn on_packets_out(
    ea_ctx: ?*anyopaque,
    specs: [*c]const c.lsquic_out_spec,
    n_specs: c_uint,
) callconv(.c) c_int {
    const engine: *QuicEngine = @ptrCast(@alignCast(ea_ctx.?));

    // cast the c pointer to a many-item pointer to safely slice it
    const n_specs_usize: usize = @intCast(n_specs);
    const specs_ptr: [*]const c.lsquic_out_spec = @ptrCast(specs);
    const specs_slice = specs_ptr[0..n_specs_usize];

    var sent: c_int = 0;

    // iterate through each packet lsquic wants to send using functional slice iteration (dod)
    for (specs_slice) |spec| {
        // extract the buffer containing the raw udp datagram
        // (these are tls 1.3 encrypted bytes wrapped in a quic header)
        const iov = spec.iov[0];
        const datagram_ptr: [*]const u8 = @ptrCast(iov.iov_base);
        const datagram = datagram_ptr[0..iov.iov_len];

        if (engine.udp_fd != -1) {
            const dest_addr = spec.dest_sa;
            const sa_len: u32 = if (dest_addr.*.sa_family == std.posix.AF.INET6) @sizeOf(std.posix.sockaddr.in6) else @sizeOf(std.posix.sockaddr.in);
            _ = std.os.linux.sendto(engine.udp_fd, datagram.ptr, datagram.len, 0, @ptrCast(dest_addr), sa_len);
        }

        sent += 1;
    }

    // return the number of successfully sent packets to lsquic
    return sent;
}

pub const QuicEngine = struct {
    engine_ptr: *c.lsquic_engine,
    udp_fd: std.posix.socket_t = -1,

    pub fn init(ea_ctx: ?*anyopaque) !QuicEngine {
        // configure stream interface callbacks
        var stream_if = std.mem.zeroes(c.lsquic_stream_if);
        stream_if.on_new_stream = lsquic_api.on_new_stream;
        stream_if.on_read = lsquic_api.on_read;
        stream_if.on_close = lsquic_api.on_close;

        // configure engine to activate http/3
        var engine_api = std.mem.zeroes(c.lsquic_engine_api);
        engine_api.ea_stream_if = &stream_if;
        engine_api.ea_alpn = "h3";

        // register the data exhaust callback
        engine_api.ea_packets_out = on_packets_out;
        engine_api.ea_packets_out_ctx = ea_ctx;

        // initialize the engine
        const ptr = c.lsquic_engine_new(c.LSENG_SERVER, &engine_api);
        if (ptr == null) return error.EngineInitFailed;

        return QuicEngine{ .engine_ptr = ptr.? };
    }

    // called by udp server to feed raw packets into the engine
    pub fn process_datagram(self: *QuicEngine, data: []const u8, peer_addr: std.Io.net.IpAddress) void {
        var local_sa_storage = std.mem.zeroes(std.posix.sockaddr.storage);
        var peer_sa_storage = std.mem.zeroes(std.posix.sockaddr.storage);

        const local_sa: *std.posix.sockaddr = @ptrCast(@alignCast(&local_sa_storage));
        const peer_sa: *std.posix.sockaddr = @ptrCast(@alignCast(&peer_sa_storage));

        switch (peer_addr) {
            .ip4 => |v4| {
                const sa_in: *std.posix.sockaddr.in = @ptrCast(@alignCast(peer_sa));
                sa_in.family = std.posix.AF.INET;
                sa_in.port = std.mem.nativeToBig(u16, v4.port);
                sa_in.addr = @bitCast(v4.bytes);

                const local_in: *std.posix.sockaddr.in = @ptrCast(@alignCast(local_sa));
                local_in.family = std.posix.AF.INET;
                local_in.port = std.mem.nativeToBig(u16, 8443);
            },
            .ip6 => |v6| {
                const sa_in6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(peer_sa));
                sa_in6.family = std.posix.AF.INET6;
                sa_in6.port = std.mem.nativeToBig(u16, v6.port);
                sa_in6.addr = v6.bytes;

                const local_in6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(local_sa));
                local_in6.family = std.posix.AF.INET6;
                local_in6.port = std.mem.nativeToBig(u16, 8443);
            },
        }

        // feed packet into engine -> if lsquic needs to ack, it automatically triggers on_packets_out
        _ = c.lsquic_engine_packet_in(self.engine_ptr, data.ptr, data.len, @ptrCast(local_sa), @ptrCast(peer_sa), null, 0);

        // wake up the engine to flush its queue
        c.lsquic_engine_process_conns(self.engine_ptr);
    }
};
