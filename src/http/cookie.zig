const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const signature_length = HmacSha256.mac_length * 2;

pub const SameSite = enum {
    strict,
    lax,
    none,
};

pub const Options = struct {
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    http_only: bool = false,
    secure: bool = false,
    same_site: ?SameSite = null,
};

/// Returns the first RFC 6265 cookie pair matching `name`.
pub fn find(header: []const u8, name: []const u8) ?[]const u8 {
    if (!valid_name(name)) return null;
    var pairs = std.mem.splitScalar(u8, header, ';');
    while (pairs.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t");
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, pair[0..separator], " \t"), name)) continue;
        const value = std.mem.trim(u8, pair[separator + 1 ..], " \t");
        if (!valid_value(value)) return null;
        return value;
    }
    return null;
}

/// Formats one validated Set-Cookie response field into caller storage.
pub fn format(
    buffer: []u8,
    name: []const u8,
    value: []const u8,
    options: Options,
) ![]const u8 {
    if (!valid_name(name)) return error.InvalidCookieName;
    if (!valid_value(value)) return error.InvalidCookieValue;
    if (options.same_site == .none and !options.secure) return error.InsecureSameSiteNone;

    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("Set-Cookie: {s}={s}", .{ name, value });
    if (options.path) |path| {
        if (!valid_attribute(path)) return error.InvalidCookieAttribute;
        try writer.print("; Path={s}", .{path});
    }
    if (options.domain) |domain| {
        if (!valid_attribute(domain)) return error.InvalidCookieAttribute;
        try writer.print("; Domain={s}", .{domain});
    }
    if (options.max_age) |max_age| try writer.print("; Max-Age={d}", .{max_age});
    if (options.http_only) try writer.writeAll("; HttpOnly");
    if (options.secure) try writer.writeAll("; Secure");
    if (options.same_site) |same_site| {
        const value_name = switch (same_site) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
        try writer.print("; SameSite={s}", .{value_name});
    }
    try writer.writeAll("\r\n");
    return writer.buffered();
}

/// Writes `value.hex(HMAC-SHA256(value, secret))` into caller storage.
pub fn sign(buffer: []u8, value: []const u8, secret: []const u8) ![]const u8 {
    if (!valid_value(value)) return error.InvalidCookieValue;
    if (secret.len < 32) return error.CookieSecretTooShort;
    if (buffer.len < value.len + 1 + signature_length) return error.BufferTooSmall;

    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = '.';
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, value, secret);
    encode_hex(buffer[value.len + 1 ..][0..signature_length], &mac);
    return buffer[0 .. value.len + 1 + signature_length];
}

/// Verifies a signed value in constant time and returns its borrowed payload.
pub fn verify_signed(value: []const u8, secret: []const u8) ![]const u8 {
    if (secret.len < 32) return error.CookieSecretTooShort;
    if (value.len <= signature_length or value[value.len - signature_length - 1] != '.') {
        return error.InvalidCookieSignature;
    }
    const payload = value[0 .. value.len - signature_length - 1];
    const encoded = value[value.len - signature_length ..];

    var supplied: [HmacSha256.mac_length]u8 = undefined;
    decode_hex(&supplied, encoded) catch return error.InvalidCookieSignature;
    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, payload, secret);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, supplied)) {
        return error.InvalidCookieSignature;
    }
    return payload;
}

fn valid_name(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn valid_value(value: []const u8) bool {
    for (value) |byte| {
        if (byte == 0x21 or (byte >= 0x23 and byte <= 0x2b) or
            (byte >= 0x2d and byte <= 0x3a) or
            (byte >= 0x3c and byte <= 0x5b) or
            (byte >= 0x5d and byte <= 0x7e)) continue;
        return false;
    }
    return true;
}

fn valid_attribute(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == ';') return false;
    }
    return true;
}

fn encode_hex(output: []u8, input: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (input, 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn decode_hex(output: []u8, input: []const u8) !void {
    if (input.len != output.len * 2) return error.InvalidHex;
    for (output, 0..) |*byte, index| {
        const high = hex_digit(input[index * 2]) orelse return error.InvalidHex;
        const low = hex_digit(input[index * 2 + 1]) orelse return error.InvalidHex;
        byte.* = high << 4 | low;
    }
}

fn hex_digit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
