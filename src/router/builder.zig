//! Ergonomic, compile-time server construction.
//!
//! `Server.builder(io)` starts a fluent chain whose `with_*` methods each
//! return a builder for a new `ServerConfig`. `build(allocator)` then performs
//! exactly one allocation: the contiguous slab that backs every pool, request,
//! message, queue, and optional compression region. Nothing on the runtime I/O
//! path allocates.

const std = @import("std");
const app_module = @import("app.zig");
const config_module = @import("config.zig");

/// Human-readable capacities accepted by the builder.
pub const ServerConfig = config_module.ServerConfig;
/// Named capacity presets such as `Preset.microservice`.
pub const Preset = config_module.ServerConfig.Preset;
/// Views over the single contiguous startup slab.
pub const SlabLayout = config_module.SlabLayout;
/// Defaults used when no `with_*` override is applied.
pub const default_config = config_module.default_config;

/// Fluent entry point for configured servers.
///
/// ```zig
/// var server = try Server.builder(init.io)
///     .preset(Preset.microservice)
///     .with_max_body_size(256 * 1024)
///     .build(std.heap.page_allocator);
/// defer server.deinit();
/// ```
pub const Server = struct {
    /// Starts a builder from the default configuration.
    pub fn builder(io: std.Io) Builder(default_config) {
        return .{ .io = io };
    }

    /// Starts a builder directly from a named preset.
    pub fn preset(io: std.Io, comptime config: ServerConfig) Builder(config) {
        return .{ .io = io };
    }
};

/// Compile-time specialized builder; every `with_*` returns a new builder type.
///
/// Capacities stay compile-time because they size the generated application
/// type. Passing a literal or a `const` value keeps the fluent syntax working;
/// a runtime-variable capacity is rejected at compile time by design.
pub fn Builder(comptime config: ServerConfig) type {
    comptime {
        config.validate() catch @compileError(
            "invalid ServerConfig: capacities must be non-zero and the idle timeout must fit i64",
        );
    }

    return struct {
        const Self = @This();

        /// Application type generated for this configuration.
        pub const AppType = app_module.configured_app_with_timeout(
            config.max_connections,
            config.max_ws_message_size,
            config.write_queue_size,
            config.idle_timeout_ms,
        );

        io: std.Io,

        /// Overrides the maximum simultaneous connection count.
        pub fn with_max_clients(
            self: Self,
            comptime value: usize,
        ) Builder(config.with(.{ .max_connections = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the maximum complete WebSocket message size.
        pub fn with_max_ws_message_size(
            self: Self,
            comptime value: usize,
        ) Builder(config.with(.{ .max_ws_message_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the bounded pending-output bytes per connection.
        pub fn with_write_queue_size(
            self: Self,
            comptime value: usize,
        ) Builder(config.with(.{ .write_queue_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the largest accepted HTTP/1.1 request body.
        pub fn with_max_body_size(
            self: Self,
            comptime value: usize,
        ) Builder(config.with(.{ .max_body_size = value })) {
            return .{ .io = self.io };
        }

        /// Overrides the inactivity timeout; zero disables the sweeper.
        pub fn with_idle_timeout_ms(
            self: Self,
            comptime value: u64,
        ) Builder(config.with(.{ .idle_timeout_ms = value })) {
            return .{ .io = self.io };
        }

        /// Reserves RFC 7692 scratch in the startup slab when enabled.
        pub fn with_compression(
            self: Self,
            comptime enabled: bool,
        ) Builder(config.with(.{ .compression = enabled })) {
            return .{ .io = self.io };
        }

        /// Replaces the whole configuration with a named preset or literal.
        pub fn preset(self: Self, comptime value: ServerConfig) Builder(value) {
            return .{ .io = self.io };
        }

        /// Returns the configuration this builder will build.
        pub fn configuration(self: Self) ServerConfig {
            _ = self;
            return config;
        }

        /// Returns the exact contiguous slab size `build` will allocate.
        pub fn slab_bytes(self: Self) config_module.Error!usize {
            _ = self;
            return config.slab_bytes();
        }

        /// Allocates the startup slab once and returns the ready application.
        ///
        /// Register routes on the returned value, then call `listen`/`run`.
        /// The value must stay at a stable address after listening.
        pub fn build(self: Self, allocator: std.mem.Allocator) !AppType {
            return AppType.init_configured(self.io, allocator, config);
        }
    };
}
