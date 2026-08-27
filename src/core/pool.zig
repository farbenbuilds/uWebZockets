const std = @import("std");

// a generic fixed-size memory pool using a stack-based freelist.
// achieves strict o(1) acquire/release times without loops, ideal for zero-allocation hot paths.
pub fn freelist_pool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        // 1. slab memory: contiguous memory storing all items.
        storage: []T = undefined,

        // 2. freelist (stack): stores the indices of available slots.
        free_indices: []usize = undefined,
        free_count: usize = capacity,

        // initializes the pool. called once during setup.
        pub fn init() !Self {
            var pool: Self = undefined;
            pool.free_count = capacity;

            // allocate memory for the slab and freelist
            pool.storage = try std.heap.page_allocator.alloc(T, capacity);
            pool.free_indices = try std.heap.page_allocator.alloc(usize, capacity);

            // push all indices from 0 to capacity-1 into the free stack
            for (pool.free_indices, 0..) |*item, i| {
                item.* = i;
            }
            return pool;
        }

        pub fn deinit(self: *Self) void {
            std.heap.page_allocator.free(self.storage);
            std.heap.page_allocator.free(self.free_indices);
        }

        // acquires a memory slot from the pool (zero-allocation, o(1)).
        pub fn acquire(self: *Self) ?*T {
            if (self.free_count == 0) {
                return null;
            }

            // pop index from the top of the stack
            self.free_count -= 1;
            const index = self.free_indices[self.free_count];

            return &self.storage[index];
        }

        // returns a memory slot back to the pool (o(1)).
        pub fn release(self: *Self, item: *T) void {
            // pointer arithmetic to calculate the index from the ram address
            const start_ptr = @intFromPtr(&self.storage[0]);
            const item_ptr = @intFromPtr(item);
            const offset = item_ptr - start_ptr;

            // safety check: ensure the pointer strictly belongs to our memory slab
            std.debug.assert(offset % @sizeOf(T) == 0);
            const index = offset / @sizeOf(T);
            std.debug.assert(index < capacity);

            // push index back onto the stack
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
        }

        // returns the current number of active items.
        pub fn count_active(self: *const Self) usize {
            return capacity - self.free_count;
        }
    };
}
