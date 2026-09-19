//! C ABI error mapping and slice boundary validation.
//!
//! Error integers are append-only and must match the `uwz_error` enum in
//! `include/uWebZockets.h`.

const version = @import("../version.zig");
const types = @import("types.zig");

const ok = types.ok;
const invalid_argument = types.invalid_argument;
const out_of_memory = types.out_of_memory;
const invalid_state = types.invalid_state;
const already_exists = types.already_exists;
const capacity = types.capacity;
const would_block = types.would_block;
const protocol = types.protocol;
const io_error = types.io_error;
const unsupported = types.unsupported;
const internal = types.internal;

/// Returns the versioned C ABI string.
pub export fn uwz_version() [*c]const u8 {
    return version.string;
}

/// Returns a static name for a versioned C error code.
pub export fn uwz_error_name(code: c_int) [*c]const u8 {
    return switch (code) {
        ok => "ok",
        invalid_argument => "invalid argument",
        out_of_memory => "out of memory",
        invalid_state => "invalid state",
        already_exists => "already exists",
        capacity => "capacity reached",
        would_block => "would block",
        protocol => "protocol error",
        io_error => "I/O error",
        unsupported => "unsupported",
        internal => "internal error",
        else => "unknown error",
    };
}

pub fn required_bytes(pointer: [*c]const u8, length: usize) ?[]const u8 {
    if (pointer == null) return null;
    return pointer[0..length];
}

pub fn slice_bytes(slice: types.CSlice) ?[]const u8 {
    if (slice.length == 0) return "";
    if (slice.data == null) return null;
    return slice.data[0..slice.length];
}

pub fn make_slice(bytes: []const u8) types.CSlice {
    if (bytes.len == 0) return types.empty_slice;
    return .{ .data = bytes.ptr, .length = bytes.len };
}

pub fn map_error(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory,
        error.TlsContextCreationFailed,
        error.SslAllocationFailed,
        error.BioAllocationFailed,
        error.InitFailed,
        error.LsquicEngineCreationFailed,
        => out_of_memory,
        error.WouldBlock => would_block,
        error.RouteCapacityReached,
        error.RouteStorageCapacityReached,
        error.MiddlewareCapacityReached,
        error.RouteParameterCapacityReached,
        error.CapacityExceeded,
        error.ConnectionCapacityReached,
        error.StreamCapacityReached,
        error.TopicCapacityReached,
        error.SubscriptionCapacityReached,
        error.TopicSubscriberCapacityReached,
        error.BufferTooSmall,
        error.SizeOverflow,
        error.ReferenceCountOverflow,
        => capacity,
        error.RouteAlreadyRegistered,
        error.AlreadyListening,
        error.TlsAlreadyInitialized,
        => already_exists,
        error.InvalidRoutePath,
        error.InvalidRoutePattern,
        error.InvalidWebSocketLimits,
        error.InvalidMethod,
        error.InvalidStatus,
        error.InvalidHeaders,
        error.InvalidOpcode,
        error.InvalidUtf8,
        error.InvalidCloseCode,
        error.InvalidClosePayload,
        error.InvalidCloseFrame,
        error.ControlFrameTooLarge,
        error.BodyNotAllowed,
        error.EmptyTopic,
        error.TopicTooLong,
        error.Overflow,
        error.InvalidEnd,
        error.InvalidCharacter,
        error.Incomplete,
        error.NonCanonical,
        error.ParseFailed,
        error.UnresolvedScope,
        error.KeyMismatch,
        => invalid_argument,
        error.ApplicationUnavailable,
        error.ApplicationDeinitialized,
        error.ApplicationAlreadyRunning,
        error.RoutesLocked,
        error.ResponseAlreadyStarted,
        error.ResponseNotStreaming,
        error.Http3NotInitialized,
        error.ShutdownIncomplete,
        error.AsyncResponseExpired,
        error.AsyncResponseAlreadyCompleted,
        error.ConnectionClosed,
        error.CompressionUnavailable,
        error.PubSubUnavailable,
        error.TransportAlreadyStarted,
        error.TransportShuttingDown,
        error.QuicEngineAlreadyStarted,
        error.TlsUnavailable,
        error.StreamClosed,
        error.NestedRunsNotAllowed,
        => invalid_state,
        error.Http3Unavailable,
        error.BackendUnsupported,
        error.Unsupported,
        => unsupported,
        error.ProtocolError,
        error.InvalidFrame,
        error.InvalidHandshake,
        error.OutputTooLarge,
        => protocol,
        error.BufferOverflow => capacity,
        error.InputOutput,
        error.AccessDenied,
        error.AddressInUse,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.AddressNotAvailable,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.NetworkSubsystemFailed,
        error.SystemResources,
        error.TlsReadFailed,
        error.TlsWriteFailed,
        error.TlsShutdownFailed,
        error.CertificateLoadFailed,
        error.PrivateKeyLoadFailed,
        => io_error,
        else => internal,
    };
}
