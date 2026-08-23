pub const c = @cImport({
    // Standard system headers often required by networking libraries (like lsquic)
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("stddef.h");
    @cInclude("stdint.h");

    // BoringSSL
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/crypto.h");

    // lsquic
    @cInclude("lsquic.h");

    // libdeflate
    @cInclude("libdeflate.h");
});
