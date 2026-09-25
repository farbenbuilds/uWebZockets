const std = @import("std");
const simd = @import("../core/simd.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const signature_length = HmacSha256.mac_length * 2;

/// SameSite attribute policy; `none` additionally requires `secure`.
pub const SameSite = enum {
    strict,
    lax,
    none,
};

/// One RFC 9110 IMF-fixdate: 29 bytes, for example `Wed, 21 Oct 2015 07:28:00 GMT`.
pub const HttpDateBuffer = [29]u8;

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Civil calendar date decomposed from a day count since the Unix epoch.
const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

/// Formats `unix_seconds` as an IMF-fixdate into caller storage.
///
/// Pure integer math; callers own the clock. Seconds before the epoch and
/// dates past year 9999 fail closed.
pub fn format_http_date(buffer: *HttpDateBuffer, unix_seconds: i64) error{InvalidExpires}![]const u8 {
    if (unix_seconds < 0) return error.InvalidExpires;
    const days = @divFloor(unix_seconds, 86400);
    const civil = civil_from_days(days);
    if (civil.year > 9999) return error.InvalidExpires;

    const seconds_of_day = @mod(unix_seconds, 86400);
    @memcpy(buffer[0..3], weekday_names[@intCast(@mod(days + 4, 7))]);
    buffer[3] = ',';
    buffer[4] = ' ';
    write_two_digits(buffer[5..7], civil.day);
    buffer[7] = ' ';
    @memcpy(buffer[8..11], month_names[civil.month - 1]);
    buffer[11] = ' ';
    write_four_digits(buffer[12..16], @intCast(civil.year));
    buffer[16] = ' ';
    write_two_digits(buffer[17..19], @intCast(@divFloor(seconds_of_day, 3600)));
    buffer[19] = ':';
    write_two_digits(buffer[20..22], @intCast(@divFloor(@mod(seconds_of_day, 3600), 60)));
    buffer[22] = ':';
    write_two_digits(buffer[23..25], @intCast(@mod(seconds_of_day, 60)));
    buffer[25] = ' ';
    @memcpy(buffer[26..29], "GMT");
    return buffer[0..];
}

fn write_two_digits(buffer: []u8, value: u8) void {
    buffer[0] = '0' + value / 10;
    buffer[1] = '0' + value % 10;
}

fn write_four_digits(buffer: []u8, value: u16) void {
    buffer[0] = '0' + @as(u8, @intCast(value / 1000));
    buffer[1] = '0' + @as(u8, @intCast(value / 100 % 10));
    buffer[2] = '0' + @as(u8, @intCast(value / 10 % 10));
    buffer[3] = '0' + @as(u8, @intCast(value % 10));
}

/// Howard Hinnant's civil-from-days; the inverse of days-from-civil.
fn civil_from_days(days: i64) CivilDate {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divTrunc(
        day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36524) - @divTrunc(day_of_era, 146096),
        365,
    );
    const year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    const month_prime = @divTrunc(5 * day_of_year + 2, 153);
    const month = if (month_prime < 10) month_prime + 3 else month_prime - 9;
    return .{
        .year = year + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day_of_year - @divTrunc(153 * month_prime + 2, 5) + 1),
    };
}

