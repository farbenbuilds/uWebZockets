const std = @import("std");

/// Returns an inline fixed-capacity pool tracked by a bitset.
///
/// The generated type never allocates and invalidates a slot pointer when that
/// slot is released.
pub fn bitset_pool(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("pool capacity must be greater than zero");
    if (@sizeOf(T) == 0) @compileError("pool element type must have non-zero size");
    if (capacity > std.math.maxInt(usize) / @sizeOf(T)) {
        @compileError("pool storage size overflows usize");
    }

    return struct {
        const Self = @This();

        // contiguous storage for all possible items.
        storage: [capacity]T = undefined,

        // bitset tracking which slots are available (1) or active (0).
        available_mask: std.StaticBitSet(capacity) = std.StaticBitSet(capacity).initFull(),

        /// Initializes every slot as available.
        pub fn init() Self {
            return .{};
        }

        /// Acquires an uninitialized slot, or returns null when exhausted.
        pub fn acquire(self: *Self) ?*T {
            const free_index = self.available_mask.findFirstSet() orelse return null;
            self.available_mask.unset(free_index);
            return &self.storage[free_index];
        }

        /// Releases an active slot and rejects foreign, misaligned, or free pointers.
        pub fn release(self: *Self, item: *const T) bool {
            const ptr_int = @intFromPtr(item);
            const base_int = @intFromPtr(&self.storage[0]);
            const element_size = @sizeOf(T);
            const end_int = base_int + element_size * capacity;

            if (ptr_int < base_int or ptr_int >= end_int) return false;
            const offset = ptr_int - base_int;
            if (offset % element_size != 0) return false;

            const index = offset / element_size;
            if (self.available_mask.isSet(index)) return false;
            self.available_mask.set(index);
            return true;
        }

        /// Returns the number of currently acquired slots.
        pub fn count_active(self: *const Self) usize {
            return capacity - self.available_mask.count();
        }
    };
}
