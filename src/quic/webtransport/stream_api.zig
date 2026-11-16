const webtransport = @import("../webtransport.zig");

/// Application-scoped stream identity; copied handles do not retain a stream.
pub const Handle = struct {
    owner: usize,
    index: usize,
    generation: u64,
};

/// Session identity includes its owning application and connection generation.
pub const SessionHandle = struct {
    owner: usize,
    connection_index: usize,
    connection_generation: u64,
    index: usize,
    generation: u64,
};

/// Transport direction of the associated child stream.
pub const Direction = enum(u8) { uni, bidi };
/// Endpoint that originally created the transport stream.
pub const Initiator = enum(u8) { peer, local };

/// Full transport IDs accompany application handles without narrowing either.
pub const Info = struct {
    handle: Handle,
    session: SessionHandle,
    session_id: u64,
    stream_id: u64,
    direction: Direction,
    initiator: Initiator,
};

/// Application errors occupy the mapped draft-16 range; other codes stay HTTP/3.
pub const ErrorCode = union(enum) {
    application: u32,
    http3: u64,
};

/// Native error fields must fit QUIC's 62-bit variable-length integer.
pub const CodeError = error{InvalidErrorCode};

/// Identity, lifecycle and deferred-service failures for handle operations.
pub const OperationError = error{
    Unsupported,
    WrongApp,
    StaleHandle,
    NotReady,
    SessionClosed,
    ShuttingDown,
    WriteClosed,
    ConflictingIntent,
    ControlFailed,
    WakeFailed,
    NoWritableCallback,
};

/// A positive write result always transfers that prefix to native ownership.
pub const WriteError = OperationError || error{ WouldBlock, WriteFailed, WriteTooLarge };

/// The first closing cause is preserved through callback reentry.
pub const CloseReason = enum(u8) {
    completed,
    peer_reset,
    rejected,
    expired,
    session_closed,
    connection_closed,
    consumer_cancelled,
    shutdown,
    protocol_error,
};

/// Unknown final payload size remains null, including connection abandonment.
pub const ClosedEvent = struct {
    handle: Handle,
    reason: CloseReason,
    code: ?ErrorCode = null,
    final_payload_size: ?u64,
    accounted_bytes: u64,
};

/// One established parent session, separate from any particular child.
pub const SessionInfo = struct {
    handle: SessionHandle,
    session_id: u64,
};

/// The session handle is already invalid when its close callback runs.
pub const SessionClosedEvent = struct {
    handle: SessionHandle,
    session_id: u64,
    reason: CloseReason,
    code: ?ErrorCode = null,
};

pub const OpenCallback = *const fn (*anyopaque, Info) bool;
/// Payload borrows transport storage only until the callback returns.
pub const DataCallback = *const fn (*anyopaque, Handle, []const u8) bool;
/// One requested write opportunity; explicitly rearm after each notification.
pub const WritableCallback = *const fn (*anyopaque, Handle) void;
pub const EofCallback = *const fn (*anyopaque, Handle, u64) void;
pub const ResetCallback = *const fn (*anyopaque, Handle, ErrorCode, u64) void;
pub const StopCallback = *const fn (*anyopaque, Handle, ErrorCode) void;
pub const ClosedCallback = *const fn (*anyopaque, ClosedEvent) void;
pub const SessionOpenCallback = *const fn (*anyopaque, SessionInfo) void;
pub const SessionClosedCallback = *const fn (*anyopaque, SessionClosedEvent) void;

/// Open explicitly accepts ownership; notification hooks are independently optional.
pub const Callbacks = struct {
    open: OpenCallback,
    data: ?DataCallback = null,
    writable: ?WritableCallback = null,
    eof: ?EofCallback = null,
    reset: ?ResetCallback = null,
    stop: ?StopCallback = null,
    closed: ?ClosedCallback = null,
    session_open: ?SessionOpenCallback = null,
    session_closed: ?SessionClosedCallback = null,
};

/// Maps application errors while preserving explicitly supplied HTTP/3 values.
pub fn to_native_code(code: ErrorCode) CodeError!u64 {
    return switch (code) {
        .application => |application| webtransport.application_error_to_http3(application),
        .http3 => |http3| if (http3 <= webtransport.max_quic_varint) http3 else error.InvalidErrorCode,
    };
}

/// Reserved mapping holes retain their HTTP/3 identity instead of narrowing.
pub fn from_native_code(code: u64) CodeError!ErrorCode {
    if (code > webtransport.max_quic_varint) return error.InvalidErrorCode;
    if (webtransport.http3_error_to_application(code)) |application| return .{ .application = application };
    return .{ .http3 = code };
}
