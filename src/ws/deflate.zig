const std = @import("std");
const c = @import("c");

// opaque pointers to libdeflate engines.
pub const Compressor = struct {
    engine_ptr: *c.libdeflate_compressor,
};

pub const Decompressor = struct {
    engine_ptr: *c.libdeflate_decompressor,
};

// initializes a compression engine for a specific compression level.
// level typically ranges from 1 to 12 (6 is optimal).
pub fn init_compressor(level: i32) !Compressor {
    const ptr = c.libdeflate_alloc_compressor(level) orelse return error.InitFailed;
    return Compressor{ .engine_ptr = ptr };
}

// frees the compression engine.
pub fn deinit_compressor(comp: Compressor) void {
    c.libdeflate_free_compressor(comp.engine_ptr);
}

// calculates the maximum buffer size needed for compression.
pub fn get_compress_bound(comp: Compressor, in_len: usize) usize {
    return c.libdeflate_deflate_compress_bound(comp.engine_ptr, in_len);
}

// performs zero-allocation compression into the provided buffer.
pub fn compress(comp: Compressor, in_data: []const u8, out_buffer: []u8) ![]u8 {
    const actual_size = c.libdeflate_deflate_compress(
        comp.engine_ptr,
        in_data.ptr,
        in_data.len,
        out_buffer.ptr,
        out_buffer.len,
    );

    if (actual_size == 0) return error.BufferTooSmall;
    return out_buffer[0..actual_size];
}

// initializes a decompression engine.
pub fn init_decompressor() !Decompressor {
    const ptr = c.libdeflate_alloc_decompressor() orelse return error.InitFailed;
    return Decompressor{ .engine_ptr = ptr };
}

// frees the decompression engine.
pub fn deinit_decompressor(decomp: Decompressor) void {
    c.libdeflate_free_decompressor(decomp.engine_ptr);
}

// performs zero-allocation decompression into the provided buffer.
pub fn decompress(decomp: Decompressor, in_data: []const u8, out_buffer: []u8) ![]u8 {
    var actual_size: usize = 0;
    const result = c.libdeflate_deflate_decompress(
        decomp.engine_ptr,
        in_data.ptr,
        in_data.len,
        out_buffer.ptr,
        out_buffer.len,
        &actual_size,
    );

    if (result != 0) return error.DecompressionFailed; // libdeflate success is 0
    return out_buffer[0..actual_size];
}
