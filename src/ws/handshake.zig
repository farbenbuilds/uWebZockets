const std = @import("std");

// globally unique identifier required by rfc 6455 for websocket upgrades.
const websocket_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// computes the sec-websocket-accept token strictly on the stack.
// returns a slice pointing to the base64 encoded data inside out_buffer.
pub fn compute_accept_token(client_key: []const u8, out_buffer: *[28]u8) []const u8 {
    // concatenate client key and magic string in a fixed 64-byte stack buffer.
    var combined: [64]u8 = undefined;
    const total_len = client_key.len + websocket_magic.len;

    if (total_len > combined.len) return "";

    @memcpy(combined[0..client_key.len], client_key);
    @memcpy(combined[client_key.len..total_len], websocket_magic);

    // hash with sha-1
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined[0..total_len], &hash, .{});

    // base64 encoding of 20 bytes is exactly 28 bytes.
    return std.base64.standard.Encoder.encode(out_buffer, &hash);
}
