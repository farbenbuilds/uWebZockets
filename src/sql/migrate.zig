//! Pure, bounded migration history validation. Effects and locks belong to the
//! PostgreSQL and SQLite runners; a plan never changes database state.

const std = @import("std");

pub const max_migrations = 256;
pub const max_name_bytes = 128;
pub const max_sql_bytes = 64 * 1024;

/// Stable failures independent of database diagnostics or credentials.
pub const MigrationError = error{
    TooManyMigrations,
    InvalidOrder,
    InvalidName,
    InvalidSql,
    InvalidChecksum,
    ChecksumMismatch,
    HistoryMismatch,
    BufferTooSmall,
};

/// Embedded source with an immutable SHA-256 checksum of its SQL bytes.
pub const Migration = struct {
    id: u64,
    name: []const u8,
    sql: []const u8,
    checksum: [32]u8,
};

/// Borrowed history row read while holding the backend migration lock.
pub const Applied = struct {
    id: u64,
    name: []const u8,
    checksum: [32]u8,
};

/// A validated suffix of pending migrations; source storage stays borrowed.
pub const Plan = struct {
    migrations: []const Migration,
    cursor: usize,

    pub fn init(migrations: []const Migration, applied: []const Applied) MigrationError!Plan {
        if (migrations.len > max_migrations) return error.TooManyMigrations;
        if (applied.len > migrations.len) return error.HistoryMismatch;
        var previous: u64 = 0;
        for (migrations) |migration| {
            if (migration.id <= previous or migration.id > std.math.maxInt(i64)) return error.InvalidOrder;
            previous = migration.id;
            try validate_name(migration.name);
            if (migration.sql.len == 0 or migration.sql.len > max_sql_bytes) return error.InvalidSql;
            if (std.mem.indexOfScalar(u8, migration.sql, 0) != null) return error.InvalidSql;
            if (!std.mem.eql(u8, &checksum(migration.sql), &migration.checksum)) return error.ChecksumMismatch;
        }
        for (applied, migrations[0..applied.len]) |history, migration| {
            if (history.id != migration.id) return error.HistoryMismatch;
            if (!std.mem.eql(u8, history.name, migration.name)) return error.HistoryMismatch;
            if (!std.mem.eql(u8, &history.checksum, &migration.checksum)) return error.ChecksumMismatch;
        }
        return .{ .migrations = migrations, .cursor = applied.len };
    }

    /// Advances only this caller-owned plan, without performing database I/O.
    pub fn next(self: *Plan) ?*const Migration {
        if (self.cursor == self.migrations.len) return null;
        const migration = &self.migrations[self.cursor];
        self.cursor += 1;
        return migration;
    }
};

/// Constructs a migration from `@embedFile` bytes or a compile-time SQL string.
pub fn embedded(comptime id: u64, comptime name: []const u8, comptime sql: []const u8) Migration {
    @setEvalBranchQuota(10_000 + sql.len * 100);
    comptime {
        if (id == 0 or id > std.math.maxInt(i64)) @compileError("migration id must fit positive SQL BIGINT");
        validate_name(name) catch @compileError("migration name must use ASCII letters, digits, underscore or dash");
        if (sql.len == 0 or sql.len > max_sql_bytes) @compileError("migration SQL exceeds its bound or is empty");
        if (std.mem.indexOfScalar(u8, sql, 0) != null) @compileError("migration SQL contains NUL");
    }
    return .{ .id = id, .name = name, .sql = sql, .checksum = comptime checksum(sql) };
}

/// Identifies the first mismatch without including SQL or parameter values.
pub fn mismatch_name(migrations: []const Migration, applied: []const Applied) ?[]const u8 {
    for (migrations[0..@min(migrations.len, applied.len)], applied[0..@min(migrations.len, applied.len)]) |migration, history| {
        if (migration.id != history.id or !std.mem.eql(u8, migration.name, history.name) or
            !std.mem.eql(u8, &migration.checksum, &history.checksum)) return migration.name;
    }
    for (migrations) |migration| {
        if (!std.mem.eql(u8, &checksum(migration.sql), &migration.checksum)) return migration.name;
    }
    return null;
}

pub fn checksum(sql: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sql, &digest, .{});
    return digest;
}

/// SPI execution forbids transaction commands inside the outer transaction.
/// This trusted migration-only wrapper rejects either delimiter in the input.
pub fn pg_transaction_script(sql: []const u8, buffer: []u8) MigrationError![]const u8 {
    const prefix = "DO $uwz_body$ BEGIN EXECUTE $uwz_sql$";
    const suffix = "$uwz_sql$; END $uwz_body$";
    if (sql.len == 0 or sql.len > max_sql_bytes) return error.InvalidSql;
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSql;
    if (std.mem.indexOf(u8, sql, "$uwz_body$") != null or std.mem.indexOf(u8, sql, "$uwz_sql$") != null) return error.InvalidSql;
    const length = prefix.len + sql.len + suffix.len;
    if (length > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..sql.len], sql);
    @memcpy(buffer[prefix.len + sql.len ..][0..suffix.len], suffix);
    return buffer[0..length];
}

pub fn encode_checksum(digest: [32]u8, output: *[64]u8) void {
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 15];
    }
}

pub fn parse_checksum(input: []const u8) MigrationError![32]u8 {
    if (input.len != 64) return error.InvalidChecksum;
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, index| {
        const high = try hex_digit(input[index * 2]);
        const low = try hex_digit(input[index * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return digest;
}

fn hex_digit(byte: u8) MigrationError!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidChecksum,
    };
}

fn validate_name(name: []const u8) MigrationError!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidName;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return error.InvalidName,
    };
}
