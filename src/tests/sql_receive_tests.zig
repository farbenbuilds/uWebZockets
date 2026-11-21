const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const support = @import("test_support");
const sql = support.sql;

const description = "\x00\x01number\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17" ++
    "\x00\x04\xff\xff\xff\xff\x00\x01";
const row_42 = "\x00\x01\x00\x00\x00\x04\x00\x00\x00\x2a";

/// A peer emits complete protocol bytes independently of the client parser.
const Packet = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    fn add(self: *Packet, tag: u8, payload: []const u8) !void {
        if (payload.len + 5 > self.bytes.len - self.len) return error.PacketOverflow;
        const out = self.bytes[self.len..][0 .. payload.len + 5];
        out[0] = tag;
        std.mem.writeInt(u32, out[1..5], @intCast(payload.len + 4), .big);
        @memcpy(out[5..], payload);
        self.len += out.len;
    }

    fn result(self: *Packet) !void {
        try self.add('1', "");
        try self.add('2', "");
        try self.add('T', description);
        try self.add('D', row_42);
        try self.add('C', "SELECT 1\x00");
        try self.add('Z', "I");
    }
};

/// Real completions exercise receive ownership without exposing parser hooks.
const Fixture = struct {
    loop: support.loop.Loop = undefined,
    scheduler: support.timer.Scheduler = undefined,
    listener: support.tcp.TcpServer = undefined,
    peer: ?xev.TCP = null,
    connection: sql.connection.Connection = .{},
    receive: [1024]u8 = undefined,
    response: [2048]u8 = undefined,
    transmit: [128 * 1024]u8 = undefined,
    query: sql.Query = undefined,
    ready_calls: usize = 0,
    complete_calls: usize = 0,
    closed_calls: usize = 0,
    received: usize = 0,
    failure: ?sql.RuntimeError = null,
    integer: i32 = 0,
    rows: usize = 0,
    result_count: usize = 0,
    column_name: [32]u8 = undefined,
    column_name_len: usize = 0,
    iterate: bool = true,
    poison_input: bool = false,
    reenter: bool = false,
    small_window: bool = false,
    callback_tail: [4]u8 = undefined,
    callback_tail_len: usize = 0,

    fn init(self: *Fixture) !void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
        {
            self.loop = try support.loop.init();
            errdefer support.loop.deinit(&self.loop);
            self.scheduler = try support.timer.Scheduler.init(std.testing.io);
            errdefer self.scheduler.deinit();
            self.listener = try support.tcp.init_server("127.0.0.1", 0, accept, self);
        }
        self.scheduler.start(&self.loop);
        errdefer self.deinit();
        if (self.small_window) {
            const size: c_int = 2048;
            try std.posix.setsockopt(xev.tcp_fd(self.listener.listener), std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&size));
        }
        self.connection = .{ .receive = &self.receive, .response = &self.response, .transmit = &self.transmit };
        support.tcp.accept_start(&self.listener, &self.loop);
        try self.connection.start(.{
            .loop = &self.loop,
            .scheduler = &self.scheduler,
            .io = std.testing.io,
            .config = .{
                .port = try support.tcp.listener_port(&self.listener),
                .user = "fixture",
                .database = "fixture",
                .allow_plaintext = true,
                .limits = .{ .max_message_bytes = 1024, .max_response_bytes = 2048 },
            },
            .index = 0,
            .context = self,
            .ready = ready,
            .closed = closed,
            .complete = complete,
        });
        const deadline = self.scheduler.current_time_ms() + 2000;
        while (self.peer == null or self.connection.phase != .authenticating or self.connection.write_active) {
            try self.step(deadline);
        }
        support.tcp.close_server(&self.listener, &self.loop);
        var startup: Packet = .{};
        try startup.add('R', "\x00\x00\x00\x00");
        try startup.add('Z', "I");
        try self.send_bytes(startup.bytes[0..startup.len]);
        while (self.ready_calls == 0) try self.step(deadline);
    }

    fn deinit(self: *Fixture) void {
        self.connection.stop(error.ConnectionClosed);
        self.scheduler.stop(&self.loop);
        support.tcp.close_server(&self.listener, &self.loop);
        self.loop.xev_loop.run(.until_done) catch @panic("SQL receive fixture did not drain");
        support.tcp.deinit_server(&self.listener);
        if (self.peer) |peer| support.tcp.close_socket(xev.tcp_fd(peer));
        self.scheduler.deinit();
        support.loop.deinit(&self.loop);
    }

    fn step(self: *Fixture, deadline: u64) !void {
        if (self.scheduler.current_time_ms() >= deadline) return error.ReceiveFixtureTimeout;
        try self.loop.xev_loop.run(.once);
    }

    fn begin(self: *Fixture) !void {
        self.received = 0;
        self.query = .{ .statement = .{ .name = "", .sql = "SELECT 42" }, .context = self, .callback = unused_query_callback };
        try self.connection.execute(&self.query);
        const deadline = self.scheduler.current_time_ms() + 2000;
        while (self.connection.write_active) try self.step(deadline);
    }

    fn send_bytes(self: *Fixture, bytes: []const u8) !void {
        const sent = std.c.send(xev.tcp_fd(self.peer.?), bytes.ptr, bytes.len, 0);
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), sent);
    }

    fn send(self: *Fixture, bytes: []const u8) !void {
        try self.send_bytes(bytes);
        self.received += bytes.len;
        const deadline = self.scheduler.current_time_ms() + 2000;
        while (self.connection.phase != .dormant and self.connection.phase != .closing and
            self.connection.response_bytes + self.connection.receive_len < self.received)
        {
            try self.step(deadline);
        }
        while (self.connection.phase == .closing) try self.step(deadline);
    }

    fn accept(socket: xev.TCP, context: ?*anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.peer == null);
        self.peer = socket;
    }

    fn ready(context: *anyopaque, _: usize) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.ready_calls += 1;
    }

    fn closed(context: *anyopaque, _: usize, failure: sql.RuntimeError) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.closed_calls += 1;
        self.failure = failure;
    }

    fn complete(context: *anyopaque, _: usize, outcome: sql.QueryOutcome) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.complete_calls += 1;
        const result = switch (outcome) {
            .failure => |failure| {
                self.failure = failure;
                return;
            },
            .success => |result| result,
        };
        self.result_count = result.results.len;
        self.callback_tail_len = self.connection.receive_len;
        if (self.callback_tail_len == self.callback_tail.len) @memcpy(&self.callback_tail, self.receive[0..self.callback_tail.len]);
        if (!self.iterate) return;
        if (self.poison_input) {
            @memset(&self.connection.read_buffer, 0xa5);
            @memset(&self.receive, 0x5a);
        }
        var rows = result.rows;
        if (rows.columns.len > 0) {
            const name = rows.columns[0].name;
            std.debug.assert(name.len <= self.column_name.len);
            @memcpy(self.column_name[0..name.len], name);
            self.column_name_len = name.len;
        }
        while (rows.next() catch @panic("SQL receive fixture got invalid retained rows")) |row| {
            self.integer = row.get(i32, 0) catch @panic("SQL receive fixture got wrong integer");
            self.rows += 1;
        }
        if (self.reenter) {
            self.reenter = false;
            self.connection.execute(&self.query) catch @panic("SQL receive fixture reentry failed");
        }
    }

    // Connection tests observe its owner callback, without the higher-level Db adapter.
    fn unused_query_callback(_: *anyopaque, _: sql.QueryOutcome) void {}
};

