//! Startup-only SQL configuration; credentials are never formatted or logged.
const std = @import("std");
const uz = @import("uWebZockets");

pub fn load(init: std.process.Init) !uz.sql.Config {
    const environment = init.environ_map;
    const host = environment.get("PGHOST") orelse "127.0.0.1";
    const port = try parse_port(environment.get("PGPORT") orelse "5432");
    const plaintext = std.mem.eql(u8, environment.get("UWZ_SQL_ALLOW_PLAINTEXT") orelse "", "1");
    const ca_path = environment.get("PGSSLROOTCERT");
    if (ca_path == null and !plaintext) return error.SqlCaRequired;
    return .{
        .host = host,
        .port = port,
        .user = environment.get("PGUSER") orelse "postgres",
        .database = environment.get("PGDATABASE") orelse "postgres",
        .password = environment.get("PGPASSWORD") orelse "",
        .allow_plaintext = plaintext,
        .tls = if (ca_path) |path| .{
            .ca_path = try init.arena.allocator().dupeZ(u8, path),
            .server_name = environment.get("PGSSLSERVERNAME") orelse host,
        } else null,
        .limits = .{ .max_rows = 512, .max_message_bytes = 64 * 1024, .max_response_bytes = 128 * 1024 },
    };
}

pub fn http_port(init: std.process.Init) !u16 {
    return parse_port(init.environ_map.get("UWZ_HTTP_PORT") orelse "3000");
}

fn parse_port(raw: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}
