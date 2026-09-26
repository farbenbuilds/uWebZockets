//! Graceful-shutdown signal capture.
//!
//! Both backends keep OS handlers free of application work and hand the wakeup
//! to the owning event loop:
//!
//! - POSIX installs SIGINT and SIGTERM handlers that write one byte into a
//!   non-blocking self-pipe. A libxev file poll on the read end wakes the loop,
//!   drains the pipe, and coalesces any number of pending signals into a single
//!   callback.
//! - Windows installs a console control handler that sets a process flag and
//!   wakes a libxev async; the loop thread then invokes the same callback.
//!
//! One watcher per process: signal dispositions and the self-pipe write end are
//! process-wide, so `init` fails with `error.SignalWatcherAlreadyInstalled`
//! until `deinit` restores them.
//!
//! `stop` never cancels the armed completion. It writes one token through the
//! same arm the handler uses (the self-pipe, or the async notify), and the
//! callback sees `stopping` and disarms, which keeps cancellation off the
//! libxev poll path where io_uring does not map it.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const core_loop = @import("loop.zig");

const Loop = core_loop.Loop;
const windows = std.os.windows;

const log = std.log.scoped(.signal);

/// Invoked on the event-loop thread once per coalesced shutdown request.
pub const Callback = *const fn (context: *anyopaque) void;

/// Reports whether a caught POSIX signal requests graceful shutdown.
pub fn is_shutdown_signal(signal_number: std.posix.SIG) bool {
    return switch (signal_number) {
        .INT, .TERM => true,
        else => false,
    };
}

/// Reduces a drained self-pipe payload to one shutdown request per wakeup.
///
/// The byte count is intentionally discarded: graceful shutdown is
/// idempotent, so signals that arrive before the loop drains coalesce.
pub fn coalesce(drained_bytes: usize) bool {
    return drained_bytes != 0;
}

/// Platform watcher selected at compile time.
pub const SignalWatcher = if (builtin.os.tag == .windows) WindowsWatcher else PosixWatcher;

/// Byte written by the signal handler and by `stop`; the read side only cares
/// that at least one byte arrived.
const wakeup_token: u8 = 0x01;

/// Signal handlers cannot capture context, so the write end of the
/// process-wide self-pipe is the documented OS-singleton exception to the
/// file-scope `var` rule (CODING_CONVENTION 7.1). It is accessed atomically:
/// the handler loads it once and writes one byte, and it is -1 while no
/// watcher is installed.
var posix_pipe_write_fd: std.atomic.Value(std.posix.fd_t) = .init(-1);

/// Closes a private pipe descriptor during teardown.
///
/// The descriptor is owned by this watcher and cannot be retried usefully, so
/// the raw syscall result is intentionally discarded.
fn close_posix_fd(fd: std.posix.fd_t) void {
    if (fd < 0) return;
    _ = std.posix.system.close(fd);
}

/// Writes one wake token; best effort by design.
///
/// The pipe is non-blocking, so a full pipe already holds a wake token and
/// EAGAIN is safe to ignore.
fn write_wake_token(fd: std.posix.fd_t) void {
    if (fd < 0) return;
    const byte = [1]u8{wakeup_token};
    _ = std.posix.system.write(fd, &byte, byte.len);
}

/// POSIX handler writing the coalescing wakeup token into the self-pipe.
///
/// `write` is async-signal-safe and the handler performs no allocation, lock,
/// logging, or clock access.
fn handle_posix_signal(signal_number: std.posix.SIG) callconv(.c) void {
    if (!is_shutdown_signal(signal_number)) return;
    write_wake_token(posix_pipe_write_fd.load(.acquire));
}

