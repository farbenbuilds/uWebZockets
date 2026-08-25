const xev = @import("xev");

pub const Loop = struct {
    xev_loop: xev.Loop,
    // internal api: allow sockets to get the pointer to the underlying xev.loop
    pub inline fn get_xev_loop(self: *Loop) *xev.Loop {
        return &self.xev_loop;
    }
};

// intializes the event loop
// returns an error if the os runs out of file descriptors or kernel memory
pub fn init() !Loop {
    return .{
        // allows processing up to 4096 i/o events in a single kernel wake-up
        .xev_loop = try xev.Loop.init(.{ .entries = 4096 }),
    };
}

// destroys the event loop, releasing system resources
pub fn deinit(l: *Loop) void {
    l.xev_loop.deinit();
}

// blocks the current thread and starts the perpetual event loop
// returns when there are no active connections or timers left
pub fn run(l: *Loop) !void {
    // .until_done forces the loop to run continuously until all
    // completions (i/o, timer) are fully canceled or processed
    try l.xev_loop.run(.until_done);
}
