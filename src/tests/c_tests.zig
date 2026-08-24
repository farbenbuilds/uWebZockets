const std = @import("std");
const c = @import("c");

test "ensure boringssl compiles and links" {
    // check if boringssl constants and types are exposed properly.
    try std.testing.expect(c.TLS1_VERSION == 0x0301);
}

test "ensure lsquic compiles and links" {
    // check if lsquic constants are exposed.
    try std.testing.expect(c.LSQUIC_MAJOR_VERSION >= 3);
}

test "ensure libdeflate compiles and links" {
    // check if libdeflate functions can be called.
    const compressor = c.libdeflate_alloc_compressor(6);
    try std.testing.expect(compressor != null);
    c.libdeflate_free_compressor(compressor);
}
