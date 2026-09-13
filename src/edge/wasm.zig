const shared = @import("../ffi/shared_memory.zig");

comptime {
    _ = @import("root.zig");
}

const block_size = 64 * 1024;
const block_count = 64;
const SharedRegion = shared.region(block_size, block_count);

var shared_region: SharedRegion = .{};

/// Acquires one fixed shared-memory block for a host TypedArray view.
export fn alloc(length: u32) usize {
    const handle = shared_region.acquire(length) catch return 0;
    const bytes = shared_region.capacity(handle) catch return 0;
    return @intFromPtr(bytes.ptr);
}

/// Releases a block after validating its base pointer and length.
export fn free(pointer: usize, length: u32) void {
    if (pointer == 0) return;
    const bytes: [*]u8 = @ptrFromInt(pointer);
    const handle = shared_region.handle_from_pointer(bytes, length) catch return;
    shared_region.release(handle) catch return;
}

/// Returns a generation-checked handle for ownership-aware host bridges.
export fn shared_acquire(length: u32) u64 {
    const handle = shared_region.acquire(length) catch return 0;
    return @bitCast(handle);
}

export fn shared_pointer(encoded_handle: u64) usize {
    if (encoded_handle == 0) return 0;
    const handle: shared.Handle = @bitCast(encoded_handle);
    const bytes = shared_region.capacity(handle) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn shared_commit(encoded_handle: u64, length: u32) u64 {
    if (encoded_handle == 0) return 0;
    const handle: shared.Handle = @bitCast(encoded_handle);
    const committed = shared_region.commit(handle, length) catch return 0;
    return @bitCast(committed);
}

export fn shared_release(encoded_handle: u64) i32 {
    if (encoded_handle == 0) return -1;
    const handle: shared.Handle = @bitCast(encoded_handle);
    shared_region.release(handle) catch return -1;
    return 0;
}
