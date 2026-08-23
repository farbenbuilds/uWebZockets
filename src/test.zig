const std = @import("std");
const c = @import("c");

test "ensure BoringSSL compiles and links" {
    // Check if BoringSSL constants and types are exposed properly
    try std.testing.expect(c.TLS1_VERSION == 0x0301);
}

test "ensure lsquic compiles and links" {
    // Check if lsquic constants are exposed
    // LSQUIC_MAJOR_VERSION should be at least 3 for modern lsquic
    try std.testing.expect(c.LSQUIC_MAJOR_VERSION >= 3);
}

test "ensure libdeflate compiles and links" {
    // Check if libdeflate functions can be called
    const compressor = c.libdeflate_alloc_compressor(6);
    try std.testing.expect(compressor != null);
    c.libdeflate_free_compressor(compressor);
}
