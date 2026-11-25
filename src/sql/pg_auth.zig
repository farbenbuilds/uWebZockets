//! Bounded PostgreSQL MD5 and SCRAM-SHA-256 authentication without I/O or allocation.
const std = @import("std");
const SqlError = @import("types.zig").SqlError;
const saslprep = @import("saslprep.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Server iteration counts are bounded to prevent peer-controlled CPU exhaustion.
pub const max_scram_iterations = 1000000;
/// PostgreSQL's default SCRAM work factor is the minimum accepted by this client.
pub const min_scram_iterations = 4096;

/// Emits `md5` plus 32 lowercase hex bytes and a terminating NUL.
pub fn md5_password(output: *[36]u8, password_bytes: []const u8, user: []const u8, salt: [4]u8) void {
    var inner: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &inner);
    var inner_hex: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &inner_hex);
    var outer: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &outer);
    var hash = std.crypto.hash.Md5.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    hash.update(password_bytes);
    hash.update(user);
    hash.final(&inner);
    encode_hex(&inner_hex, &inner);
    std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    hash = std.crypto.hash.Md5.init(.{});
    hash.update(&inner_hex);
    hash.update(&salt);
    hash.final(&outer);
    @memcpy(output[0..3], "md5");
    encode_hex(output[3..35], &outer);
    output[35] = 0;
}

fn encode_hex(output: []u8, input: []const u8) void {
    const digits = "0123456789abcdef";
    for (input, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 15];
    }
}

