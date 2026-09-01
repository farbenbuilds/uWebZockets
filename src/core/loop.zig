const xev = @import("xev");

/// Completion-driven event loop backed by libxev.
pub const Loop = struct {
    xev_loop: xev.Loop,

    /// Returns the borrowed libxev loop handle used by transport integrations.
    pub inline fn get_xev_loop(self: *Loop) *xev.Loop {
        return &self.xev_loop;
    }
};

/// Cancels a completion across libxev backends.
pub fn cancel(
    loop: *xev.Loop,
    completion: *xev.Completion,
    cancel_completion: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime callback: *const fn (
        userdata: ?*Userdata,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction,
) void {
    if (xev.backend != .kqueue) {
        loop.cancel(
            completion,
            cancel_completion,
            Userdata,
            userdata,
            callback,
        );
        return;
    }

    cancel_completion.* = .{
        .op = .{ .cancel = .{ .c = completion } },
        .userdata = userdata,
        .callback = (struct {
            fn callback_inner(
                raw_userdata: ?*anyopaque,
                inner_loop: *xev.Loop,
                inner_completion: *xev.Completion,
                result: xev.Result,
            ) xev.CallbackAction {
                const typed_userdata: ?*Userdata = if (Userdata == void)
                    null
                else
                    @ptrCast(@alignCast(raw_userdata));
                return @call(.always_inline, callback, .{
                    typed_userdata,
                    inner_loop,
                    inner_completion,
                    if (result.cancel) |_| {} else |err| err,
                });
            }
        }).callback_inner,
    };
    loop.add(cancel_completion);
}

/// Initializes an event loop sized for 4096 completion entries.
pub fn init() !Loop {
    return .{
        // allows processing up to 4096 i/o events in a single kernel wake-up
        .xev_loop = try xev.Loop.init(.{ .entries = 4096 }),
    };
}

/// Releases operating-system resources after all operations have stopped.
pub fn deinit(l: *Loop) void {
    l.xev_loop.deinit();
}

/// Runs until no active connection, timer, or cancellation remains.
pub fn run(l: *Loop) !void {
    // .until_done forces the loop to run continuously until all
    // completions (i/o, timer) are fully canceled or processed
    try l.xev_loop.run(.until_done);
}
