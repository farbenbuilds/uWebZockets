const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

/// Reports whether the kernel can stream a regular file directly to a socket
/// on this platform.
///
/// Windows is deliberately excluded: libxev owns the IOCP completion port, so
/// an overlapped `TransmitFile` cannot be observed by the event loop and the
/// transport takes the bounded buffered path instead of blocking a worker.
pub const kernel_send_supported = switch (builtin.os.tag) {
    .linux, .macos, .ios => true,
    else => false,
};

/// Upper bound for one kernel `sendfile` call.
pub const max_chunk: usize = 1 << 20;

pub const SendFileError = error{
    WouldBlock,
    InvalidFileDescriptor,
    SyscallFailed,
};

/// Streams up to `length` regular-file bytes to a socket at the kernel boundary.
///
/// `offset` is read and advanced in place. Returns the accepted byte count;
/// `error.WouldBlock` means a nonblocking socket cannot take more right now.
/// The caller must hold a nonblocking window open for the socket: a blocking
/// `sendfile` sleeps until the full count is transferred.
pub fn send_file_chunk(
    socket_fd: posix.fd_t,
    file_fd: posix.fd_t,
    offset: *u64,
    length: usize,
) SendFileError!usize {
    return switch (comptime builtin.os.tag) {
        .linux => send_file_linux(socket_fd, file_fd, offset, length),
        .macos, .ios => send_file_darwin(socket_fd, file_fd, offset, length),
        else => error.SyscallFailed,
    };
}

fn send_file_linux(
    socket_fd: posix.fd_t,
    file_fd: posix.fd_t,
    offset: *u64,
    length: usize,
) SendFileError!usize {
    var kernel_offset: i64 = @intCast(offset.*);
    const result = linux.sendfile(socket_fd, file_fd, &kernel_offset, length);
    switch (linux.errno(result)) {
        .SUCCESS => {
            offset.* = @intCast(kernel_offset);
            return result;
        },
        // Signals and full send buffers both defer to the bounded dribble path.
        .AGAIN, .INTR => return error.WouldBlock,
        .BADF => return error.InvalidFileDescriptor,
        else => return error.SyscallFailed,
    }
}

const DarwinSendfile = *const fn (
    c_int,
    c_int,
    std.c.off_t,
    *std.c.off_t,
    ?*std.c.sf_hdtr,
    c_int,
) callconv(.c) c_int;

fn send_file_darwin(
    socket_fd: posix.fd_t,
    file_fd: posix.fd_t,
    offset: *u64,
    length: usize,
) SendFileError!usize {
    const darwin_sendfile = @extern(DarwinSendfile, .{ .name = "sendfile" });
    var transferred: std.c.off_t = @intCast(@min(length, std.math.maxInt(std.c.off_t)));
    const result = darwin_sendfile(
        @intCast(file_fd),
        @intCast(socket_fd),
        @intCast(offset.*),
        &transferred,
        null,
        0,
    );
    // Darwin reports bytes sent before EAGAIN or EINTR in `transferred`.
    if (result == 0 or transferred != 0) {
        offset.* += @intCast(transferred);
        return @intCast(transferred);
    }
    return switch (std.c._errno().*) {
        @intFromEnum(std.c.E.AGAIN), @intFromEnum(std.c.E.INTR) => error.WouldBlock,
        @intFromEnum(std.c.E.BADF) => error.InvalidFileDescriptor,
        else => error.SyscallFailed,
    };
}

/// State of a temporary nonblocking window over a possibly blocking socket.
pub const NonblockingWindow = enum {
    already,
    enabled,
    failed,
};

/// Opens a nonblocking window so `sendfile` reports `EAGAIN` instead of
/// sleeping.
///
/// No libxev completion may be submitted while the window is open: the io_uring
/// backend creates blocking sockets and surfaces `EAGAIN` as an error. Callers
/// must close the window before queueing any socket operation.
pub fn open_nonblocking_window(fd: posix.fd_t) NonblockingWindow {
    if (is_nonblocking(fd)) return .already;
    if (set_nonblocking(fd, true)) return .enabled;
    return .failed;
}

/// Restores the socket's original flag state after a kernel transfer window.
pub fn close_nonblocking_window(window: NonblockingWindow, fd: posix.fd_t) void {
    if (window != .enabled) return;
    _ = set_nonblocking(fd, false);
}

pub fn is_nonblocking(fd: posix.fd_t) bool {
    switch (comptime builtin.os.tag) {
        .linux, .macos, .ios => {
            const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            if (flags < 0) return false;
            const status: std.c.O = @bitCast(@as(c_uint, @intCast(flags)));
            return status.NONBLOCK;
        },
        else => return false,
    }
}

fn set_nonblocking(fd: posix.fd_t, enabled: bool) bool {
    switch (comptime builtin.os.tag) {
        .linux, .macos, .ios => {
            const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            if (flags < 0) return false;
            var status: std.c.O = @bitCast(@as(c_uint, @intCast(flags)));
            status.NONBLOCK = enabled;
            const raw: c_int = @bitCast(@as(c_uint, @bitCast(status)));
            return std.c.fcntl(fd, std.c.F.SETFL, raw) == 0;
        },
        else => return false,
    }
}
