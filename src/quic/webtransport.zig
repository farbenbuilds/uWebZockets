//! Public WebTransport draft-16 facade. Codec, setting, session, and capsule
//! primitives live in `webtransport/` submodules and are re-exported here so
//! importers keep one stable entry point.

const std = @import("std");
const extensions = @import("http3_extensions.zig");

const capsule = @import("webtransport/capsule.zig");
const datagrams = @import("webtransport/datagrams.zig");
const headers = @import("webtransport/headers.zig");
const session = @import("webtransport/session.zig");
const settings = @import("webtransport/settings.zig");
const varint = @import("webtransport/varint.zig");

/// WebTransport error for a stream rejected while awaiting association.
pub const wt_buffered_stream_rejected: u64 = 0x3994bd84;
/// WebTransport error for an absent or closed session.
pub const wt_session_gone: u64 = 0x170d7b68;
/// WebTransport session flow-control violation.
pub const wt_flow_control_error: u64 = 0x045d4487;
/// WebTransport ALPN negotiation failure.
pub const wt_alpn_error: u64 = 0x0817b3dd;
/// WebTransport protocol or transport prerequisites were not met.
pub const wt_requirements_not_met: u64 = 0x212c0d48;
/// First HTTP/3 code in the mapped 32-bit application-error range.
pub const wt_application_error_first: u64 = 0x52e4a40fa8db;
/// Last HTTP/3 code in the mapped 32-bit application-error range.
pub const wt_application_error_last: u64 = 0x52e5ac983162;

/// HTTP/3 frame encoding error.
pub const h3_frame_error: u64 = 0x106;
/// HTTP/3 excessive-load error.
pub const h3_excessive_load: u64 = 0x107;
/// HTTP/3 identifier error.
pub const h3_id_error: u64 = 0x108;
/// HTTP/3 settings error.
pub const h3_settings_error: u64 = 0x109;
/// HTTP/3 request-rejected error.
pub const h3_request_rejected: u64 = 0x10b;
/// HTTP/3 malformed-message error.
pub const h3_message_error: u64 = 0x10e;

// QUIC variable-length integer coding.
pub const max_quic_varint = varint.max_quic_varint;
pub const Varint = varint.Varint;
pub const VarintError = varint.VarintError;
pub const decode_varint = varint.decode_varint;
pub const encode_varint = varint.encode_varint;

// Session identity, lifecycle slab, and draft session flow-control limits.
pub const max_stream_count = session.max_stream_count;
pub const valid_session_id = session.valid_session_id;
pub const SessionState = session.SessionState;
pub const SessionHandle = session.SessionHandle;
pub const SessionError = session.SessionError;
pub const session_slab = session.session_slab;

// HTTP/3 settings and draft-16 requirement checks.
pub const settings_enable_connect_protocol = settings.settings_enable_connect_protocol;
pub const settings_h3_datagram = settings.settings_h3_datagram;
pub const settings_wt_enabled = settings.settings_wt_enabled;
pub const settings_wt_initial_max_data = settings.settings_wt_initial_max_data;
pub const settings_wt_initial_max_streams_uni = settings.settings_wt_initial_max_streams_uni;
pub const settings_wt_initial_max_streams_bidi = settings.settings_wt_initial_max_streams_bidi;
pub const reset_stream_at_parameter = settings.reset_stream_at_parameter;
pub const reset_stream_at_frame = settings.reset_stream_at_frame;
pub const Settings = settings.Settings;
pub const SettingResult = settings.SettingResult;
pub const SettingsError = settings.SettingsError;
pub const TransportParameters = settings.TransportParameters;
pub const apply_setting = settings.apply_setting;
pub const decode_settings_payload = settings.decode_settings_payload;
pub const encode_server_settings = settings.encode_server_settings;
pub const server_requirements_met = settings.server_requirements_met;
pub const client_requirements_met = settings.client_requirements_met;
pub const flow_control_enabled = settings.flow_control_enabled;

// Unidirectional and bidirectional stream association prefixes.
pub const unidirectional_stream_type = headers.unidirectional_stream_type;
pub const bidirectional_stream_signal = headers.bidirectional_stream_signal;
pub const StreamHeader = headers.StreamHeader;
pub const StreamHeaderError = headers.StreamHeaderError;
pub const decode_unidirectional_header = headers.decode_unidirectional_header;
pub const decode_bidirectional_header = headers.decode_bidirectional_header;
pub const encode_unidirectional_header = headers.encode_unidirectional_header;
pub const encode_bidirectional_header = headers.encode_bidirectional_header;

// Quarter-stream-ID datagram coding.
pub const max_datagram_frame_size_parameter = datagrams.max_datagram_frame_size_parameter;
pub const Datagram = datagrams.Datagram;
pub const DatagramError = datagrams.DatagramError;
pub const decode_datagram = datagrams.decode_datagram;
pub const encode_datagram = datagrams.encode_datagram;

