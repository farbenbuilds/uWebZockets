//! Cluster lifecycle policy and borrowed thread-slice coordination.
//!
//! The group owns lifecycle transitions, release claiming, start/join
//! coordination, and first-failure capture. Thread storage, worker slabs, and
//! event loops stay with the cluster. A borrowed slice keeps the public
//! `Cluster.threads` field source-compatible.

const std = @import("std");

/// Lifecycle of a thread-per-core cluster.
pub const Lifecycle = enum(u8) {
    /// Workers exist but no thread has been spawned.
    configured,
    /// Worker threads are running or draining.
    running,
    /// `run` returned after every worker joined.
    stopped,
    /// `deinit` claimed release and is freeing storage.
    releasing,
    /// `deinit` released every worker and thread handle.
    released,
};

/// Lifecycle-sensitive call rejection.
pub const LifecycleError = error{
    ClusterDeinitialized,
    ClusterRunning,
    ClusterStopped,
};

/// Release claiming failure.
pub const ReleaseError = error{ClusterRunning};

/// Phase that produced a worker failure.
pub const FailurePhase = enum(u8) {
    /// `std.Thread.spawn` failed on the supervisor thread.
    spawn,
    /// The worker's event-loop driver returned an error.
    run,
};

/// First worker error observed by the supervisor.
pub const WorkerFailure = struct {
    /// Zero-based index of the worker that failed.
    index: usize,
    /// Startup phase that failed.
    phase: FailurePhase,
    /// Error returned by thread spawn or the worker event loop.
    err: anyerror,
};

/// Thread-group start failure.
pub const StartError = error{
    InvalidWorkerCount,
    WorkerGroupAlreadyRunning,
    WorkerGroupNotRunning,
} || std.Thread.SpawnError;

