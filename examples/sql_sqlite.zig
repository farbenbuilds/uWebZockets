//! Local single-worker SQLite CRUD with startup-prepared, sealed statements.
const std = @import("std");
const uz = @import("uWebZockets");
const configuration = @import("sql_config.zig");
const log = std.log.scoped(.sqlite_example);
const App = uz.ConfiguredAppWithTimeout(64, 1024, 16 * 1024, 120_000);

const Context = struct {
    db: uz.sql.sqlite.Db,
    output: [256]u8 = undefined,

    fn handler(context: *anyopaque, request: *uz.Request, response: *uz.Response) void {
        const self: *Context = @ptrCast(@alignCast(context));
        self.dispatch(request, response) catch |err| {
            log.debug("SQLite example operation failed: {s}", .{@errorName(err)});
            response.end("503 Service Unavailable", "SQLite operation failed") catch |write_error| {
                log.debug("SQLite example response failed: {s}", .{@errorName(write_error)});
            };
        };
    }

    fn dispatch(self: *Context, request: *uz.Request, response: *uz.Response) !void {
        const raw_id = request.get_param("id") orelse {
            try response.end("400 Bad Request", "A positive integer id is required");
            return;
        };
        const id = std.fmt.parseInt(i64, raw_id, 10) catch {
            try response.end("400 Bad Request", "A positive integer id is required");
            return;
        };
        if (id <= 0) {
            try response.end("400 Bad Request", "A positive integer id is required");
            return;
        }
        const parameters = [_]uz.sql.Param{.{ .value = .{ .int8 = id } }};
        if (std.mem.eql(u8, request.method, "DELETE")) {
            try self.db.exec(3, &parameters);
            try response.end("204 No Content", "");
            return;
        }
        const statement: usize = if (std.mem.eql(u8, request.method, "PUT")) 2 else if (std.mem.eql(u8, request.method, "POST")) 1 else 0;
        var rows = try self.db.query(statement, &parameters);
        defer rows.deinit();
        const row = (try rows.next()) orelse {
            try response.end("404 Not Found", "No such item");
            return;
        };
        const value = try row.get(i64, 1);
        const body = try std.fmt.bufPrint(&self.output, "{{\"id\":{d},\"value\":{d}}}", .{ try row.get(i64, 0), value });
        try response.end_with_headers("200 OK", "Content-Type: application/json\r\n", body);
    }
};

pub fn main(init: std.process.Init) !void {
    var statements: [8]uz.sql.sqlite.Prepared = undefined;
    var lookaside: [128 * 1024]u8 align(8) = undefined;
    const path = try init.arena.allocator().dupeZ(u8, init.environ_map.get("UWZ_SQLITE_PATH") orelse ":memory:");
    var context = Context{ .db = try uz.sql.sqlite.Db.init(.{ .path = path, .wal = !std.mem.eql(u8, path, ":memory:"), .busy_timeout_ms = 0 }, &statements, &lookaside) };
    defer context.db.deinit();
    try context.db.prepare(4, "CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)");
    try context.db.exec(4, &.{});
    try context.db.prepare(0, "SELECT id,value FROM item WHERE id=?1");
    try context.db.prepare(1, "INSERT INTO item(id,value) VALUES(?1,0) RETURNING id,value");
    try context.db.prepare(2, "UPDATE item SET value=value+1 WHERE id=?1 RETURNING id,value");
    try context.db.prepare(3, "DELETE FROM item WHERE id=?1");
    context.db.seal();

    var app = try App.init(init.io);
    defer app.deinit();
    _ = try app.route_context(.get, "/items/:id", &context, Context.handler);
    _ = try app.route_context(.post, "/items/:id", &context, Context.handler);
    _ = try app.route_context(.put, "/items/:id", &context, Context.handler);
    _ = try app.route_context(.delete, "/items/:id", &context, Context.handler);
    try app.listen("127.0.0.1", try configuration.http_port(init));
    try app.catch_shutdown_signals();
    try app.run();
}