// Capsule coding and session flow-control application.
pub const wt_close_session = capsule.wt_close_session;
pub const wt_drain_session = capsule.wt_drain_session;
pub const wt_max_data = capsule.wt_max_data;
pub const wt_max_streams_bidi = capsule.wt_max_streams_bidi;
pub const wt_max_streams_uni = capsule.wt_max_streams_uni;
pub const wt_data_blocked = capsule.wt_data_blocked;
pub const wt_streams_blocked_bidi = capsule.wt_streams_blocked_bidi;
pub const wt_streams_blocked_uni = capsule.wt_streams_blocked_uni;
pub const max_close_message_size = capsule.max_close_message_size;
pub const CloseSession = capsule.CloseSession;
pub const UnknownCapsule = capsule.UnknownCapsule;
pub const Capsule = capsule.Capsule;
pub const DecodedCapsule = capsule.DecodedCapsule;
pub const CapsuleError = capsule.CapsuleError;
pub const FlowState = capsule.FlowState;
pub const CapsuleAction = capsule.CapsuleAction;
pub const FlowError = capsule.FlowError;
pub const decode_capsule = capsule.decode_capsule;
pub const encode_drain_session = capsule.encode_drain_session;
pub const encode_close_session = capsule.encode_close_session;
pub const encode_integer_capsule = capsule.encode_integer_capsule;
pub const apply_capsule = capsule.apply_capsule;

/// Borrowed fields and policy facts for a WebTransport extended CONNECT.
///
/// Validation is allocation-free and retains none of these slices.
pub const ConnectRequest = struct {
    /// `:method` value; validation requires `CONNECT`.
    method: []const u8,
    /// `:protocol` value; validation requires `webtransport-h3`.
    protocol: ?[]const u8,
    /// `:scheme` value; validation requires `https`.
    scheme: ?[]const u8,
    /// Non-empty `:authority` value.
    authority: ?[]const u8,
    /// Absolute-path `:path` value.
    path: ?[]const u8,
    /// Borrowed Origin field, when supplied.
    origin: ?[]const u8 = null,
    /// Whether browser-origin policy applies to this peer.
    browser_client: bool = false,
    /// Application decision for a supplied origin.
    origin_allowed: bool = false,
    /// Whether the peer SETTINGS frame has been processed.
    client_settings_received: bool = false,
    /// Cached result of peer settings and transport-parameter checks.
    client_requirements_valid: bool = false,
    /// Whether request processing began before handshake confirmation.
    arrived_before_confirmation: bool = false,
};

/// Validation failures for a WebTransport extended CONNECT request.
pub const ConnectError = error{
    /// The peer SETTINGS frame has not been processed yet.
    ClientSettingsPending,
    /// The peer did not negotiate every draft prerequisite.
    RequirementsNotMet,
    /// The request arrived as replayable early data.
    TooEarly,
    /// `:method` was not `CONNECT`.
    InvalidMethod,
    /// `:protocol` was absent or unsupported.
    InvalidProtocol,
    /// `:scheme` was absent or was not `https`.
    InvalidScheme,
    /// `:authority` was absent or empty.
    MissingAuthority,
    /// `:path` was absent, empty, or not absolute.
    InvalidPath,
    /// Browser policy required an Origin field.
    MissingOrigin,
    /// The application rejected the supplied origin.
    ForbiddenOrigin,
};

/// Validates connection state, pseudo-fields, and origin policy without I/O.
pub fn validate_connect(request: ConnectRequest) ConnectError!void {
    if (!request.client_settings_received) return error.ClientSettingsPending;
    if (!request.client_requirements_valid) return error.RequirementsNotMet;
    if (request.arrived_before_confirmation) return error.TooEarly;
    if (!std.mem.eql(u8, request.method, "CONNECT")) return error.InvalidMethod;
    const protocol = request.protocol orelse return error.InvalidProtocol;
    if (!std.mem.eql(u8, protocol, "webtransport-h3")) return error.InvalidProtocol;
    const scheme = request.scheme orelse return error.InvalidScheme;
    if (!std.mem.eql(u8, scheme, "https")) return error.InvalidScheme;
    if (request.authority == null or request.authority.?.len == 0) return error.MissingAuthority;
    if (request.path == null or request.path.?.len == 0 or request.path.?[0] != '/') {
        return error.InvalidPath;
    }
    if (request.browser_client and request.origin == null) return error.MissingOrigin;
    if (request.origin != null and !request.origin_allowed) return error.ForbiddenOrigin;
}

/// Maps a CONNECT validation failure to its response status.
pub fn connect_error_status(connect_error: ConnectError) u16 {
    return switch (connect_error) {
        error.ClientSettingsPending => 503,
        error.RequirementsNotMet => 400,
        error.TooEarly => 425,
        error.ForbiddenOrigin => 403,
        error.InvalidProtocol => 405,
        else => 400,
    };
}

/// Direction of a stream buffered before its session is available.
pub const PendingStreamKind = enum(u8) {
    /// Peer-initiated unidirectional stream.
    unidirectional,
    /// Peer-initiated bidirectional stream.
    bidirectional,
};