/// POSIX watcher driven by a non-blocking self-pipe and a libxev file poll.
///
/// The poll drains the pipe and invokes the callback once per readable event,
/// so two signals delivered before the loop wakes still request one shutdown.
/// Repeated signals while shutdown is in flight are coalesced the same way.
pub const PosixWatcher = struct {
    const Self = @This();

    loop: *Loop,
    callback: Callback,
    context: *anyopaque,
    read_fd: std.posix.fd_t = -1,
    write_fd: std.posix.fd_t = -1,
    file: xev.File = undefined,
    completion: xev.Completion = .{},
    previous_interrupt: std.posix.Sigaction = undefined,
    previous_terminate: std.posix.Sigaction = undefined,
    installed: bool = false,
    started: bool = false,
    stopping: bool = false,
    active: bool = false,

    /// Creates the self-pipe and replaces the SIGINT and SIGTERM dispositions.
    ///
    /// Signals received before `start` only fill the pipe, so no request is
    /// lost. Returns `error.SignalWatcherAlreadyInstalled` while another
    /// watcher owns the process-wide handler state.
    pub fn init(loop: *Loop, callback: Callback, context: *anyopaque) !Self {
        // Claim the process-wide slot before creating the pipe so two
        // concurrent installs cannot both replace the dispositions. The zero
        // placeholder is never observed by the handler: dispositions change
        // only after the real write end is stored.
        if (posix_pipe_write_fd.cmpxchgStrong(-1, 0, .acq_rel, .acquire) != null) {
            return error.SignalWatcherAlreadyInstalled;
        }
        errdefer posix_pipe_write_fd.store(-1, .release);

        const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer {
            close_posix_fd(fds[0]);
            close_posix_fd(fds[1]);
        }
        var action = std.posix.Sigaction{
            .handler = .{ .handler = handle_posix_signal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous_interrupt: std.posix.Sigaction = undefined;
        var previous_terminate: std.posix.Sigaction = undefined;

        // The write end becomes visible to the handler before the first
        // disposition changes, so an early signal can never observe a closed
        // descriptor.
        posix_pipe_write_fd.store(fds[1], .release);
        std.posix.sigaction(std.posix.SIG.INT, &action, &previous_interrupt);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &previous_terminate);

        return .{
            .loop = loop,
            .callback = callback,
            .context = context,
            .read_fd = fds[0],
            .write_fd = fds[1],
            .previous_interrupt = previous_interrupt,
            .previous_terminate = previous_terminate,
            .installed = true,
        };
    }

    /// Arms the loop poll on the self-pipe; idempotent and non-blocking.
    pub fn start(self: *Self) void {
        if (self.started or !self.installed) return;
        self.started = true;
        self.active = true;
        self.file = xev.File.initFd(self.read_fd);
        self.file.poll(
            self.loop.get_xev_loop(),
            &self.completion,
            .read,
            Self,
            self,
            on_readable,
        );
    }

    /// Wakes and disarms an armed poll; idempotent and non-blocking.
    pub fn stop(self: *Self) void {
        if (!self.started or self.stopping) return;
        self.stopping = true;
        if (!self.active) return;
        write_wake_token(self.write_fd);
    }

    /// Reports whether no completion can still reference this watcher.
    pub fn is_drained(self: *const Self) bool {
        if (!self.started) return true;
        return !self.active;
    }

    /// Restores the previous dispositions and closes the pipe.
    ///
    /// Callers must first `stop`, drive the loop, and observe `is_drained`.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.is_drained());
        self.release();
    }

    /// Releases without requiring a drained poll.
    ///
    /// Only valid when the owning loop will never run again, such as a cluster
    /// worker whose thread has already exited; the loop must be deinitialized
    /// afterwards without executing completions.
    pub fn deinit_undrained(self: *Self) void {
        self.release();
    }

    fn release(self: *Self) void {
        if (!self.installed) {
            self.* = undefined;
            return;
        }
        // Restore the dispositions before dropping the write end so a signal
        // arriving mid-teardown still has a valid destination.
        std.posix.sigaction(std.posix.SIG.INT, &self.previous_interrupt, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.previous_terminate, null);
        posix_pipe_write_fd.store(-1, .release);
        close_posix_fd(self.read_fd);
        close_posix_fd(self.write_fd);
        self.* = undefined;
    }

    fn on_readable(
        user_data: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.active = false;
        _ = result catch |err| {
            if (self.stopping or err == error.Canceled) return .disarm;
            // A broken watch would silently drop every later shutdown signal,
            // so fail closed: log and request shutdown now instead of leaving
            // the process unable to stop gracefully.
            log.err("signal pipe watch failed, requesting shutdown: {}", .{err});
            self.callback(self.context);
            return .disarm;
        };
        if (self.stopping) return .disarm;

        if (coalesce(self.drain())) self.callback(self.context);
        // The callback may have requested shutdown; that path stops the watch.
        if (self.stopping) return .disarm;
        self.active = true;
        return .rearm;
    }

    /// Drains the self-pipe until it reports empty.
    ///
    /// Returns whether any token was consumed. A non-`WouldBlock` failure is
    /// reported as a wakeup so a shutdown request is never lost to a broken
    /// pipe.
    fn drain(self: *Self) usize {
        var buffer: [32]u8 = undefined;
        var drained: usize = 0;
        while (true) {
            const bytes = std.posix.read(self.read_fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("signal pipe drain failed: {}", .{err});
                    return drained + 1;
                },
            };
            if (bytes == 0) break;
            drained += bytes;
        }
        return drained;
    }
};

