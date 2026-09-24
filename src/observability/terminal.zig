//! Best-effort terminal-width probing for the development log.
//!
//! This is the module's only platform-dependent surface: POSIX queries the
//! window size with `ioctl(TIOCGWINSZ)` and Windows issues the console
//! `GetScreenBufferInfo` request directly. Every failure path returns null so
//! the startup wordmark can fall back to a narrower mark.

const std = @import("std");
const builtin = @import("builtin");

/// Returns the column count of `file` when it is a terminal.
///
/// Null when the output is redirected, the query fails, or the platform has no
/// supported console query. Never allocates and never panics; the raw syscalls
/// are used instead of the `std.Io` vtable so a sink bound to a minimal `Io`
/// stays safe.
pub fn columns(file: std.Io.File) ?usize {
    return switch (builtin.os.tag) {
        .windows => columns_windows(file),
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => columns_posix(file.handle),
        else => null,
    };
}

fn columns_posix(fd: std.posix.fd_t) ?usize {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (builtin.link_libc) {
        _ = std.c.ioctl(fd, @intCast(std.posix.T.IOCGWINSZ), @intFromPtr(&size));
    } else if (builtin.os.tag == .linux) {
        _ = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    } else {
        // Non-Linux targets without libc have no ioctl binding.
        return null;
    }
    return if (size.col == 0) null else size.col;
}

fn columns_windows(file: std.Io.File) ?usize {
    // An asynchronous console handle completes through an APC; a synchronous
    // request can return while the kernel still writes the result.
    if (file.flags.nonblocking) return null;
    const windows = std.os.windows;
    var info = windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
    const request = &info.request(file, 0, .{}, 0, .{});
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtDeviceIoControlFile(
        windows.peb().ProcessParameters.ConsoleHandle,
        null,
        null,
        null,
        &status_block,
        windows.IOCTL.CONDRV.ISSUE_USER_IO,
        @ptrCast(request),
        @intCast(@sizeOf(@TypeOf(request.*))),
        null,
        0,
    );
    if (status != .SUCCESS) return null;
    const width = info.Data.dwWindowSize.X;
    return if (width <= 0) null else @intCast(width);
}
