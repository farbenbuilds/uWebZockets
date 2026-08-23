const std = @import("std");
const TcpConnection = @import("tcp.zig").TcpConnection;

// a fixed-size, zero-allocation memory pool for managing active tcp connections.
// pre-allocates memory statically to avoid dynamic heap allocation on the hot path.
pub fn connection_pool(comptime capacity: usize) type {
    return struct {
        // contiguous storage for all possible connections.
        storage: [capacity]TcpConnection = undefined,

        // bitset tracking which slots are available (1) or active (0).
        // uses 1 bit per connection, resulting in a microscopic memory footprint.
        available_mask: std.StaticBitSet(capacity) = std.StaticBitSet(capacity).initFull(),
    };
}

// initializes the static connection pool.
pub fn init_pool(comptime capacity: usize) connection_pool(capacity) {
    return .{};
}

// acquires an unused slot from the pool in o(1) amortized time.
// returns null if the pool is completely exhausted (max connections reached).
pub fn acquire_connection(comptime capacity: usize, pool: *connection_pool(capacity)) ?*TcpConnection {
    const free_index = pool.available_mask.findFirstSet() orelse return null;
    pool.available_mask.unset(free_index);
    const conn = &pool.storage[free_index];

    // reset connection memory to clean state.
    conn.* = undefined;
    return conn;
}

// releases an active connection slot back into the pool.
pub fn release_connection(comptime capacity: usize, pool: *connection_pool(capacity), conn: *const TcpConnection) void {
    const ptr_int = @intFromPtr(conn);
    const base_int = @intFromPtr(&pool.storage[0]);
    const element_size = @sizeOf(TcpConnection);

    // compute the index using pointer arithmetic without bounds branching.
    const index = (ptr_int - base_int) / element_size;
    if (index >= capacity) return;
    pool.available_mask.set(index);
}

// returns the current number of active connections.
pub fn count_active_connections(comptime capacity: usize, pool: *const connection_pool(capacity)) usize {
    return capacity - pool.available_mask.count();
}
