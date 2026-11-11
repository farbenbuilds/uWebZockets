const sql = @import("fuzz_support").sql_parse;

pub const fuzz_one = sql.fuzz_one;

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    if (size <= sql.max_input_bytes) fuzz_one(data[0..size]);
    return 0;
}
