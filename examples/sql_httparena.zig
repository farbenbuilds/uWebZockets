//! Current HttpArena async-db and delay contracts, using worker-owned SQL.
const std = @import("std");
const uz = @import("uWebZockets");

const log = std.log.scoped(.sql_httparena);
pub const worker_capacity = 32;
pub const pool_connections = 8;
const request_capacity = 128;
const response_bytes = 32 * 1024;
const empty_response = "{\"items\":[],\"count\":0}";

/// GET-only fixture keeps 32K admission without the general-purpose H2 slabs.
pub const http_config: uz.ServerConfig = .{
    .max_connections = 1024,
    .max_ws_message_size = 1024,
    .write_queue_size = 64 * 1024,
    .max_request_line_size = 1024,
    .max_header_size = 4096,
    .max_body_size = 2048,
    .max_h2_header_block_size = 2048,
    .max_h2_body_size = 512,
    .max_h2_response_header_size = 1024,
    .max_h2_response_header_count = 24,
    .enable_dev_log = false,
};

/// Startup configuration borrows environment strings or the startup arena.
pub const Configuration = struct {
    sql: uz.sql.Config,
    max_workers: usize,
};

/// Current profile defaults and the prepared query's integer bounds.
pub const Range = struct { minimum: i32, maximum: i32, limit: i32 };

pub fn query_range(parameters: uz.query.QueryParams) Range {
    return .{
        .minimum = integer(parameters.get("min"), 10),
        .maximum = integer(parameters.get("max"), 50),
        .limit = std.math.clamp(integer(parameters.get("limit"), 50), 1, 50),
    };
}

/// Resolves only numeric hosts and localhost; plaintext stays loopback-only.
pub fn configuration(init: std.process.Init) !Configuration {
    const environment = init.environ_map;
    const url = environment.get("DATABASE_URL") orelse return error.DatabaseUrlRequired;
    const uri = std.Uri.parse(url) catch return error.InvalidDatabaseUrl;
    if (!std.mem.eql(u8, uri.scheme, "postgres") and !std.mem.eql(u8, uri.scheme, "postgresql")) return error.InvalidDatabaseUrl;
    if (uri.query != null or uri.fragment != null) return error.UnsupportedDatabaseUrl;
    const arena = init.arena.allocator();
    const user = try (uri.user orelse return error.InvalidDatabaseUrl).toRawMaybeAlloc(arena);
    const password = if (uri.password) |value| try value.toRawMaybeAlloc(arena) else "";
    const raw_host = try (uri.host orelse return error.InvalidDatabaseUrl).toRawMaybeAlloc(arena);
    const host = numeric_host(raw_host);
    const port = uri.port orelse 5432;
    if (port == 0) return error.InvalidDatabaseUrl;
    const address = std.Io.net.IpAddress.parse(host, port) catch return error.DatabaseNumericHostRequired;
    const raw_path = try uri.path.toRawMaybeAlloc(arena);
    if (raw_path.len < 2 or raw_path[0] != '/') return error.InvalidDatabaseUrl;
    const ca_path = environment.get("PGSSLROOTCERT");
    if (ca_path == null and !loopback(address)) return error.DatabaseTlsRequired;
    const budget = std.fmt.parseInt(usize, environment.get("DATABASE_MAX_CONN") orelse "256", 10) catch return error.InvalidDatabaseBudget;
    if (budget < pool_connections) return error.InvalidDatabaseBudget;
    return .{
        .max_workers = @min(worker_capacity, budget / pool_connections),
        .sql = .{
            .host = host,
            .port = port,
            .user = user,
            .password = password,
            .database = raw_path[1..],
            .connections = pool_connections,
            .allow_plaintext = ca_path == null,
            .tls = if (ca_path) |path| .{
                .ca_path = try arena.dupeZ(u8, path),
                .server_name = environment.get("PGSSLSERVERNAME") orelse tls_server_name(raw_host),
            } else null,
            .write_bytes = 8192,
            .limits = .{ .max_rows = 50, .max_columns = 9, .max_field_bytes = 4096, .max_message_bytes = 64 * 1024, .max_response_bytes = 128 * 1024 },
        },
    };
}

fn numeric_host(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "localhost")) return "127.0.0.1";
    return tls_server_name(host);
}

