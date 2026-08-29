const std = @import("std");

// globally unique identifier required by rfc 6455 for websocket upgrades.
const websocket_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const ValidationError = error{
    InvalidMethod,
    MissingConnectionUpgrade,
    MissingUpgradeWebSocket,
    MissingVersion,
    UnsupportedVersion,
    MissingKey,
    InvalidKey,
};

pub fn has_token(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, expected)) return true;
    }
    return false;
}

pub fn validate_request(
    method: []const u8,
    connection: ?[]const u8,
    upgrade: ?[]const u8,
    version: ?[]const u8,
    key: ?[]const u8,
) ValidationError![]const u8 {
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidMethod;

    const connection_value = connection orelse return error.MissingConnectionUpgrade;
    if (!has_token(connection_value, "upgrade")) return error.MissingConnectionUpgrade;

    const upgrade_value = upgrade orelse return error.MissingUpgradeWebSocket;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_value, " \t"), "websocket")) {
        return error.MissingUpgradeWebSocket;
    }

    const version_value = version orelse return error.MissingVersion;
    if (!std.mem.eql(u8, std.mem.trim(u8, version_value, " \t"), "13")) {
        return error.UnsupportedVersion;
    }

    const client_key = key orelse return error.MissingKey;
    if (!valid_client_key(client_key)) return error.InvalidKey;
    return client_key;
}

pub fn valid_client_key(client_key: []const u8) bool {
    if (client_key.len != 24) return false;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(client_key) catch return false;
    if (decoded_len != 16) return false;

    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, client_key) catch return false;
    return true;
}

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
