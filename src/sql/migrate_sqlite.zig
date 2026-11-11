//! Startup-only SQLite migrations under one exclusive transaction.
const c = @import("sqlite_c");
const sqlite = @import("sqlite.zig");
const migrate = @import("migrate.zig");

/// A migration failure retains its source name without exposing SQL or values.
pub const Failure = struct { name: ?[]const u8 = null };
pub const Error = migrate.MigrationError || sqlite.Error;

/// Applies trusted embedded SQL before `Db.seal`; all history storage is local.
/// Schema changes and history inserts commit together, or roll back together.
pub fn run(db: *sqlite.Db, migrations: []const migrate.Migration, failure: *Failure) Error!usize {
    failure.* = .{};
    _ = try migrate.Plan.init(migrations, &.{});
    if (db.sealed) return error.AlreadyStarted;
    if (db.active_index != null) return error.ConnectionBusy;
    const handle = db.handle orelse return error.ConnectionClosed;
    try exec(handle, "BEGIN EXCLUSIVE");
    errdefer {
        // A failed rollback must quarantine the connection before it is reused.
        if (c.sqlite3_get_autocommit(handle) == 0) exec(handle, "ROLLBACK") catch db.deinit();
    }
    db.begin_bounded_work();
    defer db.end_bounded_work();
    try exec(handle, "CREATE TABLE IF NOT EXISTS uwz_schema_migrations(id INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL)");
    var history: [migrate.max_migrations]migrate.Applied = undefined;
    var names: [migrate.max_migrations][migrate.max_name_bytes]u8 = undefined;
    const count = try read_history(handle, &history, &names);
    var plan = migrate.Plan.init(migrations, history[0..count]) catch |err| {
        failure.name = migrate.mismatch_name(migrations, history[0..count]);
        return err;
    };
    var applied: usize = 0;
    while (plan.next()) |migration| {
        failure.name = migration.name;
        try apply_one(handle, migration);
        applied += 1;
    }
    try exec(handle, "COMMIT");
    failure.name = null;
    return applied;
}

fn apply_one(handle: *c.sqlite3, migration: *const migrate.Migration) Error!void {
    var sql_buffer: [migrate.max_sql_bytes + 1]u8 = undefined;
    @memcpy(sql_buffer[0..migration.sql.len], migration.sql);
    sql_buffer[migration.sql.len] = 0;
    try check(c.sqlite3_set_authorizer(handle, protect_transaction, null));
    const status = c.sqlite3_exec(handle, sql_buffer[0..migration.sql.len :0].ptr, null, null, null);
    try check(c.sqlite3_set_authorizer(handle, null, null));
    try check(status);
    if (c.sqlite3_get_autocommit(handle) != 0) return error.MigrationFailed;

    const statement = try prepare(handle, "INSERT INTO uwz_schema_migrations(id, name, checksum) VALUES(?1, ?2, ?3)");
    // The step result is checked below; finalize only releases its storage.
    defer _ = c.sqlite3_finalize(statement);
    var checksum: [64]u8 = undefined;
    migrate.encode_checksum(migration.checksum, &checksum);
    try check(c.sqlite3_bind_int64(statement, 1, @intCast(migration.id)));
    try check(c.sqlite3_bind_text(statement, 2, migration.name.ptr, @intCast(migration.name.len), null));
    try check(c.sqlite3_bind_text(statement, 3, &checksum, checksum.len, null));
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.MigrationFailed;
}

fn protect_transaction(_: ?*anyopaque, action: c_int, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    // Embedded scripts may contain multiple statements, but cannot escape the
    // transaction that makes their schema and checksum changes atomic.
    return if (action == c.SQLITE_TRANSACTION or action == c.SQLITE_SAVEPOINT) c.SQLITE_DENY else c.SQLITE_OK;
}

fn read_history(handle: *c.sqlite3, history: []migrate.Applied, names: [][migrate.max_name_bytes]u8) Error!usize {
    const statement = try prepare(handle, "SELECT id, name, checksum FROM uwz_schema_migrations ORDER BY id");
    // Every sqlite3_step result is handled; finalization is cleanup only.
    defer _ = c.sqlite3_finalize(statement);
    var count: usize = 0;
    while (true) {
        const status = c.sqlite3_step(statement);
        if (status == c.SQLITE_DONE) return count;
        try check(status);
        if (count == history.len) return error.TooManyMigrations;
        if (c.sqlite3_column_type(statement, 0) != c.SQLITE_INTEGER or
            c.sqlite3_column_type(statement, 1) != c.SQLITE_TEXT or
            c.sqlite3_column_type(statement, 2) != c.SQLITE_TEXT) return error.HistoryMismatch;
        const id = c.sqlite3_column_int64(statement, 0);
        if (id <= 0) return error.HistoryMismatch;
        const name = try text(statement, 1);
        const checksum = try text(statement, 2);
        if (name.len == 0 or name.len > migrate.max_name_bytes) return error.InvalidName;
        @memcpy(names[count][0..name.len], name);
        history[count] = .{
            .id = @intCast(id),
            .name = names[count][0..name.len],
            .checksum = try migrate.parse_checksum(checksum),
        };
        count += 1;
    }
}

fn text(statement: *c.sqlite3_stmt, column: c_int) Error![]const u8 {
    const bytes = c.sqlite3_column_bytes(statement, column);
    if (bytes < 0) return error.HistoryMismatch;
    const pointer = c.sqlite3_column_text(statement, column) orelse return error.HistoryMismatch;
    return pointer[0..@intCast(bytes)];
}

fn prepare(handle: *c.sqlite3, sql: [:0]const u8) Error!*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v2(handle, sql.ptr, @intCast(sql.len), &statement, null));
    return statement orelse error.MigrationFailed;
}

fn exec(handle: *c.sqlite3, sql: [:0]const u8) Error!void {
    try check(c.sqlite3_exec(handle, sql.ptr, null, null, null));
}

fn check(status: c_int) Error!void {
    return switch (status & 0xff) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SqliteBusy,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_INTERRUPT => error.QueryTimeout,
        else => error.MigrationFailed,
    };
}
