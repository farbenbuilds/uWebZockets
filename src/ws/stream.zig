const abort_module = @import("../http/abort.zig");
const backpressure = @import("backpressure.zig");

pub const MessageKind = enum(u8) {
    binary,
    text,
};

/// Creates a pull-based WebSocketStream specialized for a transport adapter.
///
/// Adapter must expose `send`, `close`, and `terminate`. Transport effects are
/// kept outside the pure backpressure transition function.
pub fn web_socket_stream(comptime Adapter: type) type {
    comptime {
        for (&.{ "send", "close", "terminate" }) |name| {
            if (!@hasDecl(Adapter, name)) {
                @compileError("WebSocketStream adapter is missing " ++ name);
            }
        }
    }

    return struct {
        const Self = @This();

        context: *anyopaque,
        incoming: []u8,
        incoming_head: usize = 0,
        incoming_len: usize = 0,
        outgoing: backpressure.State,
        signal: ?abort_module.AbortSignal = null,

        pub fn init(
            context: *anyopaque,
            incoming: []u8,
            high_water_mark: usize,
            low_water_mark: usize,
            signal: ?abort_module.AbortSignal,
        ) !Self {
            if (incoming.len == 0) return error.EmptyIncomingBuffer;
            return .{
                .context = context,
                .incoming = incoming,
                .outgoing = try backpressure.State.init(high_water_mark, low_water_mark),
                .signal = signal,
            };
        }

        /// Queues an event-driven WebSocket message for later BYOB pulls.
        pub fn push_incoming(self: *Self, message: []const u8) !void {
            try self.checkpoint();
            if (message.len > self.incoming.len - self.incoming_len) {
                return error.IncomingBufferFull;
            }
            const tail = (self.incoming_head + self.incoming_len) % self.incoming.len;
            const first_len = @min(message.len, self.incoming.len - tail);
            @memcpy(self.incoming[tail .. tail + first_len], message[0..first_len]);
            @memcpy(self.incoming[0 .. message.len - first_len], message[first_len..]);
            self.incoming_len += message.len;
        }

        /// Pulls available bytes directly into caller-owned storage.
        pub fn read(self: *Self, destination: []u8) !usize {
            try self.checkpoint();
            const count = @min(destination.len, self.incoming_len);
            if (count == 0) return 0;
            const first_len = @min(count, self.incoming.len - self.incoming_head);
            @memcpy(destination[0..first_len], self.incoming[self.incoming_head .. self.incoming_head + first_len]);
            @memcpy(destination[first_len..count], self.incoming[0 .. count - first_len]);
            self.incoming_head = (self.incoming_head + count) % self.incoming.len;
            self.incoming_len -= count;
            return count;
        }

        /// Sends one message and returns the pure flow-control action.
        pub fn send(self: *Self, message: []const u8, kind: MessageKind) !backpressure.Action {
            try self.checkpoint();
            const next = try backpressure.transition(self.outgoing, .{ .enqueue = message.len });
            Adapter.send(self.context, message, kind) catch |err| {
                const aborted = try backpressure.transition(self.outgoing, .abort);
                self.outgoing = aborted.new_state;
                Adapter.terminate(self.context);
                return err;
            };
            self.outgoing = next.new_state;
            return next.next_action;
        }

        /// Accounts for a transport drain and returns resume/close work.
        pub fn flushed(self: *Self, byte_count: usize) !backpressure.Action {
            const next = try backpressure.transition(self.outgoing, .{ .flushed = byte_count });
            self.outgoing = next.new_state;
            if (next.next_action == .close_transport) try Adapter.close(self.context);
            return next.next_action;
        }

        pub fn close(self: *Self) !backpressure.Action {
            const next = try backpressure.transition(self.outgoing, .close);
            self.outgoing = next.new_state;
            if (next.next_action == .close_transport) try Adapter.close(self.context);
            return next.next_action;
        }

        pub fn abort(self: *Self) void {
            const next = backpressure.transition(self.outgoing, .abort) catch return;
            self.outgoing = next.new_state;
            if (next.next_action == .terminate_transport) Adapter.terminate(self.context);
        }

        fn checkpoint(self: *Self) !void {
            const signal = self.signal orelse return;
            signal.checkpoint() catch {
                self.abort();
                return error.Aborted;
            };
        }
    };
}
