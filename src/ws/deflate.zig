const std = @import("std");
const c = @import("c");

// A sync-flushed per-message stream is not final. Restore its stripped tail,
// then append a final empty block so libdeflate can process it as one block.
const sync_flush_tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
const final_empty_block = [_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff };
/// Scratch bytes reserved after a compressed message for decode finalization.
pub const decode_tail_len = sync_flush_tail.len + final_empty_block.len;

/// Setup and bounded per-message compression failures.
pub const Error = error{
    OutOfMemory,
    InitFailed,
    SizeOverflow,
    BufferTooSmall,
    InvalidCompressedData,
    OutputTooLarge,
};

/// Reusable per-message DEFLATE engines allocated during application setup.
///
/// Compression and decompression use only caller-owned buffers after `init`.
pub const Context = struct {
    compressor: *c.libdeflate_compressor,
    decompressor: *c.libdeflate_decompressor,
    window_compressors: [window_compressor_count]WindowCompressor,

    /// Allocates reusable compression engines for window sizes 9 through 15.
    pub fn init(level: i32) Error!Context {
        const compressor = c.libdeflate_alloc_compressor(level) orelse return error.InitFailed;
        errdefer c.libdeflate_free_compressor(compressor);

        const decompressor = c.libdeflate_alloc_decompressor() orelse return error.InitFailed;
        errdefer c.libdeflate_free_decompressor(decompressor);

        var window_compressors: [window_compressor_count]WindowCompressor = undefined;
        var initialized: usize = 0;
        errdefer {
            while (initialized != 0) {
                initialized -= 1;
                window_compressors[initialized].deinit();
            }
        }
        while (initialized < window_compressors.len) : (initialized += 1) {
            const window_bits: u4 = @intCast(min_window_bits + initialized);
            window_compressors[initialized] = try WindowCompressor.init(window_bits, level);
        }

        return .{
            .compressor = compressor,
            .decompressor = decompressor,
            .window_compressors = window_compressors,
        };
    }

    /// Releases every compression engine and invalidates the context.
    pub fn deinit(self: *Context) void {
        for (&self.window_compressors) |*compressor| compressor.deinit();
        c.libdeflate_free_decompressor(self.decompressor);
        c.libdeflate_free_compressor(self.compressor);
        self.* = undefined;
    }

    /// Returns worst-case scratch bytes for any supported negotiated window.
    pub fn scratch_bound(self: *const Context, input_len: usize) Error!usize {
        if (input_len > std.math.maxInt(c_ulong)) return error.SizeOverflow;

        var compressed_bound = c.libdeflate_deflate_compress_bound(self.compressor, input_len);
        for (&self.window_compressors) |*compressor| {
            const window_bound: usize = @intCast(c.deflateBound(
                &compressor.storage.stream,
                @intCast(input_len),
            ));
            compressed_bound = @max(compressed_bound, window_bound);
        }
        return std.math.add(usize, compressed_bound, decode_tail_len) catch error.SizeOverflow;
    }

    /// Compresses one no-context-takeover message into `scratch`.
    ///
    /// The returned slice borrows `scratch` and includes a compatibility byte
    /// used to expose a non-final RFC 7692 payload.
    pub fn compress_message(
        self: *Context,
        input: []const u8,
        scratch: []u8,
    ) Error![]const u8 {
        if (scratch.len == 0) return error.BufferTooSmall;

        const compressed_len = c.libdeflate_deflate_compress(
            self.compressor,
            input.ptr,
            input.len,
            scratch.ptr,
            scratch.len - 1,
        );
        if (compressed_len == 0) return error.BufferTooSmall;

        scratch[compressed_len] = 0;
        return scratch[0 .. compressed_len + 1];
    }

    /// Compresses one message using a negotiated 9-through-15-bit window.
    pub fn compress_message_window(
        self: *Context,
        input: []const u8,
        scratch: []u8,
        window_bits: u4,
    ) Error![]const u8 {
        if (window_bits == 15) return self.compress_message(input, scratch);
        if (window_bits < min_window_bits or window_bits > max_zlib_window_bits) {
            return error.InvalidCompressedData;
        }

        const index = @as(usize, window_bits) - min_window_bits;
        return self.window_compressors[index].compress_message(input, scratch);
    }

    /// Decompresses one message into bounded caller storage.
    ///
    /// `input` must begin at `scratch.ptr`; decode finalization bytes are
    /// appended in place. Exhausting `output` reports `OutputTooLarge`.
    pub fn decompress_message(
        self: *Context,
        input: []const u8,
        scratch: []u8,
        output: []u8,
    ) Error![]u8 {
        if (input.len > scratch.len) return error.BufferTooSmall;
        if (input.ptr != scratch.ptr) return error.InvalidCompressedData;
        if (decode_tail_len > scratch.len - input.len) return error.BufferTooSmall;

        var tail_offset = input.len;
        @memcpy(scratch[tail_offset .. tail_offset + sync_flush_tail.len], &sync_flush_tail);
        tail_offset += sync_flush_tail.len;
        @memcpy(scratch[tail_offset .. tail_offset + final_empty_block.len], &final_empty_block);
        tail_offset += final_empty_block.len;

        var consumed: usize = 0;
        var output_len: usize = 0;
        const result = c.libdeflate_deflate_decompress_ex(
            self.decompressor,
            scratch.ptr,
            tail_offset,
            output.ptr,
            output.len,
            &consumed,
            &output_len,
        );

        return switch (result) {
            c.LIBDEFLATE_SUCCESS => output[0..output_len],
            c.LIBDEFLATE_INSUFFICIENT_SPACE => error.OutputTooLarge,
            else => error.InvalidCompressedData,
        };
    }
};

