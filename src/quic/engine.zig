const std = @import("std");
const c = @import("c");
const lsquic_api = @import("lsquic_api.zig");

pub const QuicEngine = struct {
    engine_ptr: *c.lsquic_engine,

    pub fn init() !QuicEngine {
        // configure stream interface callbacks
        var stream_if = std.mem.zeroes(c.lsquic_stream_if);
        stream_if.on_new_stream = lsquic_api.on_new_stream;
        stream_if.on_read = lsquic_api.on_read;

        // configure engine to activate http/3
        var engine_api = std.mem.zeroes(c.lsquic_engine_api);
        engine_api.ea_stream_if = &stream_if;
        engine_api.ea_alpn = "h3";

        // initialize the engine
        const ptr = c.lsquic_engine_new(c.LSENG_SERVER, &engine_api);
        if (ptr == null) return error.EngineInitFailed;

        return QuicEngine{ .engine_ptr = ptr.? };
    }

    // called by udp server to feed raw packets into the engine
    pub fn process_datagram(self: *QuicEngine, data: []const u8) void {
        _ = self;
        _ = data;
    }
};
