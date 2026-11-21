//! Thread-per-core application ownership and supervisor coordination.
const std = @import("std");
const core_affinity = @import("../core/affinity.zig");
const core_signal = @import("../core/signal.zig");
const cluster_module = @import("cluster.zig");
const worker_group_module = @import("worker_group.zig");
const config_module = @import("config.zig");
const TlsContext = @import("../crypto/tls.zig").TlsContext;
const ClusterOptions = cluster_module.ClusterOptions;

const log = std.log.scoped(.server);

/// Specializes a worker manager for App-compatible workers and bounded inboxes.
/// WorkerApp supplies the listener, TLS, inbox, and loop lifetime operations.
pub fn cluster(
    comptime WorkerApp: type,
    comptime ClusterInbox: type,
    comptime capacity: usize,
    comptime default_config: config_module.ServerConfig,
) type {
    if (capacity == 0) @compileError("cluster worker count must be greater than zero");

    return struct {
        const Cluster = @This();

        /// Concrete application type every worker owns.
        pub const Worker = WorkerApp;
        /// Route configuration callback applied to every worker.
        pub const ConfigureCallback = *const fn (*Worker, usize) anyerror!void;

        /// PEM credential paths loaded into every worker's TLS context.
        const PemCredentials = struct {
            cert_path: [:0]const u8,
            key_path: [:0]const u8,
        };

        /// Where one worker's TLS context credentials come from.
        const TlsCredentialSource = union(enum) {
            pem_files: PemCredentials,
            ephemeral: void,
        };

        allocator: std.mem.Allocator,
        workers: []WorkerApp,
        inboxes: []ClusterInbox,
        threads: []std.Thread,
        /// Compatibility field; `run` snapshots it at start. New code
        /// should use `ClusterOptions.worker_count` or an explicit
        /// worker-count constructor.
        active_workers: usize = capacity,
        /// Compatibility mirror; updated by `run`/`join`.
        thread_count: usize = 0,
        /// Compatibility mirror; `first_failure()` is authoritative.
        worker_failed: std.atomic.Value(bool) = .init(false),
        startup_options: ClusterOptions = .{},
        cores: core_affinity.CoreSelection = .{},
        signal_watcher: ?core_signal.SignalWatcher = null,
        /// Compatibility mirror; not a synchronization primitive.
        /// `state()` is authoritative for lifecycle decisions.
        deinitialized: bool = false,
        group: worker_group_module.worker_group(Cluster) = .{},

        pub fn init(allocator: std.mem.Allocator, io: std.Io) !Cluster {
            return init_with_options(allocator, io, default_config, .{});
        }

        /// Builds every worker slab on this thread with `config`; each
        /// worker then owns its slab exclusively for its whole lifetime.
        pub fn init_with_options(
            allocator: std.mem.Allocator,
            io: std.Io,
            comptime config: config_module.ServerConfig,
            startup_options: ClusterOptions,
        ) !Cluster {
            const active_count = try cluster_module.resolve_worker_count(
                capacity,
                startup_options,
            );
            return init_with_worker_count(
                allocator,
                io,
                config,
                startup_options,
                active_count,
            );
        }

        /// Builds `active_count` workers inside the compiled capacity.
        ///
        /// `active_count` wins over `startup_options.worker_count`; the
        /// options constructor uses the option when one is set. Only
        /// active workers allocate slabs, inboxes, and thread handles.
        /// Values outside the capacity fail before allocation.
        pub fn init_with_worker_count(
            allocator: std.mem.Allocator,
            io: std.Io,
            comptime config: config_module.ServerConfig,
            startup_options: ClusterOptions,
            active_count: usize,
        ) !Cluster {
            const resolved_count = try cluster_module.validate_worker_count(
                active_count,
                capacity,
            );
            const workers = try allocator.alloc(WorkerApp, resolved_count);
            errdefer allocator.free(workers);
            const inboxes = try allocator.alloc(ClusterInbox, resolved_count);
            errdefer allocator.free(inboxes);
            const threads = try allocator.alloc(std.Thread, resolved_count);
            errdefer allocator.free(threads);
            for (inboxes) |*inbox| inbox.* = .{};

            var initialized: usize = 0;
            errdefer {
                for (workers[0..initialized]) |*app_worker| app_worker.deinit();
            }
            for (workers, 0..) |*app_worker, index| {
                app_worker.* = try WorkerApp.init_configured(io, allocator, config);
                app_worker.worker_index = index;
                initialized += 1;
                try app_worker.attach_cluster_inbox(&inboxes[index]);
            }
            return .{
                .allocator = allocator,
                .workers = workers,
                .inboxes = inboxes,
                .threads = threads,
                .active_workers = resolved_count,
                .startup_options = startup_options,
                .cores = core_affinity.CoreSelection.init(),
                .group = .{ .active = std.atomic.Value(usize).init(resolved_count) },
            };
        }

        /// Releases the cluster; panics if `run` is still active.
        ///
        /// Supervisors that cannot accept a panic use
        /// `deinit_checked` and handle `error.ClusterRunning`.
        pub fn deinit(self: *Cluster) void {
            self.deinit_checked() catch |err| switch (err) {
                error.ClusterRunning => std.debug.panic(
                    "cannot deinitialize a running cluster",
                    .{},
                ),
            };
        }

        /// Releases the cluster and returns a typed lifecycle error.
        ///
        /// The call claims release once. A second caller waits until
        /// the winning owner publishes `released`, then returns.
        pub fn deinit_checked(self: *Cluster) cluster_module.ReleaseError!void {
            if (!try self.group.begin_release()) {
                self.group.wait_released();
                return;
            }
            // No new external call can enter after the release claim.
            // Wait for calls that entered before it, then free.
            self.group.wait_idle();
            // Publish the compatibility mirror before storage moves.
            // It is informational, not a synchronization primitive.
            self.deinitialized = true;
            self.group.set_active(0);
            self.stop_signal_watcher();
            // App.deinit closes recurring work and drives each loop
            // until drained, which also processes the watcher stop.
            for (self.workers) |*app_worker| app_worker.deinit();
            self.release_signal_watcher();

            const threads = self.threads;
            const inboxes = self.inboxes;
            const workers = self.workers;
            self.threads = &.{};
            self.inboxes = &.{};
            self.workers = &.{};
            self.active_workers = 0;
            self.thread_count = 0;

            self.allocator.free(threads);
            self.allocator.free(inboxes);
            self.allocator.free(workers);
            self.group.finish_release();
        }

        /// Applies the same route configuration callback to every worker.
        ///
        /// The callback runs before any thread starts. A callback error
        /// stops configuration at that worker and leaves earlier route
        /// registrations in place. Do not call `run` or `deinit_checked`
        /// from the callback; this call already holds an in-flight
        /// registration and release would wait on it.
        pub fn configure(
            self: *Cluster,
            comptime callback: ConfigureCallback,
        ) !void {
            if (!self.group.enter()) return error.ClusterDeinitialized;
            defer self.group.leave();
            try self.group.require_configured();
            for (self.workers, 0..) |*app_worker, index| {
                try callback(app_worker, index);
            }
        }

        /// Returns one worker by index, or null outside the active set.
        ///
        /// The pointer is borrowed and does not keep the group alive.
        /// External synchronization is required if another thread can
        /// call `deinit_checked` while the pointer is retained.
        pub fn worker(self: *Cluster, index: usize) ?*WorkerApp {
            switch (self.group.state()) {
                .releasing, .released => return null,
                .configured, .running, .stopped => {},
            }
            if (index >= self.workers.len) return null;
            return &self.workers[index];
        }

        /// Active worker count, snapshotted by `run`; before the first
        /// run this is the configured count.
        pub fn worker_count(self: *const Cluster) usize {
            return self.group.active_count();
        }

        /// Compiled worker capacity.
        pub fn worker_capacity(self: *const Cluster) usize {
            _ = self;
            return capacity;
        }

        /// Current lifecycle state.
        pub fn state(self: *const Cluster) cluster_module.ClusterState {
            return self.group.state();
        }

        /// First worker or spawn error, or null while every worker is healthy.
        ///
        /// The value stays available after `run` returns so a supervisor
        /// can report the failing worker instead of a bare error name.
        pub fn first_failure(self: *Cluster) ?cluster_module.WorkerFailure {
            return self.group.failure();
        }

        /// Number of failures recorded since the last `run`.
        pub fn failure_count(self: *Cluster) usize {
            return self.group.failure_count();
        }

        /// Loads `cert_path`/`key_path` into one TLS context owned by each worker.
        ///
        /// Call once after `configure` and before `listen`; the supported order is
        /// build_cluster -> configure -> enable_https -> listen -> run. Every worker
        /// keeps its own context, so no TLS state is shared between loops. On any
        /// failure the contexts this call created are released and the call is
        /// retryable.
        ///
        /// Fails with `error.ClusterDeinitialized` after `deinit`,
        /// `error.ClusterRunning` while `run` is active,
        /// `error.ClusterStopped` after `run` returned,
        /// `error.AlreadyListening` after `listen`, and
        /// `error.TlsAlreadyEnabled` on a repeated call. Credential
        /// failures (`CertificateLoadFailed`, `PrivateKeyLoadFailed`)
        /// come from `TlsContext.init`; BoringSSL rejects a key that
        /// does not match the certificate during key load, so a PEM
        /// mismatch also reports `PrivateKeyLoadFailed`.
        pub fn enable_https(
            self: *Cluster,
            cert_path: [:0]const u8,
            key_path: [:0]const u8,
        ) !void {
            return self.install_worker_tls(.{ .pem_files = .{
                .cert_path = cert_path,
                .key_path = key_path,
            } });
        }

        /// Generates one self-signed certificate per worker for development.
        ///
        /// Use `enable_https` with PEM files in production; generated certificates
        /// differ per worker and live only for the process.
        pub fn enable_https_ephemeral(self: *Cluster) !void {
            return self.install_worker_tls(.{ .ephemeral = {} });
        }

        fn install_worker_tls(self: *Cluster, source: TlsCredentialSource) !void {
            if (!self.group.enter()) return error.ClusterDeinitialized;
            defer self.group.leave();
            try self.group.require_configured();

            var created: usize = 0;
            errdefer for (self.workers[0..created]) |*app_worker| app_worker.release_tls();
            for (self.workers) |*app_worker| {
                if (app_worker.shutting_down or app_worker.deinitialized) {
                    return error.ApplicationUnavailable;
                }
                if (app_worker.listener_count != 0) return error.AlreadyListening;
                if (app_worker.tls_ctx != null) return error.TlsAlreadyEnabled;
                app_worker.tls_ctx = switch (source) {
                    .pem_files => |credentials| try TlsContext.init(
                        credentials.cert_path,
                        credentials.key_path,
                    ),
                    .ephemeral => try TlsContext.init_ephemeral(.{}),
                };
                created += 1;
            }
        }

        /// Binds every worker to one shared kernel port.
        pub fn listen(self: *Cluster, address: []const u8, port: u16) !void {
            if (!self.group.enter()) return error.ClusterDeinitialized;
            defer self.group.leave();
            try self.group.require_configured();

            var listening: usize = 0;
            errdefer {
                // Best effort: preserve the original bind error while
                // releasing the listeners created by this call.
                for (self.workers[0..listening], 0..) |*app_worker, index| {
                    app_worker.shutdown() catch |err| {
                        log.warn("worker {d} listen cleanup failed: {s}", .{
                            index,
                            @errorName(err),
                        });
                    };
                }
            }
            for (self.workers) |*app_worker| {
                try app_worker.listen_reuse_port(address, port);
                listening += 1;
            }
        }

        /// Broadcasts through bounded per-worker queues and wakes each loop.
        ///
        /// Kept for source compatibility; returns the accepted count.
        /// Use `publish_report` when the caller must observe dropped
        /// inboxes or failed loop wakeups.
        pub fn publish(
            self: *Cluster,
            topic: []const u8,
            message: []const u8,
            is_text: bool,
        ) cluster_module.PublishError!usize {
            const report = try self.publish_report(topic, message, is_text);
            return report.queued;
        }

        /// Broadcasts and reports accepted, dropped, and unwoken workers.
        pub fn publish_report(
            self: *Cluster,
            topic: []const u8,
            message: []const u8,
            is_text: bool,
        ) cluster_module.PublishError!cluster_module.PublishReport {
            if (!self.group.enter()) return error.ClusterDeinitialized;
            defer self.group.leave();
            try self.group.require_publishable();
            return ClusterInbox.broadcast(
                self.inboxes,
                topic,
                message,
                is_text,
                self,
                notify_worker,
            );
        }

        fn notify_worker(context: *anyopaque, index: usize) bool {
            const self: *Cluster = @ptrCast(@alignCast(context));
            return self.workers[index].notify_cluster_delivery();
        }

        /// Runs all workers on native threads and joins them on shutdown.
        ///
        /// A spawn failure requests shutdown for the workers already
        /// started, joins them, and returns the original OS error.
        /// A worker event-loop or post-run cleanup failure returns
        /// `error.ClusterWorkerFailed` and remains available through
        /// `first_failure`.
        pub fn run(self: *Cluster) cluster_module.RunError!void {
            try self.group.begin_run();

            // Publish `stopped` after cleanup stops the watcher and
            // drains every worker loop. If a drain fails, deinit
            // releases the surviving watcher after the loops are
            // destroyed, so a supervisor still owns a safe free path.
            defer self.group.finish_run();

            const spawn_count = self.active_workers;
            if (spawn_count == 0 or spawn_count > self.threads.len) {
                return error.InvalidWorkerCount;
            }
            self.group.set_active(spawn_count);
            self.worker_failed.store(false, .release);
            var spawn_error: ?std.Thread.SpawnError = null;
            self.group.start(
                self.threads,
                spawn_count,
                self,
                worker_main,
            ) catch |err| {
                if (self.group.failure()) |failure| {
                    log.warn("worker {d} ({s}) failed to start: {s}", .{
                        failure.index,
                        @tagName(failure.phase),
                        @errorName(failure.err),
                    });
                } else {
                    log.warn("worker group failed to start: {s}", .{
                        @errorName(err),
                    });
                }
                spawn_error = switch (err) {
                    error.ThreadQuotaExceeded,
                    error.SystemResources,
                    error.OutOfMemory,
                    error.LockedMemoryLimitExceeded,
                    error.Unexpected,
                    => |spawn_err| spawn_err,
                    // A valid run path cannot reach these lifecycle
                    // preconditions; keep the terminal type finite.
                    error.InvalidWorkerCount,
                    error.WorkerGroupAlreadyRunning,
                    error.WorkerGroupNotRunning,
                    => error.Unexpected,
                };
                self.request_shutdown();
            };

            self.thread_count = self.group.started_count();
            self.group.join(self.threads);
            self.thread_count = 0;
            self.cleanup_workers();

            if (spawn_error) |err| {
                self.worker_failed.store(true, .release);
                return err;
            }
            if (self.group.failure() != null) {
                self.worker_failed.store(true, .release);
                return error.ClusterWorkerFailed;
            }
        }

        /// Stops recurring work and drains every joined worker loop.
        fn cleanup_workers(self: *Cluster) void {
            self.stop_signal_watcher();
            for (self.workers, 0..) |*app_worker, index| {
                app_worker.shutdown() catch |err| {
                    self.group.record_failure(index, .cleanup, err);
                    self.worker_failed.store(true, .release);
                    log.warn("worker {d} cleanup failed: {s}", .{
                        index,
                        @errorName(err),
                    });
                };
            }
            self.drain_signal_watcher();
        }

        /// Requests event-loop-confined shutdown for every worker.
        ///
        /// After `deinit` this is a documented no-op: the worker
        /// slices are released, so there is no loop left to wake and
        /// no resource to drain. The guard makes the behavior explicit
        /// at the call site instead of relying on an empty slice.
        pub fn request_shutdown(self: *Cluster) void {
            if (!self.group.enter()) return;
            defer self.group.leave();
            switch (self.group.state()) {
                .releasing, .released, .stopped => return,
                .configured, .running => {},
            }
            for (self.workers) |*app_worker| app_worker.request_shutdown();
        }

        /// Installs one process-wide shutdown watcher on the first worker.
        ///
        /// The callback requests shutdown for every worker, so one
        /// SIGINT or SIGTERM drains the whole group. Returns
        /// `error.SignalWatcherAlreadyInstalled` while any watcher owns
        /// the process-wide handler state.
        pub fn catch_shutdown_signals(self: *Cluster) !void {
            if (!self.group.enter()) return error.ClusterDeinitialized;
            defer self.group.leave();
            try self.group.require_configured();
            if (self.signal_watcher != null) return error.SignalWatcherAlreadyInstalled;
            self.signal_watcher = try core_signal.SignalWatcher.init(
                &self.workers[0].loop,
                on_cluster_shutdown_signal,
                self,
            );
            self.signal_watcher.?.start();
            if (self.signal_watcher) |*watcher| {
                self.workers[0].cluster_signal_watcher = watcher;
            }
        }

        /// Disarms the cluster watcher before worker loops are drained.
        fn stop_signal_watcher(self: *Cluster) void {
            if (self.signal_watcher) |*watcher| {
                watcher.stop();
                self.workers[0].cluster_signal_watcher = null;
            }
        }

        /// Drains a stopped watcher while the first worker loop still exists.
        fn drain_signal_watcher(self: *Cluster) void {
            const watcher = &(self.signal_watcher orelse return);
            if (watcher.is_drained()) {
                watcher.deinit();
                self.signal_watcher = null;
                return;
            }
            // Worker shutdown has already closed recurring work, so
            // this loop has only the stop wakeup left to process.
            self.workers[0].loop.get_xev_loop().run(.until_done) catch |err| {
                log.warn("cluster signal watcher drain failed: {s}", .{
                    @errorName(err),
                });
                // Keep the watcher; deinit releases it after the
                // worker loops are destroyed and cannot run again.
                return;
            };
            if (watcher.is_drained()) {
                watcher.deinit();
                self.signal_watcher = null;
            }
        }

        /// Releases the watcher after every worker loop is destroyed.
        fn release_signal_watcher(self: *Cluster) void {
            const watcher = &(self.signal_watcher orelse return);
            if (watcher.is_drained()) {
                watcher.deinit();
            } else {
                // The loop cannot run again, so the undrained release
                // is safe here.
                watcher.deinit_undrained();
            }
            self.signal_watcher = null;
        }

        fn on_cluster_shutdown_signal(context: *anyopaque) void {
            const self: *Cluster = @ptrCast(@alignCast(context));
            self.request_shutdown();
            // Disarm this watcher so the first worker's loop can drain.
            if (self.signal_watcher) |*watcher| watcher.stop();
        }

        fn worker_main(self: *Cluster, index: usize) void {
            pin_worker(self, index);
            self.workers[index].run() catch |err| {
                if (self.workers[index].service_failure()) |failure| {
                    self.group.record_startup_failure(index, err, failure);
                } else {
                    self.group.record_failure(index, .run, err);
                }
                self.worker_failed.store(true, .release);
                // `run` returns the error; the log is diagnostic so a
                // supervised caller can own alerting.
                log.warn("worker {d} stopped with error: {s}", .{
                    index,
                    @errorName(err),
                });
                self.request_shutdown();
            };
        }

        /// Pins one worker to its core; failure keeps startup graceful.
        fn pin_worker(self: *Cluster, index: usize) void {
            if (!self.startup_options.cpu_affinity) return;
            const cpu = self.cores.cpu(index) orelse return;
            core_affinity.pin_current_thread(cpu) catch |err| {
                // Restricted cpusets and affinity-less platforms are
                // expected; only the first worker reports them.
                if (index == 0) {
                    log.debug("worker affinity unavailable: {}", .{err});
                }
            };
        }
    };
}