const min_window_bits: usize = 9;
const max_zlib_window_bits: u4 = 14;
const window_compressor_count = @as(usize, max_zlib_window_bits) - min_window_bits + 1;
const zlib_arena_capacity = 384 * 1024;
const zlib_alignment = @alignOf(std.c.max_align_t);

const ZlibArena = struct {
    bytes: [zlib_arena_capacity]u8 align(zlib_alignment) = undefined,
    used: usize = 0,
};

const ZlibStorage = struct {
    stream: c.z_stream = std.mem.zeroes(c.z_stream),
    arena: ZlibArena = .{},
};

const WindowCompressor = struct {
    storage: *ZlibStorage,

    fn init(window_bits: u4, level: i32) Error!WindowCompressor {
        const storage = std.heap.page_allocator.create(ZlibStorage) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.destroy(storage);
        storage.* = .{};
        storage.stream.zalloc = zlib_alloc;
        storage.stream.zfree = zlib_free;
        storage.stream.@"opaque" = &storage.arena;

        const result = c.deflateInit2(
            &storage.stream,
            level,
            c.Z_DEFLATED,
            -@as(c_int, window_bits),
            8,
            c.Z_DEFAULT_STRATEGY,
        );
        if (result != c.Z_OK) return error.InitFailed;
        return .{ .storage = storage };
    }

    fn deinit(self: *WindowCompressor) void {
        _ = c.deflateEnd(&self.storage.stream);
        std.heap.page_allocator.destroy(self.storage);
        self.* = undefined;
    }

    fn compress_message(
        self: *WindowCompressor,
        input: []const u8,
        output: []u8,
    ) Error![]const u8 {
        const stream = &self.storage.stream;
        if (c.deflateReset(stream) != c.Z_OK) return error.InitFailed;

        var input_offset: usize = 0;
        var output_offset: usize = 0;
        while (input_offset < input.len) {
            if (output_offset == output.len) return error.BufferTooSmall;
            const input_len: c_uint = @intCast(@min(
                input.len - input_offset,
                std.math.maxInt(c_uint),
            ));
            const output_len: c_uint = @intCast(@min(
                output.len - output_offset,
                std.math.maxInt(c_uint),
            ));
            stream.next_in = @ptrCast(@constCast(input[input_offset..].ptr));
            stream.avail_in = input_len;
            stream.next_out = @ptrCast(output[output_offset..].ptr);
            stream.avail_out = output_len;

            const result = c.deflate(stream, c.Z_NO_FLUSH);
            if (result != c.Z_OK) return error.InvalidCompressedData;
            input_offset += input_len - stream.avail_in;
            output_offset += output_len - stream.avail_out;
            if (stream.avail_in != 0 and stream.avail_out != 0) {
                return error.InvalidCompressedData;
            }
        }

        while (true) {
            if (output_offset == output.len) return error.BufferTooSmall;
            const output_len: c_uint = @intCast(@min(
                output.len - output_offset,
                std.math.maxInt(c_uint),
            ));
            stream.next_in = null;
            stream.avail_in = 0;
            stream.next_out = @ptrCast(output[output_offset..].ptr);
            stream.avail_out = output_len;

            const result = c.deflate(stream, c.Z_SYNC_FLUSH);
            if (result != c.Z_OK) return error.InvalidCompressedData;
            output_offset += output_len - stream.avail_out;
            if (stream.avail_out != 0) break;
        }

        if (output_offset < sync_flush_tail.len) return error.InvalidCompressedData;
        const payload_len = output_offset - sync_flush_tail.len;
        if (!std.mem.eql(u8, output[payload_len..output_offset], &sync_flush_tail)) {
            return error.InvalidCompressedData;
        }
        return output[0..payload_len];
    }
};

