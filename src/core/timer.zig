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
    _ = loop;
    _ = completion;

    _ = result catch |err| {
        std.debug.print("timer error: {}\n", .{err});
        return .disarm;
    };

    const ctx = user_data.?;
    ctx.tick_cb();

    return .rearm;
}

// connection sweeper, generic over pool type to prevent import loops
pub fn ConnectionSweeper(comptime PoolType: type) type {
    return struct {
        const Self = @This();

        timer: xev.Timer,
        completion: xev.Completion = undefined,
        pool: *PoolType,

        // timeout 30 seconds (30,000 ms)
        const timeout_ms: i64 = 30_000;

        pub fn init(pool: *PoolType) !Self {
            return Self{
                .timer = try xev.Timer.init(),
                .pool = pool,
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
            _ = completion;
            _ = result catch |err| {
                std.debug.print("sweeper timer error: {}\n", .{err});
                return .disarm;
            };

            const self = user_data.?;
            const current_time = std.time.milliTimestamp();

            // sweep through contiguous storage array (data-oriented design)
            // contiguous memory ensures cpu cache processes all items in microseconds
            for (&self.pool.storage) |*conn| {
                if (conn.last_active_ms > 0) {
                    const idle_time = current_time - conn.last_active_ms;

                    if (idle_time > timeout_ms) {
                        std.debug.print("disconnecting due to timeout (slowloris)!\n", .{});
                        // graceful async close via tcp core
                        tcp.close_connection(conn);
                        // reset active state to prevent double closing
                        conn.last_active_ms = 0;
                    }
                }
            }

            // rearm timer for another 5 seconds
            self.timer.run(loop, &self.completion, 5000, Self, self, on_tick);
            return .rearm;
        }
    };
}
