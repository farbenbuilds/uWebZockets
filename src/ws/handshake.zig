const std = @import("std");

// globally unique identifier required by rfc 6455 for websocket upgrades.
const websocket_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Reasons an RFC 6455 upgrade request is rejected.
pub const ValidationError = error{
    InvalidMethod,
    MissingConnectionUpgrade,
    MissingUpgradeWebSocket,
    MissingVersion,
    UnsupportedVersion,
    MissingKey,
    InvalidKey,
};

/// Negotiated RFC 7692 window constraints for no-context-takeover operation.
pub const PerMessageDeflate = struct {
    /// Server compression window, or the 15-bit default when absent.
    server_max_window_bits: ?u4 = null,
    /// Maximum accepted client compression window, or the default when absent.
    client_max_window_bits: ?u4 = null,
};

/// Reports whether a comma-delimited field contains `expected`.
pub fn has_token(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, expected)) return true;
    }
    return false;
}

/// Validates required RFC 6455 request fields and returns the borrowed key.
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

/// Reports whether a key is canonical-length base64 encoding of 16 bytes.
pub fn valid_client_key(client_key: []const u8) bool {
    if (client_key.len != 24) return false;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(client_key) catch return false;
    if (decoded_len != 16) return false;

    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, client_key) catch return false;
    return true;
}

/// Writes the Sec-WebSocket-Accept token and returns a slice into `out_buffer`.
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

/// Selects the first compatible no-context-takeover permessage-deflate offer.
///
/// An 8-bit server window is rejected because zlib cannot encode it reliably;
/// bounded 8-bit client windows remain valid for decompression.
pub fn negotiate_permessage_deflate(value: []const u8) ?PerMessageDeflate {
    var offers = std.mem.splitScalar(u8, value, ',');
    while (offers.next()) |offer| {
        if (parse_permessage_deflate_offer(offer)) |negotiated| return negotiated;
    }
    return null;
}

/// Formats negotiated extension response fields into caller storage.
pub fn format_permessage_deflate_response(
    negotiated: PerMessageDeflate,
    output: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);

    try writer.writeAll(
        "Sec-WebSocket-Extensions: permessage-deflate" ++
            "; server_no_context_takeover" ++
            "; client_no_context_takeover",
    );
    if (negotiated.server_max_window_bits) |bits| {
        try writer.print("; server_max_window_bits={d}", .{bits});
    }
    if (negotiated.client_max_window_bits) |bits| {
        try writer.print("; client_max_window_bits={d}", .{bits});
    }
    try writer.writeAll("\r\n");
    return writer.buffered();
}

fn parse_permessage_deflate_offer(offer: []const u8) ?PerMessageDeflate {
    var fields = std.mem.splitScalar(u8, offer, ';');
    const extension = std.mem.trim(u8, fields.next() orelse return null, " \t");
    if (!std.ascii.eqlIgnoreCase(extension, "permessage-deflate")) return null;

    var negotiated = PerMessageDeflate{};
    var saw_server_no_context = false;
    var saw_client_no_context = false;
    var saw_server_window = false;
    var saw_client_window = false;

    while (fields.next()) |field_value| {
        const field = std.mem.trim(u8, field_value, " \t");
        if (field.len == 0) return null;

        const equals = std.mem.indexOfScalar(u8, field, '=');
        const name = std.mem.trim(u8, field[0 .. equals orelse field.len], " \t");
        const raw_value = if (equals) |index|
            std.mem.trim(u8, field[index + 1 ..], " \t")
        else
            null;

        if (std.ascii.eqlIgnoreCase(name, "server_no_context_takeover")) {
            if (saw_server_no_context or raw_value != null) return null;
            saw_server_no_context = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "client_no_context_takeover")) {
            if (saw_client_no_context or raw_value != null) return null;
            saw_client_no_context = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "server_max_window_bits")) {
            if (saw_server_window) return null;
            saw_server_window = true;
            const bits = parse_window_bits(raw_value orelse return null) orelse return null;
            // zlib cannot represent an 8-bit compression window reliably;
            // accept every interoperable 9-15 bit window.
            if (bits == 8) return null;
            negotiated.server_max_window_bits = bits;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "client_max_window_bits")) {
            if (saw_client_window) return null;
            saw_client_window = true;
            negotiated.client_max_window_bits = if (raw_value) |candidate|
                parse_window_bits(candidate) orelse return null
            else
                15;
            continue;
        }
        return null;
    }

    return negotiated;
}

fn parse_window_bits(raw_value: []const u8) ?u4 {
    var value = raw_value;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    if (value.len == 0 or value.len > 2) return null;

    const parsed = std.fmt.parseInt(u8, value, 10) catch return null;
    if (parsed < 8 or parsed > 15) return null;
    return @intCast(parsed);
}
