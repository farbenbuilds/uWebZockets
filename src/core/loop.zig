const std = @import("std");
const xev = @import("xev");

/// Completion-driven event loop backed by libxev.
pub const Loop = struct {
    xev_loop: xev.Loop,
    /// Owned thread pool for backends that offload blocking file operations
    /// (epoll, kqueue, IOCP). Null on io_uring, which runs them in the ring.
    thread_pool: ?*xev.ThreadPool = null,

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
    comptime callback: xev.cancel_callback(Userdata),
) void {
    xev.cancel(loop, completion, cancel_completion, Userdata, userdata, callback);
}

fn create_thread_pool() !*xev.ThreadPool {
    const pool = try std.heap.page_allocator.create(xev.ThreadPool);
    pool.* = xev.ThreadPool.init(.{});
    return pool;
}

fn destroy_thread_pool(pool: *xev.ThreadPool) void {
    pool.shutdown();
    pool.deinit();
    std.heap.page_allocator.destroy(pool);
}

/// Initializes an event loop sized for 4096 completion entries.
///
/// Selects the first available backend before any watcher exists and falls
/// back to epoll when an available io_uring still cannot create its ring.
pub fn init() !Loop {
    try xev.detect();

    var thread_pool: ?*xev.ThreadPool = null;
    errdefer if (thread_pool) |pool| destroy_thread_pool(pool);

    const needs_pool = xev.backend() != .io_uring;
    if (needs_pool) thread_pool = try create_thread_pool();

    if (comptime xev.dynamic) {
        const handle = xev.Loop.init(.{
            .entries = 4096,
            .thread_pool = thread_pool,
        }) catch |err| {
            if (xev.backend() != .io_uring or !xev.prefer(.epoll)) return err;
            // io_uring probed as available but ring creation failed; degrade
            // to epoll instead of refusing to start.
            if (thread_pool == null) thread_pool = try create_thread_pool();
            return .{
                .xev_loop = try xev.Loop.init(.{
                    .entries = 4096,
                    .thread_pool = thread_pool,
                }),
                .thread_pool = thread_pool,
            };
        };
        return .{ .xev_loop = handle, .thread_pool = thread_pool };
    }

    return .{
        .xev_loop = try xev.Loop.init(.{
            .entries = 4096,
            .thread_pool = thread_pool,
        }),
        .thread_pool = thread_pool,
    };
}

/// Releases operating-system resources after all operations have stopped.
pub fn deinit(l: *Loop) void {
    // libxev requires the thread pool to stop before the loop's storage is
    // released, since a worker may still deliver a completion into it.
    if (l.thread_pool) |pool| destroy_thread_pool(pool);
    l.thread_pool = null;
    l.xev_loop.deinit();
}

/// Runs until no active connection, timer, or cancellation remains.
pub fn run(l: *Loop) !void {
    // .until_done forces the loop to run continuously until all
    // completions (i/o, timer) are fully canceled or processed
    try l.xev_loop.run(.until_done);
}
