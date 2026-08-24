const std = @import("std");
const xev = @import("xev");
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
        on_tick_complete,
    );
}

// callback triggered by libxev when the interval elapses.
fn on_tick_complete(
    user_data: ?*TimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.TimerResult,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    if (result.err != .none) {
        return .disarm;
    }

    const ctx = user_data.?;
    ctx.tick_cb();

    return .rearm;
}