/// Certificate IP identities exclude URI brackets; DNS names retain their spelling.
pub fn tls_server_name(host: []const u8) []const u8 {
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

/// Standard pool size follows the database budget; overrides are diagnostic.
pub fn worker_count(config: Configuration, override: ?[]const u8) !usize {
    const workers = if (override) |raw| std.fmt.parseInt(usize, raw, 10) catch return error.InvalidWorkerCount else config.max_workers;
    if (workers == 0 or workers > config.max_workers) return error.InvalidWorkerCount;
    return workers;
}

fn loopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |value| value.bytes[0] == 127,
        .ip6 => |value| std.mem.allEqual(u8, value.bytes[0..15], 0) and value.bytes[15] == 1,
    };
}

const Slot = struct {
    owner: *Context = undefined,
    token: uz.AsyncResponse = undefined,
    query: uz.sql.Query = undefined,
    params: [3]uz.sql.Param = undefined,
    output: [response_bytes]u8 = undefined,
    index: usize = 0,
    limit: usize = 50,
    active: bool = false,
};

/// Stable worker-local owner; registration transfers SQL cleanup to the App.
pub const Context = struct {
    sql: uz.sql.Sql,
    slots: [request_capacity]Slot = undefined,
    free: [request_capacity]usize = undefined,
    free_count: usize = request_capacity,
    rendered_queries: u64 = 0,
    empty_fallbacks: u64 = 0,
    rejected_responses: u64 = 0,
    start_failed: bool = false,

    pub fn init(self: *Context, allocator: std.mem.Allocator, config: uz.sql.Config) !void {
        self.* = .{ .sql = try uz.sql.Sql.init(allocator, config) };
        for (&self.slots, 0..) |*slot, index| {
            slot.* = .{ .owner = self, .index = index };
            self.free[index] = index;
        }
    }

    /// HttpArena requires an empty HTTP response when its optional DB is down.
    pub fn hooks(self: *Context) uz.modules.ServiceHooks {
        return .{ .name = "httparena_sql", .context = self, .start = start, .stop = stop, .ready = ready, .deinit = deinit };
    }

    fn start(context: *anyopaque, worker: *const uz.modules.WorkerContext) uz.modules.ServiceError!void {
        const self: *Context = @ptrCast(@alignCast(context));
        const underlying = self.sql.hooks();
        underlying.start(underlying.context, worker) catch |err| {
            if (err == error.InvalidConfiguration or err == error.CapacityExceeded) return err;
            self.start_failed = true;
            log.warn("optional benchmark database startup failed: {}", .{err});
        };
    }

    fn ready(context: *anyopaque) ?[]const u8 {
        const self: *Context = @ptrCast(@alignCast(context));
        if (self.start_failed or self.sql.db.ready() or self.sql.db.startup_failure != null) return null;
        return "optional benchmark database starting";
    }

    fn stop(context: *anyopaque, _: *const uz.modules.WorkerContext) void {
        const self: *Context = @ptrCast(@alignCast(context));
        self.sql.db.stop();
    }

    fn deinit(context: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(context));
        std.debug.assert(self.free_count == request_capacity);
        log.info("benchmark database rendered_queries={d} empty_fallbacks={d} rejected_responses={d}", .{ self.rendered_queries, self.empty_fallbacks, self.rejected_responses });
        self.sql.db.deinit();
    }

    pub fn handler(context: *anyopaque, request: *uz.Request, token: uz.AsyncResponse) void {
        const self: *Context = @ptrCast(@alignCast(context));
        if (!self.sql.db.ready()) {
            complete_empty(self, token);
            return;
        }
        if (self.free_count == 0) {
            reject(self, token, "503 Service Unavailable");
            return;
        }
        const parameters = request.query_params() catch {
            reject(self, token, "400 Bad Request");
            return;
        };
        const range = query_range(parameters);
        self.free_count -= 1;
        const slot = &self.slots[self.free[self.free_count]];
        slot.active = true;
        slot.token = token;
        slot.limit = @intCast(range.limit);
        slot.params = .{
            .{ .value = .{ .int4 = range.minimum } },
            .{ .value = .{ .int4 = range.maximum } },
            .{ .value = .{ .int4 = range.limit } },
        };
        slot.query = .{
            .statement = .{
                .name = "httparena_range",
                .sql = "SELECT id,name,category,price,quantity,active,tags,rating_score,rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
                .param_oids = &.{ 23, 23, 23 },
            },
            .params = &slot.params,
            .context = slot,
            .callback = on_query,
        };
        self.sql.db.query(&slot.query) catch |err| finish_failure(slot, err);
    }
};