/// One authentication exchange; initialize at startup with a caller-generated nonce.
pub const Scram = struct {
    client_bare: [1024]u8 = undefined,
    client_bare_len: usize = 0,
    nonce: [128]u8 = undefined,
    nonce_len: usize = 0,
    server_signature: [32]u8 = undefined,
    responded: bool = false,
    verified: bool = false,

    /// Nonce bytes must be unpredictable printable ASCII, excluding commas.
    pub fn init(user: []const u8, nonce: []const u8) SqlError!Scram {
        if (nonce.len == 0 or nonce.len > 128) return error.AuthenticationFailed;
        for (nonce) |byte| {
            if (byte < 0x21 or byte > 0x7e or byte == ',') return error.AuthenticationFailed;
        }
        if (user.len > 256 or !std.unicode.utf8ValidateSlice(user)) return error.AuthenticationFailed;
        var state = Scram{};
        @memcpy(state.nonce[0..nonce.len], nonce);
        state.nonce_len = nonce.len;
        var offset: usize = 0;
        try append(&state.client_bare, &offset, "n=");
        for (user) |byte| {
            switch (byte) {
                '=' => try append(&state.client_bare, &offset, "=3D"),
                ',' => try append(&state.client_bare, &offset, "=2C"),
                0 => return error.AuthenticationFailed,
                else => try append(&state.client_bare, &offset, &.{byte}),
            }
        }
        try append(&state.client_bare, &offset, ",r=");
        try append(&state.client_bare, &offset, nonce);
        state.client_bare_len = offset;
        return state;
    }

    /// Produces the GS2 header and escaped client-first message.
    pub fn client_first(self: *const Scram, output: []u8) SqlError![]const u8 {
        if (self.responded) return error.AuthenticationFailed;
        var offset: usize = 0;
        try append(output, &offset, "n,,");
        try append(output, &offset, self.client_bare[0..self.client_bare_len]);
        return output[0..offset];
    }

    /// Applies SASLprep and PostgreSQL's specified raw-byte fallback on invalid Unicode.
    pub fn respond(self: *Scram, password_bytes: []const u8, server_first: []const u8, output: []u8) SqlError![]const u8 {
        if (password_bytes.len > 1024) return error.AuthenticationFailed;
        var prepared: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &prepared);
        var scratch: [4096]u21 = undefined;
        defer std.crypto.secureZero(u21, &scratch);
        const password = saslprep.prepare_postgres(password_bytes, &prepared, &scratch) catch |err| switch (err) {
            // PostgreSQL applies the original bytes when SASLprep rejects their contents.
            error.InvalidValue => password_bytes,
            else => return err,
        };
        return self.respond_prepared(password, server_first, output);
    }

    /// Caller must apply RFC4013 SASLprep to non-ASCII passwords before this entry point.
    pub fn respond_prepared(self: *Scram, prepared_password: []const u8, server_first: []const u8, output: []u8) SqlError![]const u8 {
        if (self.responded or server_first.len > 1024 or prepared_password.len > 4096) return error.AuthenticationFailed;
        const challenge = try parse_challenge(server_first);
        const nonce = self.nonce[0..self.nonce_len];
        if (challenge.nonce.len <= nonce.len or !std.mem.startsWith(u8, challenge.nonce, nonce)) return error.AuthenticationFailed;
        var salt: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &salt);
        const salt_len = std.base64.standard.Decoder.calcSizeForSlice(challenge.salt) catch return error.AuthenticationFailed;
        if (salt_len == 0 or salt_len > salt.len) return error.AuthenticationFailed;
        std.base64.standard.Decoder.decode(salt[0..salt_len], challenge.salt) catch return error.AuthenticationFailed;
        var final_bare: [1200]u8 = undefined;
        var final_len: usize = 0;
        try append(&final_bare, &final_len, "c=biws,r=");
        try append(&final_bare, &final_len, challenge.nonce);
        var auth_message: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_message);
        var auth_len: usize = 0;
        try append(&auth_message, &auth_len, self.client_bare[0..self.client_bare_len]);
        try append(&auth_message, &auth_len, ",");
        try append(&auth_message, &auth_len, server_first);
        try append(&auth_message, &auth_len, ",");
        try append(&auth_message, &auth_len, final_bare[0..final_len]);
        const auth_bytes = auth_message[0..auth_len];
        var secrets: Secrets = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&secrets));
        salted_password(&secrets.salted, prepared_password, salt[0..salt_len], challenge.iterations);
        hmac(&secrets.client_key, "Client Key", &secrets.salted);
        sha256(&secrets.stored_key, &secrets.client_key);
        hmac(&secrets.client_signature, auth_bytes, &secrets.stored_key);
        for (secrets.client_key, secrets.client_signature, 0..) |key, signature, index| secrets.proof[index] = key ^ signature;
        hmac(&secrets.server_key, "Server Key", &secrets.salted);
        hmac(&secrets.server_signature, auth_bytes, &secrets.server_key);
        var proof_base64: [44]u8 = undefined;
        defer std.crypto.secureZero(u8, &proof_base64);
        _ = std.base64.standard.Encoder.encode(&proof_base64, &secrets.proof);
        var offset: usize = 0;
        try append(output, &offset, final_bare[0..final_len]);
        try append(output, &offset, ",p=");
        try append(output, &offset, &proof_base64);
        self.server_signature = secrets.server_signature;
        self.responded = true;
        return output[0..offset];
    }

    /// Server proof must match before AuthenticationOk is accepted by the transport.
    pub fn verify(self: *Scram, server_final: []const u8) SqlError!void {
        if (!self.responded or self.verified or server_final.len > 1024) return error.AuthenticationFailed;
        var attributes = std.mem.splitScalar(u8, server_final, ',');
        const verifier = try parse_attribute(attributes.next() orelse return error.AuthenticationFailed);
        if (verifier.name == 'm') return error.UnsupportedAuthentication;
        if (verifier.name != 'v' or verifier.value.len != 44) return error.AuthenticationFailed;
        while (attributes.next()) |attribute| try validate_extension(try parse_attribute(attribute));
        const encoded = verifier.value;
        var signature: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &signature);
        const length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.AuthenticationFailed;
        if (length != signature.len) return error.AuthenticationFailed;
        std.base64.standard.Decoder.decode(&signature, encoded) catch return error.AuthenticationFailed;
        if (!std.crypto.timing_safe.eql([32]u8, self.server_signature, signature)) return error.AuthenticationFailed;
        self.verified = true;
        std.crypto.secureZero(u8, &self.server_signature);
    }

    /// Erases authentication-derived material when the connection is closed or reused.
    pub fn deinit(self: *Scram) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

/// All temporary key material is erased together on success and failure.
const Secrets = struct {
    salted: [32]u8,
    client_key: [32]u8,
    stored_key: [32]u8,
    client_signature: [32]u8,
    proof: [32]u8,
    server_key: [32]u8,
    server_signature: [32]u8,
};

/// Borrowed, validated SCRAM challenge components.
const Challenge = struct { nonce: []const u8, salt: []const u8, iterations: u32 };

