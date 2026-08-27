const std = @import("std");
const handshake = @import("../ws/handshake.zig");

// tests websocket accept token computation based on rfc 6455
test "ws: compute_accept_token" {
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    var out_buffer: [28]u8 = undefined;

    const accept_token = handshake.compute_accept_token(client_key, &out_buffer);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_token);
}