/// kernel32 `SetConsoleCtrlHandler` signature.
const SetConsoleCtrlHandlerFn = *const fn (
    handler_routine: ?ConsoleHandlerRoutine,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

/// Console control routine accepted by `SetConsoleCtrlHandler`.
const ConsoleHandlerRoutine = *const fn (
    control_type: windows.DWORD,
) callconv(.winapi) windows.BOOL;

const set_console_ctrl_handler = @extern(SetConsoleCtrlHandlerFn, .{
    .name = "SetConsoleCtrlHandler",
    .library_name = "kernel32",
});

/// Console control events the watcher treats as shutdown requests.
const ConsoleControl = enum(windows.DWORD) {
    ctrl_c = 0,
    ctrl_break = 1,
    ctrl_close = 2,
    ctrl_logoff = 5,
    ctrl_shutdown = 6,
    _,
};

/// Console control handlers cannot capture context, so the process-wide
/// pending flag and published async pointer are the documented OS-singleton
/// exception to the file-scope `var` rule. The handler reads the pointer once
/// and only touches the atomic flag.
const ConsoleHandler = struct {
    var installed: std.atomic.Value(bool) = .init(false);
    var pending: std.atomic.Value(bool) = .init(false);
    var wakeup: std.atomic.Value(?*xev.Async) = .init(null);
};

/// Windows handler recording the request and waking the owning loop.
fn handle_console_control(control_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    switch (@as(ConsoleControl, @enumFromInt(control_type))) {
        .ctrl_c, .ctrl_break, .ctrl_close, .ctrl_logoff, .ctrl_shutdown => {},
        _ => return windows.BOOL.FALSE,
    }
    ConsoleHandler.pending.store(true, .release);
    if (ConsoleHandler.wakeup.load(.acquire)) |wakeup| {
        // One wakeup is enough; a failed post is re-observed through the
        // pending flag by the next wait.
        wakeup.notify() catch {};
    }
    return windows.BOOL.TRUE;
}

/// Windows watcher driven by a console control handler and a libxev async.
///
/// Console events coalesce through the pending flag: any number of events
/// recorded before the loop runs the wait callback produce one callback.
pub const WindowsWatcher = struct {
    const Self = @This();

    loop: *Loop,
    callback: Callback,
    context: *anyopaque,
    wakeup: xev.Async = undefined,
    completion: xev.Completion = .{},
    installed: bool = false,
    started: bool = false,
    stopping: bool = false,
    active: bool = false,

    /// Replaces the process console control handler and creates the wakeup.
    ///
    /// Returns `error.SignalWatcherAlreadyInstalled` while another watcher
    /// owns the process-wide handler state.
    pub fn init(loop: *Loop, callback: Callback, context: *anyopaque) !Self {
        if (ConsoleHandler.installed.swap(true, .acq_rel)) {
            return error.SignalWatcherAlreadyInstalled;
        }
        var wakeup = xev.Async.init() catch |err| {
            ConsoleHandler.installed.store(false, .release);
            return err;
        };
        if (!set_console_ctrl_handler(handle_console_control, windows.BOOL.TRUE).toBool()) {
            wakeup.deinit();
            ConsoleHandler.installed.store(false, .release);
            return error.SignalWatcherInstallFailed;
        }
        ConsoleHandler.pending.store(false, .release);
        ConsoleHandler.wakeup.store(null, .release);
        return .{
            .loop = loop,
            .callback = callback,
            .context = context,
            .wakeup = wakeup,
            .installed = true,
        };
    }

    /// Arms the async wait; idempotent and non-blocking.
    pub fn start(self: *Self) void {
        if (self.started or !self.installed) return;
        self.started = true;
        ConsoleHandler.wakeup.store(&self.wakeup, .release);
        self.active = true;
        self.wakeup.wait(
            self.loop.get_xev_loop(),
            &self.completion,
            Self,
            self,
            on_wakeup,
        );
        // An event recorded before the wait was armed still needs a post.
        if (ConsoleHandler.pending.load(.acquire)) self.wakeup.notify() catch {};
    }

    /// Wakes and disarms an armed wait; idempotent and non-blocking.
    pub fn stop(self: *Self) void {
        if (!self.started or self.stopping) return;
        self.stopping = true;
        ConsoleHandler.wakeup.store(null, .release);
        if (!self.active) return;
        self.wakeup.notify() catch {};
    }

    /// Reports whether no completion can still reference this watcher.
    pub fn is_drained(self: *const Self) bool {
        if (!self.started) return true;
        return !self.active;
    }

    /// Removes the console handler and releases the wakeup.
    ///
    /// Callers must first `stop`, drive the loop, and observe `is_drained`.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.is_drained());
        self.release();
    }

    /// Releases without requiring a drained wait.
    ///
    /// Only valid when the owning loop will never run again, such as a cluster
    /// worker whose thread has already exited; the loop must be deinitialized
    /// afterwards without executing completions.
    pub fn deinit_undrained(self: *Self) void {
        self.release();
    }

    fn release(self: *Self) void {
        if (!self.installed) {
            self.* = undefined;
            return;
        }
        // Unpublish the wakeup target before the handler is removed so a late
        // console event cannot reach storage that is about to be released.
        ConsoleHandler.wakeup.store(null, .release);
        ConsoleHandler.pending.store(false, .release);
        _ = set_console_ctrl_handler(handle_console_control, windows.BOOL.FALSE);
        ConsoleHandler.installed.store(false, .release);
        self.wakeup.deinit();
        self.* = undefined;
    }

    fn on_wakeup(
        user_data: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.active = false;
        _ = result catch return .disarm;
        if (self.stopping) return .disarm;

        if (ConsoleHandler.pending.swap(false, .acquire)) self.callback(self.context);
        // The callback may have requested shutdown; that path stops the watch.
        if (self.stopping) return .disarm;
        self.active = true;
        return .rearm;
    }
};