/// Set-Cookie attributes; `enforce_prefixes` enables the `__Host-`/`__Secure-`
/// requirements that browsers apply (RFC 6265bis).
pub const Options = struct {
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    http_only: bool = false,
    secure: bool = false,
    same_site: ?SameSite = null,
    /// Reject names whose `__Host-`/`__Secure-` prefix requirements are unmet.
    enforce_prefixes: bool = false,
    /// Absolute expiry as Unix seconds; emits `Expires` after `Max-Age`.
    expires_unix: ?i64 = null,
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

/// One raw cookie pair.
pub const Pair = struct { name: []const u8, value: []const u8 };

/// Iterator over the valid pairs of a single Cookie field.
pub const Iterator = struct {
    header: []const u8,
    offset: usize = 0,

    /// Advances to the next well-formed pair, skipping malformed ones.
    pub fn next(self: *Iterator) ?Pair {
        while (self.offset < self.header.len) {
            const rest = self.header[self.offset..];
            const separator = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            self.offset += separator + 1;
            const raw_pair = std.mem.trim(u8, rest[0..separator], " \t");
            const equals = std.mem.indexOfScalar(u8, raw_pair, '=') orelse continue;
            const name = std.mem.trim(u8, raw_pair[0..equals], " \t");
            const value = std.mem.trim(u8, raw_pair[equals + 1 ..], " \t");
            if (!valid_name(name) or !valid_value(value)) continue;
            return .{ .name = name, .value = value };
        }
        return null;
    }
};

/// Returns an iterator over `header`; malformed pairs are skipped.
pub fn iterator(header: []const u8) Iterator {
    return .{ .header = header };
}

/// Builds the fixed-capacity cookie view behind `CookieJarOf`.
fn cookie_jar_of(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        name_ptrs: [capacity][*]const u8 = undefined,
        name_lens: [capacity]usize = undefined,
        value_ptrs: [capacity][*]const u8 = undefined,
        value_lens: [capacity]usize = undefined,
        count: usize = 0,

        /// Forward iterator over pairs borrowed from one parsed view.
        pub const PairIterator = struct {
            jar: *const Self,
            index: usize = 0,

            /// Returns the next pair, or null when the view is exhausted.
            pub fn next(self: *PairIterator) ?Pair {
                const pair = self.jar.at(self.index) orelse return null;
                self.index += 1;
                return pair;
            }
        };

        /// Parses a raw Cookie field into borrowed name/value slices.
        ///
        /// Delimiters are located with a vectorized `=`/`;` scan over the
        /// caller's bytes; nothing is copied or allocated. Malformed pairs are
        /// skipped and pairs beyond `capacity` are ignored.
        pub fn parse(header: []const u8) Self {
            var result = Self{};
            var rest = header;

            while (rest.len != 0 and result.count < capacity) {
                const boundary = simd.index_of_either_byte(rest, '=', ';') orelse rest.len;
                if (boundary == rest.len) break;
                if (rest[boundary] == ';') {
                    rest = rest[boundary + 1 ..];
                    continue;
                }

                const name = std.mem.trim(u8, rest[0..boundary], " \t");
                const remainder = rest[boundary + 1 ..];
                const value_end = simd.index_of_byte(remainder, ';') orelse remainder.len;
                const value = std.mem.trim(u8, remainder[0..value_end], " \t");
                rest = if (value_end == remainder.len) "" else remainder[value_end + 1 ..];
                if (valid_name(name) and valid_value(value)) result.push(name, value);
            }
            return result;
        }

        /// Returns the pair at `index`, or null when out of range.
        pub fn at(self: *const Self, index: usize) ?Pair {
            // A zero-capacity view has no slots; returning before the index
            // keeps the empty-array instantiation compiling.
            if (comptime capacity == 0) return null;
            if (index >= self.count) return null;
            return .{
                .name = self.name_ptrs[index][0..self.name_lens[index]],
                .value = self.value_ptrs[index][0..self.value_lens[index]],
            };
        }

        /// Returns the first borrowed value whose name matches `name`.
        pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
            for (0..self.count) |index| {
                const pair = self.at(index).?;
                if (std.mem.eql(u8, pair.name, name)) return pair.value;
            }
            return null;
        }

        /// Reports whether any parsed pair has the exact `name`.
        pub fn has(self: *const Self, name: []const u8) bool {
            return self.get(name) != null;
        }

        /// Returns an iterator that borrows this view.
        pub fn pairs(self: *const Self) PairIterator {
            return .{ .jar = self };
        }

        fn push(self: *Self, name: []const u8, value: []const u8) void {
            // `parse` bounds count by capacity first, so only the zero-capacity
            // instantiation needs a guard to avoid indexing an empty array.
            if (comptime capacity == 0) return;
            self.name_ptrs[self.count] = name.ptr;
            self.name_lens[self.count] = name.len;
            self.value_ptrs[self.count] = value.ptr;
            self.value_lens[self.count] = value.len;
            self.count += 1;
        }
    };
}

/// Returns a cookie view type with `capacity` fixed pair slots.
///
/// The struct of arrays is stored inline and parsing never allocates; pairs
/// beyond `capacity` are ignored. Zero capacity is legal and yields an empty
/// view.
pub const CookieJarOf = cookie_jar_of;

/// Default pair capacity for `CookieJar`.
pub const max_cookies = 32;

