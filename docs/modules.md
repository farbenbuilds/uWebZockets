# Worker-local module lifecycle

Optional modules borrow one application's loop and timing wheel. Each cluster
worker owns a separate module instance. Register each instance with
`app.provide(hooks)` during cluster configuration, before `listen`; keep its
context at a stable address and its name bytes alive until `app.deinit` finishes.
The registry stores at
most 16 hooks inline and allocates no memory.

```zig
const uz = @import("uWebZockets");

const Resource = struct {
    started: bool = false,

    fn start(context: *anyopaque, worker: *const uz.modules.WorkerContext) uz.modules.ServiceError!void {
        const resource: *Resource = @ptrCast(@alignCast(context));
        _ = worker;
        resource.started = true;
    }

    fn stop(context: *anyopaque, _: *const uz.modules.WorkerContext) void {
        const resource: *Resource = @ptrCast(@alignCast(context));
        resource.started = false;
    }

    fn ready(context: *anyopaque) ?[]const u8 {
        const resource: *Resource = @ptrCast(@alignCast(context));
        return if (resource.started) null else "resource unavailable";
    }
};
```

Register a caller-owned `Resource` with a `ServiceHooks` value containing a
name, context pointer, and these callbacks. `deinit` is optional; use it to
release startup memory or OS handles after asynchronous cancellation drains.
Hook names are at most 48 ASCII letters, digits, underscores, dots, or hyphens.
Names must be unique within a worker. Registration after listener binding
returns `ServiceRegistrationClosed`; exceeding the inline registry returns
`ServiceCapacityReached`.

`WorkerContext` exposes the worker index, `std.Io`, and borrowed opaque pointers.
The loop pointer refers to `core.loop.Loop`, the configuration pointer refers
to `router.config.ServerConfig`, and the scheduler pointer, when present,
refers to `core.timer.Scheduler`. A module must never move, replace, or destroy
these borrowed resources, run the loop recursively, or use them from another
thread. Modules that need the low-level implementation contract should import
the project module that owns it; the opaque fields do not transfer ownership.

Startup runs on the owning worker in this order:

1. Bind all listeners and establish the worker's timing wheel.
2. Call `start` in registration order.
3. Drive asynchronous startup on the existing loop.
4. Emit ready summaries when every registered `ready` callback returns null.

A resource can schedule non-blocking startup and return before it becomes
ready. The application polls readiness with a single inline timer while startup
is pending. `app.service_readiness()` returns the first unready resource and a
reason of at most 128 bytes. Reasons must be static, credential-free messages;
never include URLs, passwords, tokens, SQL parameters, or peer error text.
An optional `failed` callback reports a terminal asynchronous startup error.
The first such error is latched with its resource name. The application drains
core and module completions, then returns that error from `run`; an unready
state alone does not fail startup.

A failed `start` preserves the first resource name and bounded `ServiceError`
in `app.service_failure()`, calls `stop` on the partially started resource and
on earlier resources in reverse order, then drains pending callbacks on the
same worker. `start` failures propagate through the existing cluster
`WorkerFailure` record as a worker run failure. A hook's `stop` must tolerate
partial initialization. The application calls `deinit` for every registered
resource, including an instance whose `start` never ran.

Shutdown stops accepting, closes HTTP/QUIC connections, and stops recurring
core timers first. After those completions drain, the application calls module
`stop` callbacks in reverse order. A stop callback initiates cancellation; it
must not block and must not free storage still borrowed by a completion. The
loop continues until those module completions have disarmed. `deinit` callbacks
then release module-owned startup resources in reverse order before the loop
is destroyed. Both stop and deinit dispatch are once-only.

Use `app.request_shutdown()` for cross-thread shutdown requests. Start, stop,
and running readiness callbacks run on the owning worker. A cluster's deinit
callbacks run on the supervisor after workers join, with their loops drained;
they may release resources but must not schedule more work. Read readiness
from the owning worker while it is running. Cross-worker state belongs in an
external system.
SQL is a Zig-only optional module. The C ABI does not expose module hooks or
SQL handles; expanding it requires a separate ABI decision and consumer tests.

See [the lifecycle decision](adr/0012-worker-module-lifecycle.md) and
[SQL](sql.md) for the first resource owner.
