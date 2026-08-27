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
    _ = ea_ctx;
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

        // here we would normally dispatch to libxev to write to the socket.
        // we only log the packet length for now to avoid hallucinating undefined functions.
        std.debug.print("sent quic packet: {d} bytes\n", .{datagram.len});

        sent += 1;
    }

    // return the number of successfully sent packets to lsquic
    return sent;
}

pub const QuicEngine = struct {
    engine_ptr: *c.lsquic_engine,

    pub fn init() !QuicEngine {
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

        // initialize the engine
        const ptr = c.lsquic_engine_new(c.LSENG_SERVER, &engine_api);
        if (ptr == null) return error.EngineInitFailed;

        return QuicEngine{ .engine_ptr = ptr.? };
    }

    // called by udp server to feed raw packets into the engine
    pub fn process_datagram(self: *QuicEngine, data: []const u8) void {
        _ = self;
        _ = data;

        // feed packet into engine -> if lsquic needs to ack, it automatically triggers on_packets_out
        // c.lsquic_engine_packet_in(...)

        // wake up the engine to flush its queue
        // c.lsquic_engine_process_conns(self.engine_ptr);
    }
};