fn parse_challenge(input: []const u8) SqlError!Challenge {
    var nonce: ?[]const u8 = null;
    var salt: ?[]const u8 = null;
    var iterations: ?u32 = null;
    var position: u2 = 0;
    var attributes = std.mem.splitScalar(u8, input, ',');
    while (attributes.next()) |encoded| {
        const attribute = try parse_attribute(encoded);
        switch (attribute.name) {
            'r' => {
                if (position != 0) return error.AuthenticationFailed;
                nonce = attribute.value;
                position = 1;
            },
            's' => {
                if (position != 1) return error.AuthenticationFailed;
                salt = attribute.value;
                position = 2;
            },
            'i' => {
                if (position != 2) return error.AuthenticationFailed;
                iterations = try parse_iterations(attribute.value);
                position = 3;
            },
            // The mandatory-extension marker cannot be ignored by this implementation.
            'm' => return error.UnsupportedAuthentication,
            else => {
                if (position != 3) return error.AuthenticationFailed;
                try validate_extension(attribute);
            },
        }
    }
    const rounds = iterations orelse return error.AuthenticationFailed;
    if (rounds < min_scram_iterations or rounds > max_scram_iterations) return error.AuthenticationFailed;
    const server_nonce = nonce orelse return error.AuthenticationFailed;
    for (server_nonce) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.AuthenticationFailed;
    }
    return .{ .nonce = server_nonce, .salt = salt orelse return error.AuthenticationFailed, .iterations = rounds };
}

/// A SCRAM attribute has a single ASCII letter and a nonempty UTF8 value.
const Attribute = struct { name: u8, value: []const u8 };

fn parse_attribute(encoded: []const u8) SqlError!Attribute {
    if (encoded.len < 3 or encoded[1] != '=') return error.AuthenticationFailed;
    const name = encoded[0];
    if (!std.ascii.isAlphabetic(name)) return error.AuthenticationFailed;
    const value = encoded[2..];
    if (std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.AuthenticationFailed;
    return .{ .name = name, .value = value };
}

fn validate_extension(attribute: Attribute) SqlError!void {
    switch (attribute.name) {
        'm' => return error.UnsupportedAuthentication,
        // Assigned attributes cannot be reinterpreted as optional extensions.
        'a', 'n', 'c', 'p', 'r', 's', 'i', 'v', 'e' => return error.AuthenticationFailed,
        else => {},
    }
}

fn append(output: []u8, offset: *usize, bytes: []const u8) SqlError!void {
    if (bytes.len > output.len - offset.*) return error.BufferTooSmall;
    @memcpy(output[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn parse_iterations(input: []const u8) SqlError!u32 {
    for (input) |byte| {
        if (byte < '0' or byte > '9') return error.AuthenticationFailed;
    }
    return std.fmt.parseInt(u32, input, 10) catch return error.AuthenticationFailed;
}

/// Owns key-derived hash states so every temporary secret can be explicitly erased.
const HmacState = struct {
    inner: Sha256,
    outer: Sha256,

    fn init(self: *HmacState, key: []const u8) void {
        var block: [64]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &block);
        if (key.len > block.len) {
            sha256(block[0..32], key);
        } else {
            @memcpy(block[0..key.len], key);
        }
        for (&block) |*byte| byte.* ^= 0x36;
        self.inner = Sha256.init(.{});
        self.inner.update(&block);
        for (&block) |*byte| byte.* ^= 0x36 ^ 0x5c;
        self.outer = Sha256.init(.{});
        self.outer.update(&block);
    }

    fn calculate(self: *const HmacState, output: *[32]u8, message: []const u8) void {
        var inner = self.inner;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&inner));
        var outer = self.outer;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&outer));
        var digest: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        inner.update(message);
        inner.final(&digest);
        outer.update(&digest);
        outer.final(output);
    }
};

fn sha256(output: *[32]u8, input: []const u8) void {
    var hash = Sha256.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    hash.update(input);
    hash.final(output);
}

fn hmac(output: *[32]u8, message: []const u8, key: []const u8) void {
    var state: HmacState = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&state));
    state.init(key);
    state.calculate(output, message);
}

// SCRAM derives exactly one SHA256 block, rather than a generic variable-length key.
fn salted_password(output: *[32]u8, password: []const u8, salt: []const u8, iterations: u32) void {
    var state: HmacState = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&state));
    state.init(password);
    var initial: [260]u8 = undefined;
    defer std.crypto.secureZero(u8, &initial);
    @memcpy(initial[0..salt.len], salt);
    std.mem.writeInt(u32, initial[salt.len..][0..4], 1, .big);
    var previous: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &previous);
    var next: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &next);
    state.calculate(&previous, initial[0 .. salt.len + 4]);
    output.* = previous;
    for (1..iterations) |_| {
        state.calculate(&next, &previous);
        for (output, next) |*byte, value| byte.* ^= value;
        previous = next;
    }
}