fn integer(raw: ?[]const u8, fallback: i32) i32 {
    return std.fmt.parseInt(i32, raw orelse return fallback, 10) catch fallback;
}

fn on_query(context: *anyopaque, outcome: uz.sql.QueryOutcome) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    if (!slot.token.is_pending()) {
        release(slot);
        return;
    }
    const result = switch (outcome) {
        .success => |result| result,
        .failure => |err| {
            finish_failure(slot, err);
            return;
        },
    };
    const body = render(&slot.output, result.rows, slot.limit) catch {
        reject(slot.owner, slot.token, "503 Service Unavailable");
        release(slot);
        return;
    };
    slot.owner.rendered_queries +|= 1;
    complete_json(slot.token, "200 OK", body);
    release(slot);
}

fn finish_failure(slot: *Slot, err: uz.sql.RuntimeError) void {
    switch (err) {
        error.ConnectionFailed, error.ConnectionClosed, error.NotReady, error.Stopped => complete_empty(slot.owner, slot.token),
        else => reject(slot.owner, slot.token, "503 Service Unavailable"),
    }
    release(slot);
}

fn release(slot: *Slot) void {
    std.debug.assert(slot.active);
    slot.active = false;
    const owner = slot.owner;
    owner.free[owner.free_count] = slot.index;
    owner.free_count += 1;
}

fn complete_json(token: uz.AsyncResponse, status: []const u8, body: []const u8) void {
    if (!token.is_pending()) return;
    token.complete_with_headers(status, "Content-Type: application/json\r\n", body) catch |err| {
        log.debug("benchmark database response failed: {}", .{err});
    };
}

fn complete_empty(owner: *Context, token: uz.AsyncResponse) void {
    if (!token.is_pending()) return;
    owner.empty_fallbacks +|= 1;
    complete_json(token, "200 OK", empty_response);
}

fn reject(owner: *Context, token: uz.AsyncResponse, status: []const u8) void {
    if (!token.is_pending()) return;
    owner.rejected_responses +|= 1;
    complete_json(token, status, "{\"error\":\"SQL request unavailable\"}");
}

