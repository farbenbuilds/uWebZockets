const xev = @import("xev");

/// Completion-driven event loop backed by libxev.
pub const Loop = struct {
    xev_loop: xev.Loop,

    /// Returns the borrowed libxev loop handle used by transport integrations.
    pub inline fn get_xev_loop(self: *Loop) *xev.Loop {
        return &self.xev_loop;
    }
};

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