fn zlib_alloc(user_data: ?*anyopaque, item_count: c_uint, item_size: c_uint) callconv(.c) ?*anyopaque {
    const arena: *ZlibArena = @ptrCast(@alignCast(user_data orelse return null));
    const byte_count = std.math.mul(
        usize,
        @as(usize, item_count),
        @as(usize, item_size),
    ) catch return null;
    const start = std.mem.alignForward(usize, arena.used, zlib_alignment);
    if (start > arena.bytes.len or byte_count > arena.bytes.len - start) return null;

    const end = start + byte_count;
    @memset(arena.bytes[start..end], 0);
    arena.used = end;
    return arena.bytes[start..end].ptr;
}

fn zlib_free(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

/// Legacy owning libdeflate compressor handle.
pub const Compressor = struct {
    engine_ptr: *c.libdeflate_compressor,
};

/// Legacy owning libdeflate decompressor handle.
pub const Decompressor = struct {
    engine_ptr: *c.libdeflate_decompressor,
};

/// Allocates a legacy compressor at `level`.
pub fn init_compressor(level: i32) !Compressor {
    const ptr = c.libdeflate_alloc_compressor(level) orelse return error.InitFailed;
    return .{ .engine_ptr = ptr };
}

/// Releases a legacy compressor handle.
pub fn deinit_compressor(comp: Compressor) void {
    c.libdeflate_free_compressor(comp.engine_ptr);
}

/// Returns libdeflate's worst-case output size for `input_len`.
pub fn get_compress_bound(comp: Compressor, input_len: usize) usize {
    return c.libdeflate_deflate_compress_bound(comp.engine_ptr, input_len);
}

/// Compresses into caller storage and returns its initialized prefix.
pub fn compress(comp: Compressor, input: []const u8, output: []u8) ![]u8 {
    const output_len = c.libdeflate_deflate_compress(
        comp.engine_ptr,
        input.ptr,
        input.len,
        output.ptr,
        output.len,
    );
    if (output_len == 0) return error.BufferTooSmall;
    return output[0..output_len];
}

/// Allocates a legacy decompressor.
pub fn init_decompressor() !Decompressor {
    const ptr = c.libdeflate_alloc_decompressor() orelse return error.InitFailed;
    return .{ .engine_ptr = ptr };
}

/// Releases a legacy decompressor handle.
pub fn deinit_decompressor(decomp: Decompressor) void {
    c.libdeflate_free_decompressor(decomp.engine_ptr);
}

/// Decompresses into bounded caller storage and returns its initialized prefix.
pub fn decompress(decomp: Decompressor, input: []const u8, output: []u8) ![]u8 {
    var output_len: usize = 0;
    const result = c.libdeflate_deflate_decompress(
        decomp.engine_ptr,
        input.ptr,
        input.len,
        output.ptr,
        output.len,
        &output_len,
    );
    if (result != c.LIBDEFLATE_SUCCESS) return error.DecompressionFailed;
    return output[0..output_len];
}
