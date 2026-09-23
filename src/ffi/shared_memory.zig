const std = @import("std");

/// One fixed-block lease: block index, anti-reuse generation, leased length.
pub const Handle = packed struct(u64) {
    block: u16,
    generation: u24,
    length: u24,
};

pub const RegionError = error{
    BufferTooSmall,
    InvalidHandle,
    InvalidLength,
    NoFreeBlock,
};

/// Fixed-block shared memory for zero-copy host bridges.
///
/// Handles carry a generation to reject stale releases and use-after-free.
pub fn region(comptime block_size: usize, comptime block_count: usize) type {
    if (block_size == 0 or block_size > std.math.maxInt(u24)) {
        @compileError("shared-memory block size is outside the handle range");
    }
    if (block_count == 0 or block_count > std.math.maxInt(u16)) {
        @compileError("shared-memory block count is outside the handle range");
    }

    return struct {
        const Self = @This();

        /// One atomic per-block state word: generation plus leased/retired bits.
        const BlockState = std.atomic.Value(u32);
        /// Fixed per-block state table indexed by block number.
        const StateTable = [block_count]BlockState;

        const leased_bit: u32 = 1;
        const retired_bit: u32 = 2;
        const state_shift = 2;

        /// Byte storage for all blocks; 64-byte aligned for host zero-copy views.
        storage: [block_size * block_count]u8 align(64) = undefined,
        /// Lease and generation state for each block.
        states: StateTable = init_states(),

        pub fn acquire(self: *Self, length: usize) RegionError!Handle {
            if (length == 0 or length > block_size) return error.InvalidLength;
            for (&self.states, 0..) |*state, index| {
                var observed = state.load(.acquire);
                while (observed & (leased_bit | retired_bit) == 0) {
                    const desired = observed | leased_bit;
                    observed = state.cmpxchgWeak(
                        observed,
                        desired,
                        .acq_rel,
                        .acquire,
                    ) orelse return .{
                        .block = @intCast(index),
                        .generation = @truncate(observed >> state_shift),
                        .length = @intCast(length),
                    };
                }
            }
            return error.NoFreeBlock;
        }

        pub fn bytes(self: *Self, handle: Handle) RegionError![]u8 {
            try self.validate(handle);
            const start = @as(usize, handle.block) * block_size;
            return self.storage[start .. start + handle.length];
        }

        pub fn capacity(self: *Self, handle: Handle) RegionError![]u8 {
            try self.validate(handle);
            const start = @as(usize, handle.block) * block_size;
            return self.storage[start .. start + block_size];
        }

        pub fn commit(self: *Self, handle: Handle, length: usize) RegionError!Handle {
            try self.validate(handle);
            if (length > block_size) return error.InvalidLength;
            var committed = handle;
            committed.length = @intCast(length);
            return committed;
        }

        pub fn release(self: *Self, handle: Handle) RegionError!void {
            const index: usize = handle.block;
            if (index >= block_count) return error.InvalidHandle;
            const expected = encode_state(handle.generation, true);
            const releasing = expected | retired_bit;
            if (self.states[index].cmpxchgStrong(
                expected,
                releasing,
                .acq_rel,
                .acquire,
            ) != null) return error.InvalidHandle;

            const start = index * block_size;
            std.crypto.secureZero(u8, self.storage[start .. start + block_size]);
            if (handle.generation == std.math.maxInt(u24)) {
                self.states[index].store(releasing & ~leased_bit, .release);
                return;
            }
            self.states[index].store(
                encode_state(handle.generation + 1, false),
                .release,
            );
        }

        pub fn handle_from_pointer(
            self: *Self,
            pointer: [*]u8,
            length: usize,
        ) RegionError!Handle {
            if (length == 0 or length > block_size) return error.InvalidLength;
            const base = @intFromPtr(&self.storage);
            const address = @intFromPtr(pointer);
            if (address < base or address >= base + self.storage.len) return error.InvalidHandle;
            const offset = address - base;
            if (offset % block_size != 0) return error.InvalidHandle;
            const index = offset / block_size;
            const state = self.states[index].load(.acquire);
            if (state & leased_bit == 0) return error.InvalidHandle;
            return .{
                .block = @intCast(index),
                .generation = @truncate(state >> state_shift),
                .length = @intCast(length),
            };
        }

        fn validate(self: *Self, handle: Handle) RegionError!void {
            const index: usize = handle.block;
            if (index >= block_count or handle.length > block_size) {
                return error.InvalidHandle;
            }
            if (self.states[index].load(.acquire) != encode_state(handle.generation, true)) {
                return error.InvalidHandle;
            }
        }

        fn init_states() StateTable {
            var result: StateTable = undefined;
            for (&result) |*state| state.* = .init(0);
            return result;
        }

        fn encode_state(generation: u24, leased: bool) u32 {
            return (@as(u32, generation) << state_shift) | @intFromBool(leased);
        }
    };
}

/// Writes a Cap'n Proto single-segment envelope around encoded wire words.
pub fn write_capnp_message(encoded_words: []const u8, output: []u8) RegionError![]u8 {
    if (encoded_words.len % 8 != 0) return error.InvalidLength;
    if (encoded_words.len > std.math.maxInt(u32) * 8) return error.InvalidLength;
    if (output.len < 8 or encoded_words.len > output.len - 8) return error.BufferTooSmall;
    write_u32_le(output[0..4], 0);
    write_u32_le(output[4..8], @intCast(encoded_words.len / 8));
    @memcpy(output[8 .. 8 + encoded_words.len], encoded_words);
    return output[0 .. 8 + encoded_words.len];
}

/// Validates and returns the borrowed segment from a Cap'n Proto message.
pub fn read_capnp_message(message: []const u8, max_words: usize) RegionError![]const u8 {
    if (message.len < 8 or message.len % 8 != 0) return error.InvalidLength;
    if (read_u32_le(message[0..4]) != 0) return error.InvalidLength;
    const word_count: usize = read_u32_le(message[4..8]);
    if (word_count > max_words) return error.InvalidLength;
    const byte_count = std.math.mul(usize, word_count, 8) catch return error.InvalidLength;
    if (byte_count != message.len - 8) return error.InvalidLength;
    return message[8..];
}

fn write_u32_le(destination: []u8, value: u32) void {
    destination[0] = @truncate(value);
    destination[1] = @truncate(value >> 8);
    destination[2] = @truncate(value >> 16);
    destination[3] = @truncate(value >> 24);
}

fn read_u32_le(source: []const u8) u32 {
    return @as(u32, source[0]) |
        (@as(u32, source[1]) << 8) |
        (@as(u32, source[2]) << 16) |
        (@as(u32, source[3]) << 24);
}
