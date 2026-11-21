//! Fixed-capacity, worker-confined resource lifecycle.
const std = @import("std");

/// Maximum independent resource owners registered on one worker.
pub const max_services = 16;
/// Public module names and readiness reasons never carry credentials.
pub const max_name_bytes = 48;
/// Maximum readiness reason retained by callers.
pub const max_reason_bytes = 128;

/// Stable lifecycle and module startup failure categories.
pub const ServiceError = error{
    Unexpected,
    InvalidConfiguration,
    CapacityExceeded,
    ConnectionFailed,
    AuthenticationFailed,
    TlsFailed,
    DeadlineExceeded,
    MigrationFailed,
    InvalidServiceName,
    DuplicateService,
    ServiceCapacityReached,
    ServiceRegistrationClosed,
    ServiceAlreadyStarted,
};

/// Borrowed worker resources; `loop`, `config`, and `scheduler` point to
/// core.loop.Loop, router.config.ServerConfig, and core.timer.Scheduler.
pub const WorkerContext = struct {
    worker_index: usize,
    io: std.Io,
    loop: *anyopaque,
    config: *const anyopaque,
    scheduler: ?*anyopaque = null,
};

/// Starts one owner on its worker after every listener has bound.
pub const StartCallback = *const fn (context: *anyopaque, worker: *const WorkerContext) ServiceError!void;
/// Initiates cancellation; storage remains live until the loop has drained.
pub const StopCallback = *const fn (context: *anyopaque, worker: *const WorkerContext) void;
/// Returns null when ready, otherwise a static, credential-free reason.
pub const ReadyCallback = *const fn (context: *anyopaque) ?[]const u8;
/// Reports a terminal asynchronous startup failure on the owning worker.
pub const FailedCallback = *const fn (context: *anyopaque) ?ServiceError;
/// Releases startup storage after drain; a joined cluster uses its supervisor.
pub const DeinitCallback = *const fn (context: *anyopaque) void;

/// Explicit hooks borrowing a stable name and worker-local module context.
pub const ServiceHooks = struct {
    name: []const u8,
    context: *anyopaque,
    start: StartCallback,
    stop: StopCallback,
    ready: ?ReadyCallback = null,
    failed: ?FailedCallback = null,
    deinit: ?DeinitCallback = null,
};

/// First startup error, preserved after rollback and shutdown.
pub const Failure = struct {
    name: []const u8,
    err: ServiceError,
};

/// Bounded readiness response naming the first unready owner.
pub const Readiness = struct {
    name: []const u8,
    reason: []const u8,
};

/// Registration and cleanup phases of one worker's resource owners.
pub const State = enum { configured, starting, running, stopped, deinitialized };

/// Inline hook storage; no registration, dispatch, or cleanup allocation.
pub const Registry = struct {
    hooks: [max_services]ServiceHooks = undefined,
    count: usize = 0,
    started: usize = 0,
    state: State = .configured,
    failure: ?Failure = null,

    /// Registers an owner before startup; name and context stay live through deinit.
    pub fn provide(self: *Registry, hooks: ServiceHooks) ServiceError!void {
        if (self.state != .configured) return error.ServiceRegistrationClosed;
        if (!valid_name(hooks.name)) return error.InvalidServiceName;
        for (self.hooks[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing.name, hooks.name)) return error.DuplicateService;
        }
        if (self.count == max_services) return error.ServiceCapacityReached;
        self.hooks[self.count] = hooks;
        self.count += 1;
    }

    /// Rolls back even a partially started hook; stop must tolerate partial init.
    pub fn start(self: *Registry, worker: *const WorkerContext) ServiceError!void {
        if (self.state != .configured) return error.ServiceAlreadyStarted;
        self.state = .starting;
        for (self.hooks[0..self.count]) |hooks| {
            self.started += 1;
            hooks.start(hooks.context, worker) catch |err| {
                self.failure = .{ .name = hooks.name, .err = err };
                self.stop(worker);
                return err;
            };
        }
        self.state = .running;
    }

    /// Initiates reverse-order cancellation once; the caller then drains its loop.
    pub fn stop(self: *Registry, worker: *const WorkerContext) void {
        if (self.state == .stopped or self.state == .deinitialized) return;
        while (self.started != 0) {
            self.started -= 1;
            const hooks = self.hooks[self.started];
            hooks.stop(hooks.context, worker);
        }
        self.state = .stopped;
    }

    /// Reports the first bounded readiness reason without exposing module errors.
    pub fn readiness(self: *const Registry) ?Readiness {
        if (self.count == 0) return null;
        if (self.failure) |failure| return .{ .name = failure.name, .reason = "service startup failed" };
        if (self.state != .running) return .{ .name = self.hooks[0].name, .reason = "service unavailable" };
        for (self.hooks[0..self.count]) |hooks| {
            const callback = hooks.ready orelse continue;
            const reason = callback(hooks.context) orelse continue;
            return .{
                .name = hooks.name,
                .reason = if (reason.len <= max_reason_bytes) reason else "service readiness reason exceeds limit",
            };
        }
        return null;
    }

    /// Latches only the first terminal error; transient unready states stay separate.
    pub fn check_failure(self: *Registry) ?Failure {
        if (self.failure != null or self.state != .running) return self.failure;
        for (self.hooks[0..self.count]) |hooks| {
            const callback = hooks.failed orelse continue;
            const err = callback(hooks.context) orelse continue;
            self.failure = .{ .name = hooks.name, .err = err };
            return self.failure;
        }
        return null;
    }

    /// Requires cancellation completions to be drained before releasing owners.
    pub fn deinit(self: *Registry) void {
        if (self.state == .deinitialized) return;
        std.debug.assert(self.started == 0);
        var index = self.count;
        while (index != 0) {
            index -= 1;
            const hooks = self.hooks[index];
            if (hooks.deinit) |callback| callback(hooks.context);
        }
        self.state = .deinitialized;
    }
};

fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return false;
    }
    return true;
}