test "sql receive: complete frames retain rows and metadata after input reuse" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.poison_input = true;
    try fixture.begin();
    var packet: Packet = .{};
    try packet.result();
    try fixture.send(packet.bytes[0..packet.len]);
    try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.rows);
    try std.testing.expectEqual(@as(i32, 42), fixture.integer);
    try std.testing.expectEqualStrings("number", fixture.column_name[0..fixture.column_name_len]);
    try std.testing.expectEqual(packet.len, fixture.connection.response_bytes);
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.receive_len);
}

test "sql receive: every header and row payload split matches complete input" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var packet: Packet = .{};
    try packet.result();
    for (1..packet.len) |split| {
        try fixture.begin();
        try fixture.send(packet.bytes[0..split]);
        try std.testing.expectEqual(split - 1, fixture.complete_calls);
        try fixture.send(packet.bytes[split..packet.len]);
        try std.testing.expectEqual(split, fixture.complete_calls);
        try std.testing.expectEqual(@as(i32, 42), fixture.integer);
        try std.testing.expectEqual(@as(usize, 0), fixture.connection.receive_len);
        try std.testing.expectEqual(packet.len, fixture.connection.response_bytes);
    }
}

test "sql receive: metadata consumes the exact whole-response byte budget" {
    var packet: Packet = .{};
    try packet.result();
    for ([_]usize{ packet.len, packet.len - 1 }) |cap| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.connection.options.config.limits.max_response_bytes = cap;
        try fixture.begin();
        try fixture.send(packet.bytes[0..packet.len]);
        if (cap == packet.len) {
            try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
            try std.testing.expectEqual(@as(?sql.RuntimeError, null), fixture.failure);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
        try std.testing.expectEqual(@as(usize, 1), fixture.closed_calls);
        try std.testing.expectEqual(error.ResponseTooLarge, fixture.failure.?);
    }
}