/// Encodes only current-row borrows into caller-owned fixed response storage.
pub fn render(output: []u8, source: uz.sql.Rows, limit: usize) ![]const u8 {
    var rows = source;
    var writer: std.Io.Writer = .fixed(output);
    var json: std.json.Stringify = .{ .writer = &writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    var count: usize = 0;
    while (try rows.next()) |row| {
        if (count >= limit or row.fields.len != 9) return error.InvalidResult;
        try render_item(&json, row);
        count += 1;
    }
    try json.endArray();
    try json.objectField("count");
    try json.write(count);
    try json.endObject();
    return writer.buffered();
}

fn render_item(json: *std.json.Stringify, row: uz.sql.Row) !void {
    const tags = row.fields[6];
    const encoded = tags.bytes orelse return error.InvalidTags;
    if (tags.oid != 3802 or tags.format != .binary or encoded.len < 3 or encoded[0] != 1) return error.InvalidTags;
    if (!valid_tags(encoded[1..])) return error.InvalidTags;
    try json.beginObject();
    try json.objectField("id");
    try json.write(try row.get(i32, 0));
    try json.objectField("name");
    try json.write(try row.get([]const u8, 1));
    try json.objectField("category");
    try json.write(try row.get([]const u8, 2));
    try json.objectField("price");
    try json.write(try row.get(i32, 3));
    try json.objectField("quantity");
    try json.write(try row.get(i32, 4));
    try json.objectField("active");
    try json.write(try row.get(bool, 5));
    try json.objectField("tags");
    try json.beginWriteRaw();
    try json.writer.writeAll(encoded[1..]);
    json.endWriteRaw();
    try json.objectField("rating");
    try json.beginObject();
    try json.objectField("score");
    try json.write(try row.get(i32, 7));
    try json.objectField("count");
    try json.write(try row.get(i32, 8));
    try json.endObject();
    try json.endObject();
}

fn valid_tags(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    var offset: usize = 0;
    skip_space(bytes, &offset);
    if (offset == bytes.len or bytes[offset] != '[') return false;
    offset += 1;
    skip_space(bytes, &offset);
    if (offset < bytes.len and bytes[offset] == ']') {
        offset += 1;
        skip_space(bytes, &offset);
        return offset == bytes.len;
    }
    while (offset < bytes.len) {
        if (!consume_string(bytes, &offset)) return false;
        skip_space(bytes, &offset);
        if (offset == bytes.len) return false;
        const separator = bytes[offset];
        offset += 1;
        skip_space(bytes, &offset);
        if (separator == ']') return offset == bytes.len;
        if (separator != ',') return false;
    }
    return false;
}

fn consume_string(bytes: []const u8, offset: *usize) bool {
    if (offset.* == bytes.len or bytes[offset.*] != '"') return false;
    offset.* += 1;
    while (offset.* < bytes.len) {
        const byte = bytes[offset.*];
        offset.* += 1;
        if (byte == '"') return true;
        if (byte < 0x20) return false;
        if (byte != '\\') continue;
        if (offset.* == bytes.len) return false;
        const escaped = bytes[offset.*];
        offset.* += 1;
        if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", escaped) != null) continue;
        if (escaped != 'u' or bytes.len - offset.* < 4) return false;
        for (bytes[offset.*..][0..4]) |digit| if (!std.ascii.isHex(digit)) return false;
        offset.* += 4;
    }
    return false;
}

fn skip_space(bytes: []const u8, offset: *usize) void {
    while (offset.* < bytes.len and std.mem.indexOfScalar(u8, " \t\r\n", bytes[offset.*]) != null) offset.* += 1;
}

/// Request-path digits remain borrowed until the generation-checked timer fires.
pub fn delay(request: *uz.Request, token: uz.AsyncResponse) void {
    const raw = request.get_param("ms") orelse "";
    const milliseconds = std.fmt.parseInt(u64, raw, 10) catch {
        complete_delay(token, "400 Bad Request", "Invalid delay");
        return;
    };
    if (raw.len == 0 or std.mem.indexOfNone(u8, raw, "0123456789") != null or milliseconds > 60_000) {
        complete_delay(token, "400 Bad Request", "Invalid delay");
        return;
    }
    var leading: usize = 0;
    while (leading + 1 < raw.len and raw[leading] == '0') leading += 1;
    const body = raw[leading..];
    if (milliseconds == 0) {
        complete_delay(token, "200 OK", body);
        return;
    }
    token.sleep_complete(milliseconds, "200 OK", "Content-Type: text/plain\r\n", body) catch |err| {
        log.debug("benchmark delay scheduling failed: {}", .{err});
        complete_delay(token, "503 Service Unavailable", "Timer unavailable");
    };
}

fn complete_delay(token: uz.AsyncResponse, status: []const u8, body: []const u8) void {
    if (!token.is_pending()) return;
    token.complete_with_headers(status, "Content-Type: text/plain\r\n", body) catch |err| {
        log.debug("benchmark delay response failed: {}", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    const config = try configuration(init);
    const override = init.environ_map.get("UWZ_SQL_WORKERS");
    const workers = try worker_count(config, override);
    if (override != null) log.info("diagnostic SQL worker override={d}; standard workers={d}", .{ workers, config.max_workers });
    log.info("benchmark SQL workers={d} connections={d} connection_slab_bytes_per_worker={d}", .{ workers, workers * pool_connections, try http_config.slab_bytes() });
    const contexts = try init.gpa.alloc(Context, workers);
    defer init.gpa.free(contexts);
    var group = try uz.Server.preset(init.io, http_config)
        .build_cluster_with_worker_count(init.gpa, worker_capacity, workers, .{ .cpu_affinity = false });
    defer group.deinit();
    for (contexts, 0..) |*context, index| {
        try context.init(init.gpa, config.sql);
        const worker = group.worker(index).?;
        worker.provide(context.hooks()) catch |err| {
            context.sql.db.deinit();
            return err;
        };
        _ = try worker.get_async_context("/async-db", context, Context.handler);
        _ = try worker.get_async("/delay/:ms", delay);
    }
    const port = std.fmt.parseInt(u16, init.environ_map.get("UWZ_HTTP_PORT") orelse "8080", 10) catch return error.InvalidPort;
    try group.listen("127.0.0.1", port);
    try group.catch_shutdown_signals();
    try group.run();
}
