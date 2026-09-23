const c = @import("c");

pub const sha256_length = 32;
pub const aes_gcm_tag_length = 16;
pub const aes_gcm_nonce_length = 12;

/// Failure modes shared by AES-GCM seal, open, and algorithm selection.
pub const AesGcmError = error{
    AuthenticationFailed,
    BufferTooSmall,
    ContextCreationFailed,
    InvalidKeyLength,
    InvalidNonceLength,
};

/// Hardware-accelerated SHA-256 through BoringSSL.
pub fn digest_sha256(input: []const u8) [sha256_length]u8 {
    var digest: [sha256_length]u8 = undefined;
    const data = if (input.len == 0) empty_ptr() else input.ptr;
    _ = c.SHA256(data, input.len, &digest);
    return digest;
}

/// Hardware-accelerated HMAC-SHA-256 through BoringSSL.
pub fn sign_hmac_sha256(key: []const u8, input: []const u8) [sha256_length]u8 {
    var digest: [sha256_length]u8 = undefined;
    var digest_length: c_uint = 0;
    const key_ptr = if (key.len == 0) empty_ptr() else key.ptr;
    const input_ptr = if (input.len == 0) empty_ptr() else input.ptr;
    _ = c.HMAC(
        c.EVP_sha256(),
        key_ptr,
        key.len,
        input_ptr,
        input.len,
        &digest,
        &digest_length,
    );
    return digest;
}

/// Verifies MAC bytes with BoringSSL's constant-time comparison.
pub fn verify_hmac_sha256(
    key: []const u8,
    input: []const u8,
    expected: *const [sha256_length]u8,
) bool {
    const actual = sign_hmac_sha256(key, input);
    return c.CRYPTO_memcmp(&actual, expected, actual.len) == 0;
}

/// AES-GCM seal. The returned bytes are ciphertext followed by the tag.
pub fn encrypt_aes_gcm(
    key: []const u8,
    nonce: []const u8,
    plaintext: []const u8,
    additional_data: []const u8,
    output: []u8,
) AesGcmError![]u8 {
    if (nonce.len != aes_gcm_nonce_length) return error.InvalidNonceLength;
    if (output.len < plaintext.len or output.len - plaintext.len < aes_gcm_tag_length) {
        return error.BufferTooSmall;
    }
    const algorithm = try aes_gcm_algorithm(key.len);
    const context = c.EVP_AEAD_CTX_new(
        algorithm,
        key.ptr,
        key.len,
        c.EVP_AEAD_DEFAULT_TAG_LENGTH,
    ) orelse return error.ContextCreationFailed;
    defer c.EVP_AEAD_CTX_free(context);

    var output_length: usize = 0;
    const ad_ptr = if (additional_data.len == 0) empty_ptr() else additional_data.ptr;
    const input_ptr = if (plaintext.len == 0) empty_ptr() else plaintext.ptr;
    if (c.EVP_AEAD_CTX_seal(
        context,
        output.ptr,
        &output_length,
        output.len,
        nonce.ptr,
        nonce.len,
        input_ptr,
        plaintext.len,
        ad_ptr,
        additional_data.len,
    ) != 1) return error.BufferTooSmall;
    return output[0..output_length];
}

/// AES-GCM open. Authentication failure never exposes partial plaintext.
pub fn decrypt_aes_gcm(
    key: []const u8,
    nonce: []const u8,
    ciphertext_and_tag: []const u8,
    additional_data: []const u8,
    output: []u8,
) AesGcmError![]u8 {
    if (nonce.len != aes_gcm_nonce_length) return error.InvalidNonceLength;
    if (ciphertext_and_tag.len < aes_gcm_tag_length) return error.AuthenticationFailed;
    if (output.len < ciphertext_and_tag.len - aes_gcm_tag_length) return error.BufferTooSmall;
    const algorithm = try aes_gcm_algorithm(key.len);
    const context = c.EVP_AEAD_CTX_new(
        algorithm,
        key.ptr,
        key.len,
        c.EVP_AEAD_DEFAULT_TAG_LENGTH,
    ) orelse return error.ContextCreationFailed;
    defer c.EVP_AEAD_CTX_free(context);

    var output_length: usize = 0;
    const ad_ptr = if (additional_data.len == 0) empty_ptr() else additional_data.ptr;
    if (c.EVP_AEAD_CTX_open(
        context,
        output.ptr,
        &output_length,
        output.len,
        nonce.ptr,
        nonce.len,
        ciphertext_and_tag.ptr,
        ciphertext_and_tag.len,
        ad_ptr,
        additional_data.len,
    ) != 1) return error.AuthenticationFailed;
    return output[0..output_length];
}

fn aes_gcm_algorithm(key_length: usize) AesGcmError!*const c.EVP_AEAD {
    return switch (key_length) {
        16 => c.EVP_aead_aes_128_gcm() orelse error.ContextCreationFailed,
        32 => c.EVP_aead_aes_256_gcm() orelse error.ContextCreationFailed,
        else => error.InvalidKeyLength,
    };
}

fn empty_ptr() [*]const u8 {
    return "".ptr;
}
