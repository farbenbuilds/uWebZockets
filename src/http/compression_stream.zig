const c = @import("c");

pub const Format = enum(u8) {
    deflate,
    deflate_raw,
    gzip,
};

pub const StreamError = error{
    BufferTooSmall,
    InitFailed,
    InvalidData,
    StreamClosed,
};

/// Bounded CompressionStream backed directly by libdeflate.
///
/// Writes stage chunks in caller-owned storage; finish performs one codec pass
/// into caller-owned output. The reusable codec is allocated only at init.
pub const CompressionStream = struct {
    compressor: *c.libdeflate_compressor,
    input: []u8,
    input_length: usize = 0,
    format: Format,
    closed: bool = false,

    pub fn init(format: Format, level: i32, input_storage: []u8) StreamError!CompressionStream {
        if (input_storage.len == 0) return error.BufferTooSmall;
        const compressor = c.libdeflate_alloc_compressor(level) orelse return error.InitFailed;
        return .{
            .compressor = compressor,
            .input = input_storage,
            .format = format,
        };
    }

    pub fn deinit(self: *CompressionStream) void {
        c.libdeflate_free_compressor(self.compressor);
        self.* = undefined;
    }

    pub fn write(self: *CompressionStream, chunk: []const u8) StreamError!void {
        if (self.closed) return error.StreamClosed;
        if (chunk.len > self.input.len - self.input_length) return error.BufferTooSmall;
        @memcpy(self.input[self.input_length .. self.input_length + chunk.len], chunk);
        self.input_length += chunk.len;
    }

    pub fn output_bound(self: *const CompressionStream) usize {
        return switch (self.format) {
            .deflate => c.libdeflate_zlib_compress_bound(self.compressor, self.input_length),
            .deflate_raw => c.libdeflate_deflate_compress_bound(self.compressor, self.input_length),
            .gzip => c.libdeflate_gzip_compress_bound(self.compressor, self.input_length),
        };
    }

    pub fn finish(self: *CompressionStream, output: []u8) StreamError![]u8 {
        if (self.closed) return error.StreamClosed;
        const output_length = switch (self.format) {
            .deflate => c.libdeflate_zlib_compress(
                self.compressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
            ),
            .deflate_raw => c.libdeflate_deflate_compress(
                self.compressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
            ),
            .gzip => c.libdeflate_gzip_compress(
                self.compressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
            ),
        };
        if (output_length == 0) return error.BufferTooSmall;
        self.closed = true;
        return output[0..output_length];
    }
};

/// Bounded DecompressionStream backed directly by libdeflate.
pub const DecompressionStream = struct {
    decompressor: *c.libdeflate_decompressor,
    input: []u8,
    input_length: usize = 0,
    format: Format,
    closed: bool = false,

    pub fn init(format: Format, input_storage: []u8) StreamError!DecompressionStream {
        if (input_storage.len == 0) return error.BufferTooSmall;
        const decompressor = c.libdeflate_alloc_decompressor() orelse return error.InitFailed;
        return .{
            .decompressor = decompressor,
            .input = input_storage,
            .format = format,
        };
    }

    pub fn deinit(self: *DecompressionStream) void {
        c.libdeflate_free_decompressor(self.decompressor);
        self.* = undefined;
    }

    pub fn write(self: *DecompressionStream, chunk: []const u8) StreamError!void {
        if (self.closed) return error.StreamClosed;
        if (chunk.len > self.input.len - self.input_length) return error.BufferTooSmall;
        @memcpy(self.input[self.input_length .. self.input_length + chunk.len], chunk);
        self.input_length += chunk.len;
    }

    pub fn finish(self: *DecompressionStream, output: []u8) StreamError![]u8 {
        if (self.closed) return error.StreamClosed;
        var output_length: usize = 0;
        const result = switch (self.format) {
            .deflate => c.libdeflate_zlib_decompress(
                self.decompressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
                &output_length,
            ),
            .deflate_raw => c.libdeflate_deflate_decompress(
                self.decompressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
                &output_length,
            ),
            .gzip => c.libdeflate_gzip_decompress(
                self.decompressor,
                self.input.ptr,
                self.input_length,
                output.ptr,
                output.len,
                &output_length,
            ),
        };
        if (result == c.LIBDEFLATE_INSUFFICIENT_SPACE) return error.BufferTooSmall;
        if (result != c.LIBDEFLATE_SUCCESS) return error.InvalidData;
        self.closed = true;
        return output[0..output_length];
    }
};
