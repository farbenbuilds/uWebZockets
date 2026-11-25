//! Explicit, allocation-free SQL values and protocol bounds.

/// Stable SQL failures; backend diagnostics never contain credentials or parameters.
pub const SqlError = error{
    BufferTooSmall,
    InvalidMessage,
    TruncatedMessage,
    MessageTooLarge,
    InvalidString,
    StatementTooLarge,
    TooManyParameters,
    TooManyColumns,
    TooManyRows,
    FieldTooLarge,
    ResponseTooLarge,
    TypeMismatch,
    NullValue,
    ColumnNotFound,
    UnsupportedType,
    InvalidValue,
    NumericTooLarge,
    AuthenticationFailed,
    UnsupportedAuthentication,
    InvalidConfiguration,
    PoolExhausted,
    AcquireTimeout,
    QueryTimeout,
    Canceled,
    ConnectionFailed,
    ConnectionClosed,
    ConnectionBusy,
    ProtocolError,
    ServerError,
    TlsRequired,
    TlsFailed,
    CertificateVerificationFailed,
    NotReady,
    AlreadyStarted,
    InvalidTransaction,
    SavepointLimit,
    StatementCacheFull,
    OutOfMemory,
    SqliteBusy,
    SqliteError,
    SqliteConstraint,
    SQLiteUnavailable,
    MigrationChecksumMismatch,
    MigrationOrder,
    MigrationFailed,
    UnknownStatement,
};

/// Configured bounds apply before accepting or encoding peer-controlled lengths.
pub const Limits = struct {
    max_message_bytes: usize = 1024 * 1024,
    max_statement_bytes: usize = 4096,
    max_parameters: usize = 64,
    max_columns: usize = 64,
    max_rows: usize = 1024,
    max_field_bytes: usize = 64 * 1024,
    max_response_bytes: usize = 1024 * 1024,
};

/// PostgreSQL format code; values are defined by protocol 3.0.
pub const Format = enum(u16) { text = 0, binary = 1 };

/// PostgreSQL's 16-byte UUID representation.
pub const Uuid = struct { bytes: [16]u8 };
/// Microseconds since PostgreSQL's epoch, 2000-01-01 UTC.
pub const Timestamp = struct { microseconds: i64 };
/// Days since PostgreSQL's epoch, 2000-01-01.
pub const Date = struct { days: i32 };
/// Bounded borrowed PostgreSQL base-10000 numeric digits, preserving scale.
pub const Numeric = struct {
    digits: []const u8,
    weight: i16,
    scale: u16,
    sign: NumericSign,
};
/// PostgreSQL numeric special values and signs.
pub const NumericSign = enum(u16) {
    positive = 0x0000,
    negative = 0x4000,
    nan = 0xc000,
    positive_infinity = 0xd000,
    negative_infinity = 0xf000,
};

/// Named SQL types preserve wire distinctions and NULL without reflection.
pub const Value = union(enum) {
    null,
    bool: bool,
    int2: i16,
    int4: i32,
    int8: i64,
    float4: f32,
    float8: f64,
    text: []const u8,
    varchar: []const u8,
    bytea: []const u8,
    timestamp: Timestamp,
    date: Date,
    uuid: Uuid,
    numeric: Numeric,
};

/// One bound parameter; a nonzero OID overrides the value's inferred type.
pub const Param = struct { value: Value, oid: u32 = 0 };
/// Borrowed column metadata expires when its owning response slab is reused.
pub const Column = struct { name: []const u8, oid: u32, format: Format = .binary };
/// Borrowed field payload with explicit SQL type and format.
pub const Field = struct { bytes: ?[]const u8, oid: u32, format: Format = .binary };
/// Stable statement name and SQL text, retained by the caller for cache lifetime.
pub const Statement = struct { name: []const u8, sql: []const u8, param_oids: []const u32 = &.{} };

/// PostgreSQL OID inferred from a typed value, or zero for untyped NULL.
pub fn value_oid(value: Value) u32 {
    return switch (value) {
        .null => 0,
        .bool => 16,
        .int2 => 21,
        .int4 => 23,
        .int8 => 20,
        .float4 => 700,
        .float8 => 701,
        .text => 25,
        .varchar => 1043,
        .bytea => 17,
        .timestamp => 1114,
        .date => 1082,
        .uuid => 2950,
        .numeric => 1700,
    };
}