/// Returns a type-safe group bound to a borrowed thread slice.
pub fn worker_group(comptime Context: type) type {
    return struct {
        const Self = @This();

        /// Worker entry point; runs on the spawned thread.
        pub const StartCallback = *const fn (context: *Context, index: usize) void;

        lifecycle: std.atomic.Value(Lifecycle) = .init(.configured),
        active: std.atomic.Value(usize) = .init(0),
        started: usize = 0,
        running: bool = false,
        failure_lock: std.atomic.Mutex = .unlocked,
        first_failure: ?WorkerFailure = null,
        failures: usize = 0,

        /// Current lifecycle state.
        pub fn state(self: *const Self) Lifecycle {
            return self.lifecycle.load(.acquire);
        }

        /// Number of worker threads started by the last `start` call.
        pub fn worker_count(self: *const Self) usize {
            return self.started;
        }

        /// Publishes the active worker count for lock-free supervisor reads.
        pub fn set_active(self: *Self, count: usize) void {
            self.active.store(count, .release);
        }

        /// Returns the active worker count without touching worker storage.
        pub fn active_count(self: *const Self) usize {
            return self.active.load(.acquire);
        }

        /// Requires a group that has not run and has not been released.
        pub fn require_configured(self: *const Self) LifecycleError!void {
            return switch (self.state()) {
                .configured => {},
                .running => error.ClusterRunning,
                .stopped => error.ClusterStopped,
                .releasing, .released => error.ClusterDeinitialized,
            };
        }

        /// Requires a group whose workers can still consume a publish.
        pub fn require_publishable(self: *const Self) LifecycleError!void {
            return switch (self.state()) {
                .configured, .running => {},
                .stopped => error.ClusterStopped,
                .releasing, .released => error.ClusterDeinitialized,
            };
        }

        /// Claims the configured-to-running transition exactly once.
        pub fn begin_run(self: *Self) LifecycleError!void {
            while (true) {
                switch (self.state()) {
                    .configured => {
                        if (self.lifecycle.cmpxchgWeak(
                            .configured,
                            .running,
                            .acq_rel,
                            .acquire,
                        ) == null) return;
                    },
                    .running => return error.ClusterRunning,
                    .stopped => return error.ClusterStopped,
                    .releasing, .released => return error.ClusterDeinitialized,
                }
            }
        }

        /// Publishes the stopped state after every worker has joined.
        pub fn finish_run(self: *Self) void {
            std.debug.assert(self.state() == .running);
            std.debug.assert(!self.running);
            self.lifecycle.store(.stopped, .release);
        }

        /// Claims release, or reports that another owner already holds it.
        ///
        /// A running group is rejected so release never frees a live loop.
        pub fn begin_release(self: *Self) ReleaseError!bool {
            while (true) {
                const current = self.state();
                switch (current) {
                    .releasing, .released => return false,
                    .running => return error.ClusterRunning,
                    .configured, .stopped => {
                        // Never release storage while a thread handle is
                        // still joinable, even if the lifecycle is stale.
                        if (self.running) return error.ClusterRunning;
                        if (self.lifecycle.cmpxchgWeak(
                            current,
                            .releasing,
                            .acq_rel,
                            .acquire,
                        ) == null) return true;
                    },
                }
            }
        }

        /// Publishes the released state after storage is freed.
        pub fn finish_release(self: *Self) void {
            std.debug.assert(self.state() == .releasing);
            std.debug.assert(!self.running);
            std.debug.assert(self.started == 0);
            self.lifecycle.store(.released, .release);
        }

        /// Starts exactly `count` workers in the borrowed thread slice.
        ///
        /// A spawn failure records the failing index and phase. The caller
        /// must request shutdown for the started workers and call `join`
        /// before releasing the context or the thread slice.
        pub fn start(
            self: *Self,
            threads: []std.Thread,
            count: usize,
            context: *Context,
            callback: StartCallback,
        ) StartError!void {
            if (self.state() != .running) return error.WorkerGroupNotRunning;
            if (self.running or self.started != 0) return error.WorkerGroupAlreadyRunning;
            if (count == 0 or count > threads.len) return error.InvalidWorkerCount;

            self.clear_failure();
            self.running = true;
            for (0..count) |index| {
                threads[index] = std.Thread.spawn(
                    .{},
                    entry,
                    .{ context, callback, index },
                ) catch |err| {
                    self.record_failure(index, .spawn, err);
                    return err;
                };
                self.started += 1;
            }
        }

        /// Joins every started worker and clears the running state.
        pub fn join(self: *Self, threads: []std.Thread) void {
            std.debug.assert(threads.len >= self.started);
            for (threads[0..self.started]) |thread| thread.join();
            self.started = 0;
            self.running = false;
        }

        /// Records one failure; the first failure and the total count are kept.
        ///
        /// The lock is confined to this cold supervisor path.
        pub fn record_failure(
            self: *Self,
            index: usize,
            phase: FailurePhase,
            err: anyerror,
        ) void {
            self.lock_failure();
            defer self.failure_lock.unlock();
            self.failures += 1;
            if (self.first_failure == null) {
                self.first_failure = .{ .index = index, .phase = phase, .err = err };
            }
        }

        /// Returns the first failure, or null while every worker is healthy.
        pub fn failure(self: *Self) ?WorkerFailure {
            self.lock_failure();
            defer self.failure_lock.unlock();
            return self.first_failure;
        }

        /// Number of failures recorded since the last `start`.
        pub fn failure_count(self: *Self) usize {
            self.lock_failure();
            defer self.failure_lock.unlock();
            return self.failures;
        }

        fn clear_failure(self: *Self) void {
            self.lock_failure();
            defer self.failure_lock.unlock();
            self.first_failure = null;
            self.failures = 0;
        }

        fn lock_failure(self: *Self) void {
            while (!self.failure_lock.tryLock()) std.atomic.spinLoopHint();
        }

        fn entry(context: *Context, callback: StartCallback, index: usize) void {
            callback(context, index);
        }
    };
}