test "sql receive: malformed rows fail before a noniterating callback" {
    const malformed = [_][]const u8{
        "\x00\x02",
        "\x00\x01\xff\xff\xff\xfe",
        "\x00\x01\x00\x00\x00\x04\x00",
        row_42 ++ "\x00",
    };
    const failures = [_]sql.RuntimeError{ error.TypeMismatch, error.InvalidMessage, error.TruncatedMessage, error.InvalidMessage };
    for (malformed, failures) |payload, failure| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.iterate = false;
        try fixture.begin();
        var packet: Packet = .{};
        try packet.add('1', "");
        try packet.add('2', "");
        try packet.add('T', description);
        try packet.add('D', payload);
        try packet.add('C', "SELECT 1\x00");
        try packet.add('Z', "I");
        try fixture.send(packet.bytes[0..packet.len]);
        try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
        try std.testing.expectEqual(@as(usize, 1), fixture.closed_calls);
        try std.testing.expectEqual(failure, fixture.failure.?);
    }
}

test "sql receive: invalid ready status cannot complete a query" {
    const statuses = [_][]const u8{ "", "X", "II" };
    for (statuses) |status| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.iterate = false;
        try fixture.begin();
        var packet: Packet = .{};
        try packet.add('Z', status);
        try fixture.send(packet.bytes[0..packet.len]);
        try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
        try std.testing.expectEqual(error.ProtocolError, fixture.failure.?);
    }
}

test "sql receive: a fragmented invalid field fails without row iteration" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.iterate = false;
    try fixture.begin();
    var packet: Packet = .{};
    try packet.add('1', "");
    try packet.add('2', "");
    try packet.add('T', description);
    try packet.add('D', "\x00\x01\xff\xff\xff\xfe");
    const split = packet.len - 2;
    try packet.add('C', "SELECT 1\x00");
    try packet.add('Z', "I");
    try fixture.send(packet.bytes[0..split]);
    try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.closed_calls);
    try fixture.send(packet.bytes[split..packet.len]);
    try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
    try std.testing.expectEqual(error.InvalidMessage, fixture.failure.?);
}

test "sql receive: oversized reads preserve receive slab frame capacity" {
    for ([_]usize{ 16, 32 }) |capacity| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        fixture.connection.receive = fixture.receive[0..capacity];
        try fixture.begin();
        var packet: Packet = .{};
        try packet.result();
        try fixture.send(packet.bytes[0..packet.len]);
        if (capacity == 32) {
            try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
            try std.testing.expectEqual(@as(i32, 42), fixture.integer);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
        try std.testing.expectEqual(error.MessageTooLarge, fixture.failure.?);
    }
}