/// Fixed-capacity view of the pairs in one Cookie field.
pub const CookieJar = CookieJarOf(max_cookies);

/// Formats one validated Set-Cookie response field into caller storage.
///
/// With `options.enforce_prefixes`, `__Host-` requires Secure, an explicit
/// `Path=/`, and no Domain; `__Secure-` requires Secure.
pub fn format(
    buffer: []u8,
    name: []const u8,
    value: []const u8,
    options: Options,
) ![]const u8 {
    if (!valid_name(name)) return error.InvalidCookieName;
    if (!valid_value(value)) return error.InvalidCookieValue;
    if (options.same_site == .none and !options.secure) return error.InsecureSameSiteNone;
    if (options.enforce_prefixes) try enforce_prefix(name, options);

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
    if (options.expires_unix) |expires| {
        var date_buffer: HttpDateBuffer = undefined;
        try writer.print("; Expires={s}", .{try format_http_date(&date_buffer, expires)});
    }
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

fn enforce_prefix(name: []const u8, options: Options) !void {
    if (std.mem.startsWith(u8, name, "__Host-")) {
        if (!options.secure) return error.InsecureCookiePrefix;
        if (options.domain != null) return error.InsecureCookiePrefix;
        const path = options.path orelse return error.InsecureCookiePrefix;
        if (!std.mem.eql(u8, path, "/")) return error.InsecureCookiePrefix;
        return;
    }
    if (std.mem.startsWith(u8, name, "__Secure-") and !options.secure) {
        return error.InsecureCookiePrefix;
    }
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

/// One rotation key: a public id and a >=32-byte secret.
pub const Key = struct { id: []const u8, secret: []const u8 };

/// Maximum accepted key-id length.
pub const max_key_id_length = 32;

/// Writes "id.payload.hex(HMAC-SHA256(id.payload, secret))" into caller storage.
pub fn sign_versioned(buffer: []u8, value: []const u8, key: Key) ![]const u8 {
    if (!valid_key_id(key.id)) return error.InvalidKeyId;
    if (key.secret.len < 32) return error.CookieSecretTooShort;
    if (!valid_value(value)) return error.InvalidCookieValue;

    const payload_start = key.id.len + 1;
    const signature_start = payload_start + value.len + 1;
    const total = signature_start + signature_length;
    if (buffer.len < total) return error.BufferTooSmall;

    @memcpy(buffer[0..key.id.len], key.id);
    buffer[key.id.len] = '.';
    @memcpy(buffer[payload_start..][0..value.len], value);
    buffer[payload_start + value.len] = '.';
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var hmac = HmacSha256.init(key.secret);
    hmac.update(key.id);
    hmac.update(".");
    hmac.update(value);
    hmac.final(&mac);
    encode_hex(buffer[signature_start..][0..signature_length], &mac);
    return buffer[0..total];
}

/// Verifies a versioned value against any rotation key and returns the payload.
pub fn verify_versioned(value: []const u8, keys: []const Key) ![]const u8 {
    const id_end = std.mem.indexOfScalar(u8, value, '.') orelse return error.InvalidCookieSignature;
    const signature_start = std.mem.lastIndexOfScalar(u8, value, '.') orelse return error.InvalidCookieSignature;
    if (signature_start == id_end) return error.InvalidCookieSignature;

    const id = value[0..id_end];
    const payload = value[id_end + 1 .. signature_start];
    const encoded = value[signature_start + 1 ..];

    for (keys) |key| {
        if (!std.mem.eql(u8, key.id, id)) continue;
        if (key.secret.len < 32) return error.CookieSecretTooShort;
        var supplied: [HmacSha256.mac_length]u8 = undefined;
        decode_hex(&supplied, encoded) catch return error.InvalidCookieSignature;
        var expected: [HmacSha256.mac_length]u8 = undefined;
        var hmac = HmacSha256.init(key.secret);
        hmac.update(id);
        hmac.update(".");
        hmac.update(payload);
        hmac.final(&expected);
        if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, supplied)) {
            return error.InvalidCookieSignature;
        }
        return payload;
    }
    return error.UnknownKeyId;
}

fn valid_key_id(id: []const u8) bool {
    if (id.len == 0 or id.len > max_key_id_length) return false;
    if (std.mem.indexOfScalar(u8, id, '.') != null) return false;
    return valid_name(id);
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
