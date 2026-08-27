const std = @import("std");
const TcpConnection = @import("tcp.zig").TcpConnection;

// slab allocator: statically allocates the entire connection pool at comptime.
// uses a stack-based freelist to achieve strict o(1) acquire/release without looping.
pub fn connection_pool(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        // 1. slab memory: contiguous memory storing all tcp connections.
        storage: [capacity]TcpConnection = undefined,

        // 2. freelist (stack): stores the indices of available slots.
        free_indices: [capacity]usize = undefined,
        free_count: usize = capacity,

        // initializes the pool. called once during server startup.
        pub fn init() Self {
            var pool: Self = undefined;
            pool.free_count = capacity;

            // push all indices from 0 to capacity-1 into the free stack
            for (&pool.free_indices, 0..) |*item, i| {
                item.* = i;
            }
            return pool;
        }

        // acquires a connection from the pool (zero-allocation, o(1)).
        pub fn acquire(self: *Self) ?*TcpConnection {
            if (self.free_count == 0) {
                std.debug.print("warning: connection pool exhausted!\n", .{});
                return null;
            }

            // pop index from the top of the stack
            self.free_count -= 1;
            const index = self.free_indices[self.free_count];

            // get the pointer to the corresponding memory slot
            const conn = &self.storage[index];

            // dod optimization: reset only lightweight state.
            // avoid re-initializing the large 24kb io buffers on every connection.
            conn.req = .{};
            conn.parser = .{};
            conn.protocol_state = .http;
            conn.ssl = null;
            conn.is_tls_handshake_done = false;
            conn.last_active_ms = 0;

            return conn;
        }

        // returns a connection back to the pool after the client disconnects (o(1)).
        pub fn release(self: *Self, conn: *TcpConnection) void {
            // pointer arithmetic to calculate the index from the ram address
            const start_ptr = @intFromPtr(&self.storage[0]);
            const conn_ptr = @intFromPtr(conn);
            const offset = conn_ptr - start_ptr;

            // safety check: ensure the pointer strictly belongs to our memory slab
            std.debug.assert(offset % @sizeOf(TcpConnection) == 0);
            const index = offset / @sizeOf(TcpConnection);
            std.debug.assert(index < capacity);

            // push index back onto the stack
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
        }
    };
}
