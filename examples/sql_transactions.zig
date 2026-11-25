//! Apply examples/sql/world.sql. POST /transaction/:id demonstrates an outbox.
const std = @import("std");
const uz = @import("uWebZockets");
const configuration = @import("sql_config.zig");
const log = std.log.scoped(.transaction_example);
const capacity = 16;
const App = uz.ConfiguredAppWithTimeout(capacity, 1024, 16 * 1024, 120_000);
const Phase = enum { begin, update, savepoint, tentative, rollback_to, release_savepoint, enqueue, commit, rollback };

const Slot = struct {
    owner: *Context = undefined,
    token: uz.AsyncResponse = undefined,
    transaction: uz.sql.Tx = undefined,
    request: uz.sql.Query = undefined,
    parameter: [1]uz.sql.Param = undefined,
    savepoint: uz.sql.Savepoint = undefined,
    phase: Phase = .begin,
    active: bool = false,
};

const Context = struct {
    sql: uz.sql.Sql,
    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

    fn handler(context: *anyopaque, request: *uz.Request, token: uz.AsyncResponse) void {
        const self: *Context = @ptrCast(@alignCast(context));
        const id = std.fmt.parseInt(i32, request.get_param("id") orelse "", 10) catch {
            complete(token, "400 Bad Request", "Invalid World id");
            return;
        };
        if (id < 1 or id > 10000) {
            complete(token, "400 Bad Request", "Invalid World id");
            return;
        }
        const slot = self.acquire() orelse {
            complete(token, "503 Service Unavailable", "Transaction capacity unavailable");
            return;
        };
        const lease = self.sql.db.acquire() catch {
            complete(token, "503 Service Unavailable", "SQL capacity unavailable");
            return;
        };
        slot.transaction = uz.sql.Tx.init(&self.sql.db, lease) catch {
            self.sql.db.discard(lease) catch |err| log.err("transaction lease discard failed: {s}", .{@errorName(err)});
            complete(token, "503 Service Unavailable", "SQL connection unavailable");
            return;
        };
        slot.active = true;
        slot.owner = self;
        slot.token = token;
        slot.phase = .begin;
        slot.parameter[0] = .{ .value = .{ .int4 = id } };
        slot.request = .{
            .statement = .{ .name = "", .sql = "BEGIN" },
            .deadline_ms = self.sql.db.scheduler.?.current_time_ms() +| 10_000,
            .context = slot,
            .callback = on_query,
        };
        slot.transaction.begin(&slot.request) catch abort(slot);
    }

    fn acquire(self: *Context) ?*Slot {
        for (&self.slots) |*slot| {
            if (!slot.active) return slot;
        }
        return null;
    }

    fn on_query(context: *anyopaque, outcome: uz.sql.QueryOutcome) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        if (!slot.token.is_pending()) {
            abort(slot);
            return;
        }
        if (outcome == .failure) {
            if (slot.phase == .rollback or slot.transaction.state == .closed) {
                abort(slot);
                return;
            }
            slot.phase = .rollback;
            slot.request.deadline_ms = slot.owner.sql.db.scheduler.?.current_time_ms() +| 2000;
            slot.transaction.rollback(&slot.request) catch abort(slot);
            return;
        }
        advance(slot) catch abort(slot);
    }

    fn advance(slot: *Slot) uz.sql.RuntimeError!void {
        switch (slot.phase) {
            .begin => {
                slot.phase = .update;
                slot.request.statement = .{ .name = "tx_world_update", .sql = "UPDATE World SET randomnumber=1+(randomnumber%10000) WHERE id=$1", .param_oids = &.{23} };
                slot.request.params = &slot.parameter;
                try slot.transaction.query(&slot.request);
            },
            .update => {
                slot.phase = .savepoint;
                slot.savepoint = try slot.transaction.savepoint(&slot.request);
            },
            .savepoint => {
                slot.phase = .tentative;
                try enqueue(slot);
            },
            .tentative => {
                slot.phase = .rollback_to;
                try slot.transaction.rollback_to(&slot.request, slot.savepoint);
            },
            .rollback_to => {
                slot.phase = .release_savepoint;
                try slot.transaction.release_savepoint(&slot.request, slot.savepoint);
            },
            .release_savepoint => {
                slot.phase = .enqueue;
                try enqueue(slot);
            },
            .enqueue => {
                slot.phase = .commit;
                try slot.transaction.commit(&slot.request);
            },
            .commit => {
                complete(slot.token, "200 OK", "World update and one outbox entry committed");
                slot.active = false;
            },
            .rollback => {
                complete(slot.token, "503 Service Unavailable", "Transaction rolled back");
                slot.active = false;
            },
        }
    }

    fn enqueue(slot: *Slot) uz.sql.RuntimeError!void {
        slot.request.statement = .{ .name = "tx_outbox", .sql = "INSERT INTO example_jobs(world_id,kind) VALUES($1,'world_updated')", .param_oids = &.{23} };
        slot.request.params = &slot.parameter;
        try slot.transaction.query(&slot.request);
    }

    fn abort(slot: *Slot) void {
        slot.transaction.discard() catch |err| log.err("transaction discard failed: {s}", .{@errorName(err)});
        complete(slot.token, "503 Service Unavailable", "Transaction failed; connection discarded");
        slot.active = false;
    }
};

fn complete(token: uz.AsyncResponse, status: []const u8, body: []const u8) void {
    if (!token.is_pending()) return;
    token.complete(status, body) catch |err| log.debug("transaction response failed: {s}", .{@errorName(err)});
}

pub fn main(init: std.process.Init) !void {
    var context = Context{ .sql = try uz.sql.Sql.init(init.gpa, try configuration.load(init)) };
    var app = App.init(init.io) catch |err| {
        context.sql.db.deinit();
        return err;
    };
    app.provide(context.sql.hooks()) catch |err| {
        app.deinit();
        context.sql.db.deinit();
        return err;
    };
    defer app.deinit();
    _ = try app.route_async_context(.post, "/transaction/:id", &context, Context.handler);
    try app.listen("127.0.0.1", try configuration.http_port(init));
    try app.catch_shutdown_signals();
    try app.run();
}
