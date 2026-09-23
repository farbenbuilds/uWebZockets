const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;
const ipproto_tcp = 6;
const tcp_ulp = 31;
const sol_tls = 282;
const tls_tx = 1;
const tls_rx = 2;
const tls_1_2_version = 0x0303;
const tls_cipher_aes_gcm_128 = 51;

/// Record direction a kTLS socket option applies to.
pub const Direction = enum(u8) {
    transmit,
    receive,
};

/// Linux `tls12_crypto_info_aes_gcm_128` record state.
pub const AesGcm128 = extern struct {
    version: u16 = tls_1_2_version,
    cipher_type: u16 = tls_cipher_aes_gcm_128,
    iv: [8]u8,
    key: [16]u8,
    salt: [4]u8,
    record_sequence: [8]u8,
};

pub const Error = error{
    InvalidFileDescriptor,
    KernelTlsUnavailable,
    PermissionDenied,
    SyscallFailed,
    WouldBlock,
};

/// Enables the Linux TLS upper-layer protocol on an established TCP socket.
pub fn enable(fd: i32) Error!void {
    require_linux();
    const ulp = "tls";
    const result = linux.setsockopt(
        fd,
        ipproto_tcp,
        tcp_ulp,
        ulp.ptr,
        ulp.len,
    );
    switch (linux.errno(result)) {
        .SUCCESS, .EXIST => {},
        .BADF => return error.InvalidFileDescriptor,
        .PERM, .ACCES => return error.PermissionDenied,
        .NOPROTOOPT, .PROTONOSUPPORT => return error.KernelTlsUnavailable,
        else => return error.SyscallFailed,
    }
}

/// Installs Linux kTLS AES-128-GCM record state on an enabled socket.
pub fn configure_aes_gcm_128(fd: i32, direction: Direction, crypto: AesGcm128) Error!void {
    require_linux();
    var local_crypto = crypto;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&local_crypto));
    try check_setsockopt(linux.setsockopt(
        fd,
        sol_tls,
        switch (direction) {
            .transmit => tls_tx,
            .receive => tls_rx,
        },
        std.mem.asBytes(&local_crypto).ptr,
        @sizeOf(AesGcm128),
    ));
}

/// Enables kTLS and installs one AES-128-GCM record direction.
pub fn enable_aes_gcm_128(fd: i32, direction: Direction, crypto: AesGcm128) Error!void {
    try enable(fd);
    try configure_aes_gcm_128(fd, direction, crypto);
}

/// Transfers file bytes to a kTLS socket without userspace payload copies.
pub fn sendfile_once(socket_fd: i32, file_fd: i32, offset: *i64, length: usize) Error!usize {
    require_linux();
    const result = linux.sendfile(socket_fd, file_fd, offset, length);
    return syscall_count(result);
}

/// Splices pipe bytes to a kTLS socket without userspace payload copies.
pub fn splice_once(
    input_fd: i32,
    input_offset: ?*i64,
    socket_fd: i32,
    output_offset: ?*i64,
    length: usize,
    flags: u32,
) Error!usize {
    require_linux();
    const result = linux.syscall6(
        .splice,
        @bitCast(@as(isize, input_fd)),
        @intFromPtr(input_offset),
        @bitCast(@as(isize, socket_fd)),
        @intFromPtr(output_offset),
        length,
        flags,
    );
    return syscall_count(result);
}

fn check_setsockopt(result: usize) Error!void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .BADF => error.InvalidFileDescriptor,
        .PERM, .ACCES => error.PermissionDenied,
        .NOPROTOOPT, .PROTONOSUPPORT => error.KernelTlsUnavailable,
        else => error.SyscallFailed,
    };
}

fn syscall_count(result: usize) Error!usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .AGAIN => error.WouldBlock,
        .BADF => error.InvalidFileDescriptor,
        .PERM, .ACCES => error.PermissionDenied,
        else => error.SyscallFailed,
    };
}

inline fn require_linux() void {
    if (builtin.os.tag != .linux) @compileError("kTLS is available only on Linux");
}
