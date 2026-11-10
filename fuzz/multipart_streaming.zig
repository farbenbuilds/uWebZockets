const support = @import("fuzz_support");

pub const max_input_size = support.multipart_streaming.max_input_size;
pub const fuzz_one = support.multipart_streaming.fuzz_one;

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    if (size <= max_input_size) fuzz_one(data[0..size]);
    return 0;
}
