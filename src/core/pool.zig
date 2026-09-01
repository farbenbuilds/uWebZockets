const std = @import("std");

/// Returns a page-backed fixed-capacity pool with O(1) acquire and release.
///
/// The generated type allocates its slab only during `init`; steady-state slot
/// operations do not allocate.
pub fn freelist_pool(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("pool capacity must be greater than zero");
    if (@sizeOf(T) == 0) @compileError("pool element type must have non-zero size");
    if (capacity > std.math.maxInt(usize) / @sizeOf(T)) {
        @compileError("pool storage size overflows usize");
    }

    return struct {
        const Self = @This();

        // 1. slab memory: contiguous memory storing all items.
        storage: []T = undefined,

        // 2. freelist (stack): stores the indices of available slots.
        free_indices: []usize = undefined,
        free_count: usize = capacity,
        active: std.StaticBitSet(capacity) = .empty,

        /// Allocates and zeroes the slab and freelist storage.
        pub fn init() !Self {
            var pool: Self = undefined;
            pool.free_count = capacity;
            pool.active = .empty;

            // allocate memory for the slab and freelist
            pool.storage = try std.heap.page_allocator.alloc(T, capacity);
            errdefer std.heap.page_allocator.free(pool.storage);

            // strictly zero-initialize the slab to prevent garbage state on first use
            const bytes = std.mem.sliceAsBytes(pool.storage);
            @memset(bytes, 0);

            pool.free_indices = try std.heap.page_allocator.alloc(usize, capacity);

            // push all indices from 0 to capacity-1 into the free stack
            for (pool.free_indices, 0..) |*item, i| {
                item.* = i;
            }
            return pool;
        }

        /// Releases the slab and freelist; no acquired slot may be used afterward.
        pub fn deinit(self: *Self) void {
            std.heap.page_allocator.free(self.storage);
            std.heap.page_allocator.free(self.free_indices);
        }

        /// Acquires a slot, or returns null when all `capacity` slots are active.
        pub fn acquire(self: *Self) ?*T {
            if (self.free_count == 0) {
                return null;
            }

            // pop index from the top of the stack
            self.free_count -= 1;
            const index = self.free_indices[self.free_count];
            std.debug.assert(!self.active.isSet(index));
            self.active.set(index);

            return &self.storage[index];
        }

        /// Releases an active slot and rejects foreign, misaligned, or free pointers.
        pub fn release(self: *Self, item: *T) bool {
            // pointer arithmetic to calculate the index from the ram address
            const start_ptr = @intFromPtr(&self.storage[0]);
            const item_ptr = @intFromPtr(item);
            const end_ptr = start_ptr + @sizeOf(T) * capacity;
            if (item_ptr < start_ptr or item_ptr >= end_ptr) return false;
            const offset = item_ptr - start_ptr;

            if (offset % @sizeOf(T) != 0) return false;
            const index = offset / @sizeOf(T);
            if (index >= capacity or !self.active.isSet(index)) return false;
            if (self.free_count >= capacity) return false;

            // push index back onto the stack
            self.active.unset(index);
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
            return true;
        }

        /// Returns the number of currently acquired slots.
        pub fn count_active(self: *const Self) usize {
            return capacity - self.free_count;
        }

        /// Reports whether `index` names an acquired slot.
        pub fn is_active(self: *const Self, index: usize) bool {
            return index < capacity and self.active.isSet(index);
        }

        /// Returns the slab index for an aligned in-range pointer.
        pub fn index_of(self: *const Self, item: *const T) ?usize {
            const start_ptr = @intFromPtr(&self.storage[0]);
            const item_ptr = @intFromPtr(item);
            const end_ptr = start_ptr + @sizeOf(T) * capacity;
            if (item_ptr < start_ptr or item_ptr >= end_ptr) return null;

            const offset = item_ptr - start_ptr;
            if (offset % @sizeOf(T) != 0) return null;
            const index = offset / @sizeOf(T);
            return if (index < capacity) index else null;
        }
    };
}