test "sql receive: server failure waits for Sync and permits the next query" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    var packet: Packet = .{};
    try packet.add('E', "\x00");
    try fixture.send(packet.bytes[0..packet.len]);
    try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
    packet = .{};
    try packet.add('Z', "I");
    try fixture.send(packet.bytes[0..packet.len]);
    try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
    try std.testing.expectEqual(error.ServerError, fixture.failure.?);
    fixture.failure = null;
    try fixture.begin();
    packet = .{};
    try packet.result();
    try fixture.send(packet.bytes[0..packet.len]);
    try std.testing.expectEqual(@as(usize, 2), fixture.complete_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.rows);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), fixture.failure);
}

test "sql receive: incomplete async tail is staged before query callback reentry" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    fixture.reenter = true;
    var result: Packet = .{};
    try result.result();
    var notice: Packet = .{};
    try notice.add('N', "trace\x00");
    var first: [2048]u8 = undefined;
    @memcpy(first[0..result.len], result.bytes[0..result.len]);
    @memcpy(first[result.len..][0..4], notice.bytes[0..4]);
    try fixture.send_bytes(first[0 .. result.len + 4]);
    const deadline = fixture.scheduler.current_time_ms() + 2000;
    while (fixture.complete_calls == 0 or fixture.connection.write_active) try fixture.step(deadline);
    try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
    try std.testing.expectEqual(@as(usize, 4), fixture.callback_tail_len);
    try std.testing.expectEqualSlices(u8, notice.bytes[0..4], &fixture.callback_tail);
    try std.testing.expectEqual(sql.connection.Phase.querying, fixture.connection.phase);
    var second: [2048]u8 = undefined;
    const tail = notice.bytes[4..notice.len];
    @memcpy(second[0..tail.len], tail);
    @memcpy(second[tail.len..][0..result.len], result.bytes[0..result.len]);
    fixture.received = 4;
    try fixture.send(second[0 .. tail.len + result.len]);
    try std.testing.expectEqual(@as(usize, 2), fixture.complete_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.rows);
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.receive_len);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), fixture.failure);
}

test "sql receive: ReadyForQuery cannot complete before the socket write drains" {
    var fixture: Fixture = .{ .small_window = true };
    try fixture.init();
    defer fixture.deinit();
    const size: c_int = 2048;
    try std.posix.setsockopt(xev.tcp_fd(fixture.connection.socket), std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&size));
    const sql_text = "x" ** 4095;
    const operation: sql.BoundStatement = .{ .statement = .{ .name = "", .sql = sql_text } };
    const operations = [_]sql.BoundStatement{operation} ** sql.runtime_types.max_batch_statements;
    fixture.query = .{
        .statement = .{ .name = "", .sql = "" },
        .batch = &operations,
        .context = &fixture,
        .callback = Fixture.unused_query_callback,
    };
    try fixture.connection.execute(&fixture.query);
    var packet: Packet = .{};
    for (operations) |_| {
        try packet.add('1', "");
        try packet.add('2', "");
        try packet.add('C', "SELECT 0\x00");
    }
    try packet.add('Z', "I");
    try fixture.send(packet.bytes[0..packet.len]);
    try std.testing.expect(fixture.connection.ready_pending);
    try std.testing.expect(fixture.connection.write_active);
    try std.testing.expectEqual(@as(usize, 0), fixture.complete_calls);
    const deadline = fixture.scheduler.current_time_ms() + 2000;
    var drain: [8192]u8 = undefined;
    while (fixture.complete_calls == 0) {
        var poll = [_]std.posix.pollfd{.{ .fd = xev.tcp_fd(fixture.peer.?), .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&poll, 0) > 0) {
            const count = std.c.recv(xev.tcp_fd(fixture.peer.?), &drain, drain.len, 0);
            try std.testing.expect(count > 0);
        }
        try fixture.step(deadline);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.complete_calls);
    try std.testing.expectEqual(operations.len, fixture.result_count);
    try std.testing.expectEqual(@as(?sql.RuntimeError, null), fixture.failure);
}