/// Capacity-policy outcomes when buffering unassociated traffic.
pub const PendingError = error{
    /// No fixed stream slot remains; reject the stream.
    BufferedStreamRejected,
    /// No fixed datagram slot remains; silently drop the datagram.
    DropDatagram,
    /// The datagram exceeds the per-slot payload capacity.
    DatagramTooLarge,
};

/// Returns fixed-capacity storage for traffic awaiting session association.
///
/// Stream entries copy only identifiers and direction. Datagram payloads are
/// copied into embedded slabs, so caller buffers may be reused after return.
/// The zero value is ready for use; do not copy it after mutation.
pub fn pending_associations(
    comptime stream_capacity: usize,
    comptime datagram_capacity: usize,
    comptime datagram_payload_capacity: usize,
) type {
    if (stream_capacity == 0) @compileError("pending stream capacity must be nonzero");
    if (datagram_capacity == 0) @compileError("pending datagram capacity must be nonzero");
    if (datagram_payload_capacity == 0) @compileError("pending datagram payload capacity must be nonzero");

    return struct {
        /// Stream IDs in insertion order; only entries below `stream_count` are valid.
        stream_ids: [stream_capacity]u64 = .{0} ** stream_capacity,
        /// Session IDs parallel to `stream_ids`; callers must not mutate them.
        stream_session_ids: [stream_capacity]u64 = .{0} ** stream_capacity,
        /// Directions parallel to `stream_ids`; callers must not mutate them.
        stream_kinds: [stream_capacity]PendingStreamKind = .{.unidirectional} ** stream_capacity,
        /// Session IDs for payload slots below `datagram_count`.
        datagram_session_ids: [datagram_capacity]u64 = .{0} ** datagram_capacity,
        /// Initialized payload lengths parallel to `datagram_session_ids`.
        datagram_lengths: [datagram_capacity]usize = .{0} ** datagram_capacity,
        /// Embedded payload storage; bytes beyond each length are undefined.
        datagram_payloads: [datagram_capacity][datagram_payload_capacity]u8 = undefined,
        /// Number of initialized stream entries.
        stream_count: usize = 0,
        /// Number of initialized datagram entries.
        datagram_count: usize = 0,

        /// Appends stream metadata or returns the stream rejection policy error.
        pub fn add_stream(
            self: *@This(),
            stream_id: u64,
            session_id: u64,
            kind: PendingStreamKind,
        ) PendingError!void {
            if (self.stream_count == stream_capacity) return error.BufferedStreamRejected;
            const slot = self.stream_count;
            self.stream_ids[slot] = stream_id;
            self.stream_session_ids[slot] = session_id;
            self.stream_kinds[slot] = kind;
            self.stream_count += 1;
        }

        /// Copies a payload into the next datagram slot.
        ///
        /// Capacity and size errors leave existing entries and counts unchanged.
        pub fn add_datagram(self: *@This(), session_id: u64, payload: []const u8) PendingError!void {
            if (self.datagram_count == datagram_capacity) return error.DropDatagram;
            if (payload.len > datagram_payload_capacity) return error.DatagramTooLarge;
            const slot = self.datagram_count;
            self.datagram_session_ids[slot] = session_id;
            self.datagram_lengths[slot] = payload.len;
            @memcpy(self.datagram_payloads[slot][0..payload.len], payload);
            self.datagram_count += 1;
        }

        /// Makes all entries reusable without erasing embedded payload bytes.
        pub fn clear(self: *@This()) void {
            self.stream_count = 0;
            self.datagram_count = 0;
        }
    };
}

/// Maps every 32-bit WebTransport application code into HTTP/3 error space.
pub fn application_error_to_http3(application_error: u32) u64 {
    const value: u64 = application_error;
    return wt_application_error_first + value + value / 0x1e;
}

/// Reverses a mapped HTTP/3 error, or returns `null` for reserved/other codes.
pub fn http3_error_to_application(http3_error: u64) ?u32 {
    if (http3_error < wt_application_error_first or http3_error > wt_application_error_last) {
        return null;
    }
    if ((http3_error - 0x21) % 0x1f == 0) return null;
    const shifted = http3_error - wt_application_error_first;
    const application_error = shifted - shifted / 0x1f;
    if (application_error > std.math.maxInt(u32)) return null;
    return @intCast(application_error);
}

/// Failure to satisfy the runtime primitives needed by draft 16.
pub const BackendError = error{
    /// At least one mandatory backend capability is absent.
    BackendUnsupported,
};

/// Verifies a declarative backend capability record.
///
/// This check performs no configuration and does not prove wire
/// interoperability. The pinned lsquic backend currently fails this check.
pub fn require_backend(capabilities: extensions.BackendCapabilities) BackendError!void {
    if (!capabilities.extended_connect_setting or
        !capabilities.quic_datagrams or
        !capabilities.outgoing_unidirectional_streams or
        !capabilities.reset_stream_at or
        !capabilities.webtransport_draft_16)
    {
        return error.BackendUnsupported;
    }
}
