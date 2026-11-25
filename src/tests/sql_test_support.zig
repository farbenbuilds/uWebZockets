const std = @import("std");
const sql = @import("test_support").sql;

const support = @import("test_support");

/// Retains scalar evidence inside the callback, never borrowed row slices.
pub const QueryCapture = struct {
    calls: usize = 0,
    failure: ?sql.RuntimeError = null,
    rows: usize = 0,
    integer: i64 = 0,
    text: [256]u8 = undefined,
    text_len: usize = 0,
    status: u8 = 0,

    pub fn complete(context: *anyopaque, outcome: sql.QueryOutcome) void {
        const self: *QueryCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        switch (outcome) {
            .failure => |failure| self.failure = failure,
            .success => |result| {
                self.status = result.transaction_status;
                var rows = result.rows;
                while (rows.next() catch |err| {
                    self.failure = err;
                    return;
                }) |row| {
                    self.rows += 1;
                    const value = row.value(0) catch |err| {
                        self.failure = err;
                        return;
                    };
                    switch (value) {
                        .int2 => |integer| self.integer = integer,
                        .int4 => |integer| self.integer = integer,
                        .int8 => |integer| self.integer = integer,
                        .text, .varchar, .bytea => |bytes| {
                            if (bytes.len > self.text.len) {
                                self.failure = error.FieldTooLarge;
                                return;
                            }
                            @memcpy(self.text[0..bytes.len], bytes);
                            self.text_len = bytes.len;
                        },
                        else => {},
                    }
                }
            },
        }
    }
};

/// A live integration uses only its own loop, scheduler, connections, and slabs.
pub const LiveDb = struct {
    db: sql.Db,
    loop: support.loop.Loop,
    scheduler: support.timer.Scheduler,
    owned_password: ?[]u8 = null,

    pub fn init() !LiveDb {
        return init_with_tls(null);
    }

    pub fn init_with_tls(tls: ?sql.TlsConfig) !LiveDb {
        const password = try required_env("UWZ_SQL_TEST_PASSWORD");
        errdefer std.testing.allocator.free(password);
        var live = try init_credentials("uwz_test", password, tls);
        live.owned_password = password;
        return live;
    }

    pub fn init_credentials(user: []const u8, password: []const u8, tls: ?sql.TlsConfig) !LiveDb {
        const port_text = try env("UWZ_SQL_TEST_PORT");
        defer if (port_text) |text| std.testing.allocator.free(text);
        const port = try std.fmt.parseInt(u16, port_text orelse "55432", 10);
        var event_loop = try support.loop.init();
        errdefer support.loop.deinit(&event_loop);
        var scheduler = try support.timer.Scheduler.init(std.testing.io);
        errdefer scheduler.deinit();
        const db = try sql.Db.init(std.testing.allocator, .{
            .user = user,
            .database = "uwz_test",
            .password = password,
            .port = port,
            .allow_plaintext = true,
            .tls = tls,
            .limits = .{ .max_message_bytes = 64 * 1024, .max_response_bytes = 64 * 1024 },
        });
        return .{ .db = db, .loop = event_loop, .scheduler = scheduler };
    }

    pub fn start(self: *LiveDb) !void {
        self.scheduler.start(&self.loop);
        try self.db.start(&self.loop, &self.scheduler, std.testing.io, 3);
        const deadline = self.scheduler.current_time_ms() + 5000;
        while (!self.db.ready()) {
            if (self.db.startup_failure) |failure| return failure;
            if (self.scheduler.current_time_ms() >= deadline) return error.DatabaseStartupTimeout;
            try self.loop.xev_loop.run(.once);
        }
    }

    pub fn deinit(self: *LiveDb) void {
        self.db.stop();
        self.scheduler.stop(&self.loop);
        self.loop.xev_loop.run(.until_done) catch @panic("SQL integration close failed to drain");
        self.db.deinit();
        if (self.owned_password) |password| {
            std.crypto.secureZero(u8, password);
            std.testing.allocator.free(password);
            self.owned_password = null;
        }
        self.scheduler.deinit();
        support.loop.deinit(&self.loop);
    }

    pub fn wait(self: *LiveDb, capture: *const QueryCapture) !void {
        const deadline = self.scheduler.current_time_ms() + 5000;
        while (capture.calls == 0) {
            if (self.scheduler.current_time_ms() >= deadline) return error.QueryCompletionTimeout;
            try self.loop.xev_loop.run(.once);
        }
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
    }
};

pub fn request(sql_text: []const u8, capture: *QueryCapture) sql.Query {
    return .{ .statement = .{ .name = "", .sql = sql_text }, .context = capture, .callback = QueryCapture.complete };
}

/// Reads portable test environment storage with explicit caller ownership.
pub fn env(comptime name: []const u8) !?[]u8 {
    return std.testing.environ.getAlloc(std.testing.allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

/// Required integration inputs skip with a named reason when unavailable.
pub fn required_env(comptime name: []const u8) ![]u8 {
    return (try env(name)) orelse {
        std.log.warn("SQL integration skipped: {s} is unavailable", .{name});
        return error.SkipZigTest;
    };
}

/// Returns a sentinel-terminated environment value owned by the caller.
pub fn required_env_z(comptime name: []const u8) ![:0]u8 {
    const value = try required_env(name);
    defer std.testing.allocator.free(value);
    return std.testing.allocator.dupeZ(u8, value);
}
