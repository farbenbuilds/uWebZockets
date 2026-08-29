const std = @import("std");
const xev = @import("xev");
const tcp = @import("tcp.zig");
const Loop = @import("loop.zig").Loop;

// a lightweight, zero-allocation timer context for the event loop.
pub const TimerContext = struct {
    timer: xev.Timer,
    completion: xev.Completion = undefined,
    interval_ms: u64,
    tick_cb: *const fn () void,
};

// initializes a recurring timer.
pub fn init_timer(interval_ms: u64, tick_callback: *const fn () void) !TimerContext {
    const t = try xev.Timer.init();
    return TimerContext{
        .timer = t,
        .interval_ms = interval_ms,
        .tick_cb = tick_callback,
    };
}

// dismantles the timer.
pub fn deinit_timer(ctx: *TimerContext) void {
    ctx.timer.deinit();
}

// arms the timer on the provided event loop.
pub fn start_timer(ctx: *TimerContext, loop: *Loop) void {
    ctx.timer.run(
        loop.get_xev_loop(),
        &ctx.completion,
        ctx.interval_ms,
        TimerContext,
        ctx,
        on_timer_tick,
    );
}

// callback triggered by libxev when the interval elapses.
fn on_timer_tick(
    user_data: ?*TimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    _ = result catch |err| {
        std.debug.print("timer error: {}\n", .{err});
        return .disarm;
    };

    const ctx = user_data.?;
    ctx.tick_cb();

    // io_uring rearms the original absolute timeout, which is already expired.
    ctx.timer.run(loop, completion, ctx.interval_ms, TimerContext, ctx, on_timer_tick);
    return .disarm;
}

// connection sweeper, generic over pool type to prevent import loops
pub fn ConnectionSweeper(comptime PoolType: type, comptime idle_timeout_ms: u64) type {
    if (idle_timeout_ms > std.math.maxInt(i64)) {
        @compileError("idle timeout exceeds the monotonic clock representation");
    }

    return struct {
        const Self = @This();
        const timeout_ms: i64 = @intCast(idle_timeout_ms);

        timer: xev.Timer,
        completion: xev.Completion = undefined,
        pool: *PoolType,
        io: std.Io,

        pub fn init(io: std.Io, pool: *PoolType) !Self {
            return Self{
                .timer = try xev.Timer.init(),
                .pool = pool,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.timer.deinit();
        }

        pub fn start(self: *Self, loop: *Loop) void {
            // run callback every 5000ms (5 seconds)
            self.timer.run(
                loop.get_xev_loop(),
                &self.completion,
                5000,
                Self,
                self,
                on_tick,
            );
        }

        // callback triggered by libxev every 5 seconds
        fn on_tick(
            user_data: ?*Self,
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            _ = result catch |err| {
                std.debug.print("sweeper timer error: {}\n", .{err});
                return .disarm;
            };

            const self = user_data.?;
            const now = std.Io.Clock.now(.awake, self.io);
            const current_time: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000));

            // sweep through contiguous storage array (data-oriented design)
            // contiguous memory ensures cpu cache processes all items in microseconds
            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index) or conn.closing) continue;
                if (conn.last_active_ms <= 0) continue;

                const idle_time = current_time - conn.last_active_ms;
                if (idle_time <= timeout_ms) continue;

                conn.last_active_ms = 0;
                tcp.close_connection(conn);
            }

            // Schedule a new relative timeout instead of reusing an expired one.
            self.timer.run(loop, completion, 5000, Self, self, on_tick);
            return .disarm;
        }
    };
}
