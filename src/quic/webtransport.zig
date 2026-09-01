const std = @import("std");
const extensions = @import("http3_extensions.zig");

/// HTTP/3 setting that permits extended CONNECT requests.
pub const settings_enable_connect_protocol: u64 = 0x08;
/// HTTP/3 setting that enables HTTP datagrams.
pub const settings_h3_datagram: u64 = 0x33;
/// Draft-16 setting that selects WebTransport version 1.
pub const settings_wt_enabled: u64 = 0x2c7cf000;
/// Draft-16 setting for the initial session data limit.
pub const settings_wt_initial_max_data: u64 = 0x2b61;
/// Draft-16 setting for the initial unidirectional stream limit.
pub const settings_wt_initial_max_streams_uni: u64 = 0x2b64;
/// Draft-16 setting for the initial bidirectional stream limit.
pub const settings_wt_initial_max_streams_bidi: u64 = 0x2b65;

/// QUIC transport parameter advertising datagram payload capacity.
pub const max_datagram_frame_size_parameter: u64 = 0x20;
/// Draft transport parameter enabling RESET_STREAM_AT.
pub const reset_stream_at_parameter: u64 = 0x1d;
/// Draft QUIC RESET_STREAM_AT frame type.
pub const reset_stream_at_frame: u64 = 0x24;

/// WebTransport unidirectional stream type.
pub const unidirectional_stream_type: u64 = 0x54;
/// WebTransport bidirectional stream prefix.
pub const bidirectional_stream_signal: u64 = 0x41;

/// WT_CLOSE_SESSION capsule type.
pub const wt_close_session: u64 = 0x2843;
/// WT_DRAIN_SESSION capsule type.
pub const wt_drain_session: u64 = 0x78ae;
/// WT_MAX_DATA capsule type.
pub const wt_max_data: u64 = 0x190b4d3d;
/// WT_MAX_STREAMS_BIDI capsule type.
pub const wt_max_streams_bidi: u64 = 0x190b4d3f;
/// WT_MAX_STREAMS_UNI capsule type.
pub const wt_max_streams_uni: u64 = 0x190b4d40;
/// WT_DATA_BLOCKED capsule type.
pub const wt_data_blocked: u64 = 0x190b4d41;
/// WT_STREAMS_BLOCKED_BIDI capsule type.
pub const wt_streams_blocked_bidi: u64 = 0x190b4d43;
/// WT_STREAMS_BLOCKED_UNI capsule type.
pub const wt_streams_blocked_uni: u64 = 0x190b4d44;

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

/// Largest value representable by a QUIC variable-length integer.
pub const max_quic_varint: u64 = (1 << 62) - 1;
/// Largest stream count allowed by the draft session flow controller.
pub const max_stream_count: u64 = 1 << 60;
/// Maximum WT_CLOSE_SESSION reason length accepted or emitted.
pub const max_close_message_size: usize = 1024;

/// Decoded QUIC variable-length integer and its encoded byte count.
pub const Varint = struct {
    /// Decoded integer value.
    value: u64,
    /// Number of input bytes consumed.
    length: usize,
};

/// Failures from QUIC variable-length integer coding.
pub const VarintError = error{
    /// The input does not contain a complete integer.
    NeedMoreData,
    /// The requested value exceeds `max_quic_varint`.
    ValueTooLarge,
    /// The caller-owned output cannot hold the encoded integer.
    BufferTooSmall,
};

/// Decodes one QUIC variable-length integer without retaining `input`.
///
/// Non-minimal encodings are accepted. `NeedMoreData` leaves no parser state;
/// callers should retry with the complete prefix.
pub fn decode_varint(input: []const u8) VarintError!Varint {
    if (input.len == 0) return error.NeedMoreData;
    const length: usize = @as(usize, 1) << @intCast(input[0] >> 6);
    if (input.len < length) return error.NeedMoreData;

    var value: u64 = input[0] & 0x3f;
    var index: usize = 1;
    while (index < length) : (index += 1) {
        value = (value << 8) | input[index];
    }
    return .{ .value = value, .length = length };
}

/// Encodes one integer minimally into caller-owned `output`.
///
/// Returns the number of initialized bytes. Both errors are detected before
/// writing, so `output` remains unchanged on failure.
pub fn encode_varint(value: u64, output: []u8) VarintError!usize {
    if (value > max_quic_varint) return error.ValueTooLarge;
    const length: usize = if (value < (1 << 6))
        1
    else if (value < (1 << 14))
        2
    else if (value < (1 << 30))
        4
    else
        8;
    if (output.len < length) return error.BufferTooSmall;

    var remaining = value;
    var index = length;
    while (index != 0) {
        index -= 1;
        output[index] = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
    output[0] |= switch (length) {
        1 => 0x00,
        2 => 0x40,
        4 => 0x80,
        8 => 0xc0,
        else => unreachable,
    };
    return length;
}

/// Recognized WebTransport-related HTTP/3 settings.
///
/// The zero value is ready for decoding. `seen` is decoder bookkeeping and
/// should not be changed independently of the corresponding values.
pub const Settings = struct {
    /// Selected WebTransport draft version; draft 16 requires one.
    wt_enabled: u64 = 0,
    /// Whether extended CONNECT is enabled.
    enable_connect_protocol: u64 = 0,
    /// Whether HTTP datagrams are enabled.
    h3_datagram: u64 = 0,
    /// Initial aggregate session data limit.
    initial_max_data: u64 = 0,
    /// Initial session unidirectional stream limit.
    initial_max_streams_uni: u64 = 0,
    /// Initial session bidirectional stream limit.
    initial_max_streams_bidi: u64 = 0,
    /// Bit mask of recognized settings already applied.
    seen: u8 = 0,
};

/// Outcome from applying one HTTP/3 setting pair.
pub const SettingResult = enum(u8) {
    /// A recognized setting was validated and stored.
    applied,
    /// An unknown setting was ignored as required by HTTP/3.
    ignored,
};

/// Semantic or framing failures while processing settings.
pub const SettingsError = error{
    /// A recognized identifier occurred more than once.
    DuplicateSetting,
    /// A boolean setting was not zero or one.
    InvalidBoolean,
    /// SETTINGS_WT_ENABLED selected an unsupported version.
    UnsupportedWebTransportVersion,
    /// A stream limit exceeded `max_stream_count`.
    InvalidStreamLimit,
    /// The payload ended within an identifier or value.
    TruncatedSettings,
};

/// Applies one identifier/value pair to caller-owned settings state.
///
/// Unknown identifiers do not change `settings`. Validation is atomic: every
/// error leaves both the decoded values and duplicate-detection mask unchanged.
pub fn apply_setting(settings: *Settings, identifier: u64, value: u64) SettingsError!SettingResult {
    const field = setting_field(identifier) orelse return .ignored;
    const bit: u8 = @as(u8, 1) << field.bit;
    if (settings.seen & bit != 0) return error.DuplicateSetting;

    var next = settings.*;

    switch (field.kind) {
        .wt_enabled => {
            if (value > 1) return error.UnsupportedWebTransportVersion;
            next.wt_enabled = value;
        },
        .connect => {
            if (value > 1) return error.InvalidBoolean;
            next.enable_connect_protocol = value;
        },
        .datagram => {
            if (value > 1) return error.InvalidBoolean;
            next.h3_datagram = value;
        },
        .max_data => next.initial_max_data = value,
        .max_streams_uni => {
            if (value > max_stream_count) return error.InvalidStreamLimit;
            next.initial_max_streams_uni = value;
        },
        .max_streams_bidi => {
            if (value > max_stream_count) return error.InvalidStreamLimit;
            next.initial_max_streams_bidi = value;
        },
    }
    next.seen |= bit;
    settings.* = next;
    return .applied;
}

/// Decodes a complete SETTINGS payload into stack-owned state.
///
/// No input slice is retained. Any malformed pair rejects the entire result;
/// unknown settings are skipped without allocation.
pub fn decode_settings_payload(payload: []const u8) SettingsError!Settings {
    var settings = Settings{};
    var offset: usize = 0;
    while (offset < payload.len) {
        const identifier = decode_varint(payload[offset..]) catch return error.TruncatedSettings;
        offset += identifier.length;
        const value = decode_varint(payload[offset..]) catch return error.TruncatedSettings;
        offset += value.length;
        _ = try apply_setting(&settings, identifier.value, value.value);
    }
    return settings;
}

/// Encodes all six recognized settings into caller-owned `output`.
///
/// The function does not validate boolean or stream-limit semantics; callers
/// must supply a valid server configuration. It returns the initialized prefix
/// length. A short buffer may contain a partial sequence when
/// `BufferTooSmall` is returned.
pub fn encode_server_settings(settings: Settings, output: []u8) VarintError!usize {
    var offset: usize = 0;
    offset += try encode_setting_pair(settings_wt_enabled, settings.wt_enabled, output[offset..]);
    offset += try encode_setting_pair(
        settings_enable_connect_protocol,
        settings.enable_connect_protocol,
        output[offset..],
    );
    offset += try encode_setting_pair(settings_h3_datagram, settings.h3_datagram, output[offset..]);
    offset += try encode_setting_pair(
        settings_wt_initial_max_data,
        settings.initial_max_data,
        output[offset..],
    );
    offset += try encode_setting_pair(
        settings_wt_initial_max_streams_uni,
        settings.initial_max_streams_uni,
        output[offset..],
    );
    offset += try encode_setting_pair(
        settings_wt_initial_max_streams_bidi,
        settings.initial_max_streams_bidi,
        output[offset..],
    );
    return offset;
}

/// Peer QUIC transport parameters required by WebTransport draft 16.
pub const TransportParameters = struct {
    /// Maximum QUIC DATAGRAM frame size; zero disables datagrams.
    max_datagram_frame_size: u64 = 0,
    /// Whether RESET_STREAM_AT was negotiated.
    reset_stream_at: bool = false,
};

/// Returns whether an advertised server configuration meets every prerequisite.
pub fn server_requirements_met(settings: Settings, transport: TransportParameters) bool {
    return settings.wt_enabled == 1 and
        settings.enable_connect_protocol == 1 and
        settings.h3_datagram == 1 and
        transport.max_datagram_frame_size != 0 and
        transport.reset_stream_at;
}

/// Returns whether an advertised client configuration meets every prerequisite.
///
/// Extended CONNECT is omitted because its receipt by a server has no effect.
pub fn client_requirements_met(settings: Settings, transport: TransportParameters) bool {
    return settings.wt_enabled == 1 and
        settings.h3_datagram == 1 and
        transport.max_datagram_frame_size != 0 and
        transport.reset_stream_at;
}

/// Returns whether both endpoints requested WebTransport session flow control.
pub fn flow_control_enabled(local: Settings, peer: Settings) bool {
    return flow_control_requested(local) and flow_control_requested(peer);
}

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

/// Lifecycle state recorded for one WebTransport session.
pub const SessionState = enum(u8) {
    /// CONNECT validation succeeded but the response is not final.
    accepting,
    /// The CONNECT response established the session.
    established,
    /// The application has been asked to begin graceful shutdown.
    draining,
    /// The session is terminal.
    closed,
};

/// Generation-checked reference to one active WebTransport session.
///
/// A handle remains valid only until that session is closed. Callers may copy
/// handles but must not construct them or retain them across `close`.
pub const SessionHandle = struct {
    /// Fixed slab slot occupied by the session.
    index: usize,
    /// Slot generation that prevents aliases after slot reuse.
    generation: u64,
};

/// Failures from fixed-capacity session bookkeeping.
pub const SessionError = error{
    /// The CONNECT stream ID was not a client-initiated bidirectional ID.
    InvalidSessionId,
    /// The session ID already identifies an active session.
    DuplicateSession,
    /// Flow control is disabled and another session remains open.
    TooManySessions,
    /// Every compile-time slot is occupied.
    CapacityExceeded,
    /// A slot exhausted its generation space and cannot safely be reused.
    GenerationExhausted,
    /// The handle is closed, superseded, or outside this slab.
    StaleHandle,
    /// The requested lifecycle transition is not permitted.
    InvalidTransition,
};

/// Returns fixed-capacity, allocation-free session lifecycle storage.
///
/// `capacity` bounds simultaneous sessions. Closing a session releases its slot;
/// per-slot generations ensure old handles cannot alias a later occupant. The
/// zero value is ready for use. Keep one stable instance and do not copy it
/// after mutation because handles are meaningful only for their source slab.
pub fn session_slab(comptime capacity: usize) type {
    if (capacity == 0) @compileError("WebTransport session capacity must be greater than zero");

    return struct {
        const Self = @This();

        /// Session IDs indexed by slot; only active entries are meaningful.
        session_ids: [capacity]u64 = .{0} ** capacity,
        /// Lifecycle states indexed by slot; callers must not mutate them.
        states: [capacity]SessionState = .{.closed} ** capacity,
        /// Current generation for each slot; callers must not mutate it.
        generations: [capacity]u64 = .{0} ** capacity,
        /// Slots occupied by active sessions; callers must not mutate it.
        active: std.StaticBitSet(capacity) = .empty,
        /// Number of active sessions; callers must not mutate it.
        active_count: usize = 0,

        /// Records an accepted CONNECT stream and returns its stable handle.
        ///
        /// Without negotiated flow control, at most one active session is
        /// permitted. Closed slots are reusable. All failures leave the slab
        /// unchanged.
        pub fn open(self: *Self, session_id: u64, use_flow_control: bool) SessionError!SessionHandle {
            if (!valid_session_id(session_id)) return error.InvalidSessionId;
            if (self.find(session_id) != null) return error.DuplicateSession;
            if (!use_flow_control and self.active_count != 0) return error.TooManySessions;

            var slot: ?usize = null;
            var has_reusable_slot = false;
            for (0..capacity) |index| {
                if (self.active.isSet(index)) continue;
                has_reusable_slot = true;
                if (self.generations[index] == std.math.maxInt(u64)) continue;
                slot = index;
                break;
            }
            const index = slot orelse {
                if (has_reusable_slot) return error.GenerationExhausted;
                return error.CapacityExceeded;
            };

            self.generations[index] += 1;
            self.session_ids[index] = session_id;
            self.states[index] = .accepting;
            self.active.set(index);
            self.active_count += 1;
            return .{ .index = index, .generation = self.generations[index] };
        }

        /// Returns the active handle for `session_id`, or `null` if absent.
        pub fn find(self: *const Self, session_id: u64) ?SessionHandle {
            var iterator = self.active.iterator(.{});
            while (iterator.next()) |slot| {
                if (self.session_ids[slot] != session_id) continue;
                return .{ .index = slot, .generation = self.generations[slot] };
            }
            return null;
        }

        /// Advances an accepting session to established.
        pub fn establish(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            if (self.states[slot] != .accepting) return error.InvalidTransition;
            self.states[slot] = .established;
        }

        /// Advances an established session to draining.
        ///
        /// Repeating the drain transition is idempotent. Accepting sessions
        /// cannot begin draining before establishment.
        pub fn drain(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            if (self.states[slot] == .draining) return;
            if (self.states[slot] != .established) return error.InvalidTransition;
            self.states[slot] = .draining;
        }

        /// Closes an active session and releases its slot for reuse.
        ///
        /// The supplied handle and all of its copies become stale on return.
        pub fn close(self: *Self, handle: SessionHandle) SessionError!void {
            const slot = try self.validate_handle(handle);
            self.states[slot] = .closed;
            self.active.unset(slot);
            self.active_count -= 1;
        }

        /// Returns the state of an active generation-checked handle.
        pub fn state(self: *const Self, handle: SessionHandle) SessionError!SessionState {
            const slot = try self.validate_handle(handle);
            return self.states[slot];
        }

        /// Returns the number of active sessions in constant time.
        pub fn open_count(self: *const Self) usize {
            return self.active_count;
        }

        fn validate_handle(self: *const Self, handle: SessionHandle) SessionError!usize {
            if (handle.index >= capacity) return error.StaleHandle;
            if (!self.active.isSet(handle.index)) return error.StaleHandle;
            if (self.generations[handle.index] != handle.generation) return error.StaleHandle;
            return handle.index;
        }
    };
}

/// Parsed WebTransport stream association prefix.
pub const StreamHeader = struct {
    /// CONNECT stream ID identifying the associated session.
    session_id: u64,
    /// Number of prefix bytes consumed from the stream.
    length: usize,
};

/// Failures from WebTransport stream-prefix coding.
pub const StreamHeaderError = error{
    /// The input ends within the prefix.
    NeedMoreData,
    /// A unidirectional stream carried another stream type.
    InvalidStreamType,
    /// A bidirectional stream carried another signal value.
    InvalidSignal,
    /// The session ID is not a client-initiated bidirectional stream ID.
    InvalidSessionId,
    /// Caller-owned output cannot hold the prefix.
    BufferTooSmall,
    /// A value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes a unidirectional association prefix without retaining `input`.
pub fn decode_unidirectional_header(input: []const u8) StreamHeaderError!StreamHeader {
    const stream_type = decode_varint(input) catch |decode_error| return map_varint_stream_error(decode_error);
    if (stream_type.value != unidirectional_stream_type) return error.InvalidStreamType;
    const session = decode_varint(input[stream_type.length..]) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (!valid_session_id(session.value)) return error.InvalidSessionId;
    return .{ .session_id = session.value, .length = stream_type.length + session.length };
}

/// Decodes a bidirectional association prefix without retaining `input`.
pub fn decode_bidirectional_header(input: []const u8) StreamHeaderError!StreamHeader {
    const signal = decode_varint(input) catch |decode_error| return map_varint_stream_error(decode_error);
    if (signal.value != bidirectional_stream_signal) return error.InvalidSignal;
    const session = decode_varint(input[signal.length..]) catch |decode_error| {
        return map_varint_stream_error(decode_error);
    };
    if (!valid_session_id(session.value)) return error.InvalidSessionId;
    return .{ .session_id = session.value, .length = signal.length + session.length };
}

/// Encodes a unidirectional association prefix into caller-owned `output`.
///
/// Returns the initialized prefix length. A short buffer can contain the
/// stream-type varint before `BufferTooSmall` is returned.
pub fn encode_unidirectional_header(session_id: u64, output: []u8) StreamHeaderError!usize {
    if (!valid_session_id(session_id)) return error.InvalidSessionId;
    return encode_stream_header(unidirectional_stream_type, session_id, output);
}

/// Encodes a bidirectional association prefix into caller-owned `output`.
///
/// Returns the initialized prefix length. A short buffer can contain the
/// signal varint before `BufferTooSmall` is returned.
pub fn encode_bidirectional_header(session_id: u64, output: []u8) StreamHeaderError!usize {
    if (!valid_session_id(session_id)) return error.InvalidSessionId;
    return encode_stream_header(bidirectional_stream_signal, session_id, output);
}

/// Decoded WebTransport HTTP datagram.
pub const Datagram = struct {
    /// CONNECT stream ID reconstructed from the quarter-stream ID.
    session_id: u64,
    /// Payload borrowed from the decoder input.
    payload: []const u8,
    /// Number of bytes occupied by the quarter-stream ID.
    header_length: usize,
};

/// Failures from WebTransport datagram coding.
pub const DatagramError = error{
    /// The input ends within the quarter-stream ID.
    NeedMoreData,
    /// The decoded or supplied session ID is invalid.
    InvalidSessionId,
    /// Caller-owned output cannot hold the header and payload.
    BufferTooSmall,
    /// A value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes a WebTransport datagram and borrows its payload from `input`.
///
/// The returned payload remains valid only while `input` does.
pub fn decode_datagram(input: []const u8) DatagramError!Datagram {
    const quarter = decode_varint(input) catch |decode_error| return map_varint_datagram_error(decode_error);
    const session_id = std.math.mul(u64, quarter.value, 4) catch return error.InvalidSessionId;
    if (!valid_session_id(session_id)) return error.InvalidSessionId;
    return .{
        .session_id = session_id,
        .payload = input[quarter.length..],
        .header_length = quarter.length,
    };
}

/// Encodes a datagram into caller-owned `output` without allocating.
///
/// `payload` may be released after return. A short buffer can contain the
/// encoded quarter-stream ID before `BufferTooSmall` is returned.
pub fn encode_datagram(session_id: u64, payload: []const u8, output: []u8) DatagramError!usize {
    if (!valid_session_id(session_id)) return error.InvalidSessionId;
    const header_length = encode_varint(session_id / 4, output) catch |encode_error| {
        return map_varint_datagram_error(encode_error);
    };
    if (payload.len > output.len - header_length) return error.BufferTooSmall;
    @memcpy(output[header_length .. header_length + payload.len], payload);
    return header_length + payload.len;
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

/// Payload of a decoded WT_CLOSE_SESSION capsule.
pub const CloseSession = struct {
    /// Application-defined 32-bit close code.
    application_error: u32,
    /// UTF-8 reason borrowed from the decoder input.
    message: []const u8,
};

/// Unknown capsule retained for extension-aware dispatch.
pub const UnknownCapsule = struct {
    /// Unrecognized QUIC-varint capsule type.
    capsule_type: u64,
    /// Payload borrowed from the decoder input.
    payload: []const u8,
};

/// Decoded WebTransport session capsule.
///
/// Slice-bearing variants borrow the input passed to `decode_capsule`.
pub const Capsule = union(enum) {
    /// Peer requested graceful session draining.
    drain_session,
    /// Peer closed the session with an application code and reason.
    close_session: CloseSession,
    /// Peer raised the session data credit.
    max_data: u64,
    /// Peer raised the bidirectional stream credit.
    max_streams_bidi: u64,
    /// Peer raised the unidirectional stream credit.
    max_streams_uni: u64,
    /// Peer reported exhaustion of session data credit.
    data_blocked: u64,
    /// Peer reported exhaustion of bidirectional stream credit.
    streams_blocked_bidi: u64,
    /// Peer reported exhaustion of unidirectional stream credit.
    streams_blocked_uni: u64,
    /// Extension capsule not interpreted by this module.
    unknown: UnknownCapsule,
};

/// One decoded capsule and the total bytes consumed from the input.
pub const DecodedCapsule = struct {
    /// Parsed capsule value.
    capsule: Capsule,
    /// Header plus payload length, for advancing an incremental parser.
    length: usize,
};

/// Failures from WebTransport capsule coding.
pub const CapsuleError = error{
    /// The input does not contain a complete capsule.
    NeedMoreData,
    /// The encoded payload length cannot fit in `usize`.
    LengthOverflow,
    /// A known capsule carried an invalid payload length.
    InvalidLength,
    /// A close reason is not valid UTF-8.
    InvalidUtf8,
    /// A decoded stream limit exceeds `max_stream_count`.
    InvalidStreamLimit,
    /// Caller-owned output cannot hold the capsule.
    BufferTooSmall,
    /// A type, length, or value exceeds the QUIC varint range.
    ValueTooLarge,
};

/// Decodes one complete capsule without allocating.
///
/// Returned message and unknown-payload slices borrow `input` and remain valid
/// only while it does. `NeedMoreData` carries no retained parser state.
pub fn decode_capsule(input: []const u8) CapsuleError!DecodedCapsule {
    const capsule_type = decode_varint(input) catch |decode_error| return map_varint_capsule_error(decode_error);
    const encoded_length = decode_varint(input[capsule_type.length..]) catch |decode_error| {
        return map_varint_capsule_error(decode_error);
    };
    if (encoded_length.value > std.math.maxInt(usize)) return error.LengthOverflow;
    const header_length = capsule_type.length + encoded_length.length;
    const payload_length: usize = @intCast(encoded_length.value);
    if (payload_length > input.len -| header_length) return error.NeedMoreData;
    const payload = input[header_length .. header_length + payload_length];

    const capsule: Capsule = switch (capsule_type.value) {
        wt_drain_session => blk: {
            if (payload.len != 0) return error.InvalidLength;
            break :blk .drain_session;
        },
        wt_close_session => blk: {
            if (payload.len < 4 or payload.len > 4 + max_close_message_size) {
                return error.InvalidLength;
            }
            const message = payload[4..];
            if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
            const application_error_bytes: *const [4]u8 = @ptrCast(payload.ptr);
            break :blk .{ .close_session = .{
                .application_error = std.mem.readInt(u32, application_error_bytes, .big),
                .message = message,
            } };
        },
        wt_max_data => .{ .max_data = try decode_capsule_integer(payload, false) },
        wt_max_streams_bidi => .{ .max_streams_bidi = try decode_capsule_integer(payload, true) },
        wt_max_streams_uni => .{ .max_streams_uni = try decode_capsule_integer(payload, true) },
        wt_data_blocked => .{ .data_blocked = try decode_capsule_integer(payload, false) },
        wt_streams_blocked_bidi => .{ .streams_blocked_bidi = try decode_capsule_integer(payload, true) },
        wt_streams_blocked_uni => .{ .streams_blocked_uni = try decode_capsule_integer(payload, true) },
        else => .{ .unknown = .{ .capsule_type = capsule_type.value, .payload = payload } },
    };
    return .{ .capsule = capsule, .length = header_length + payload_length };
}

/// Encodes a zero-length drain capsule into caller-owned `output`.
pub fn encode_drain_session(output: []u8) CapsuleError!usize {
    return encode_capsule_header(wt_drain_session, 0, output);
}

/// Encodes a close capsule into caller-owned `output` without allocation.
///
/// `message` must be valid UTF-8 and at most `max_close_message_size` bytes.
/// A short buffer may contain a partial header on error.
pub fn encode_close_session(application_error: u32, message: []const u8, output: []u8) CapsuleError!usize {
    if (message.len > max_close_message_size) return error.InvalidLength;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
    const payload_length = 4 + message.len;
    const header_length = try encode_capsule_header(wt_close_session, payload_length, output);
    if (payload_length > output.len - header_length) return error.BufferTooSmall;
    const application_error_bytes: *[4]u8 = @ptrCast(output[header_length..].ptr);
    std.mem.writeInt(u32, application_error_bytes, application_error, .big);
    @memcpy(output[header_length + 4 .. header_length + payload_length], message);
    return header_length + payload_length;
}

/// Encodes a single-varint capsule into caller-owned `output`.
///
/// This primitive does not restrict `capsule_type` to known flow-control types
/// or apply `max_stream_count`. A short output may retain a partial header.
pub fn encode_integer_capsule(capsule_type: u64, value: u64, output: []u8) CapsuleError!usize {
    var integer: [8]u8 = undefined;
    const integer_length = encode_varint(value, &integer) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    const header_length = try encode_capsule_header(capsule_type, integer_length, output);
    if (integer_length > output.len - header_length) return error.BufferTooSmall;
    @memcpy(output[header_length .. header_length + integer_length], integer[0..integer_length]);
    return header_length + integer_length;
}

/// Mutable receive-side WebTransport session flow-control state.
pub const FlowState = struct {
    /// Current aggregate data credit.
    max_data: u64 = 0,
    /// Current bidirectional stream credit.
    max_streams_bidi: u64 = 0,
    /// Current unidirectional stream credit.
    max_streams_uni: u64 = 0,
    /// Whether the peer sent WT_DRAIN_SESSION.
    draining: bool = false,
    /// Whether the peer sent WT_CLOSE_SESSION.
    closed: bool = false,
};

/// Dispatch result after applying a decoded capsule.
pub const CapsuleAction = enum(u8) {
    /// The capsule changed session state.
    applied,
    /// The capsule is unknown or flow control is disabled.
    ignored,
    /// The peer reported a flow-control blocked condition.
    peer_blocked,
};

/// Semantic failures while applying session flow-control capsules.
pub const FlowError = error{
    /// A credit failed to increase monotonically or exceeded its limit.
    FlowControlViolation,
};

/// Applies one capsule to caller-owned session flow state.
///
/// Drain and close capsules apply regardless of `enabled`. Disabled flow
/// control ignores all credit and blocked capsules. Errors leave the targeted
/// credit unchanged.
pub fn apply_capsule(state: *FlowState, capsule: Capsule, enabled: bool) FlowError!CapsuleAction {
    return switch (capsule) {
        .drain_session => blk: {
            state.draining = true;
            break :blk .applied;
        },
        .close_session => blk: {
            state.closed = true;
            break :blk .applied;
        },
        .max_data => |value| if (!enabled)
            .ignored
        else blk: {
            if (value <= state.max_data) return error.FlowControlViolation;
            state.max_data = value;
            break :blk .applied;
        },
        .max_streams_bidi => |value| if (!enabled)
            .ignored
        else blk: {
            if (value > max_stream_count or value <= state.max_streams_bidi) {
                return error.FlowControlViolation;
            }
            state.max_streams_bidi = value;
            break :blk .applied;
        },
        .max_streams_uni => |value| if (!enabled)
            .ignored
        else blk: {
            if (value > max_stream_count or value <= state.max_streams_uni) {
                return error.FlowControlViolation;
            }
            state.max_streams_uni = value;
            break :blk .applied;
        },
        .data_blocked, .streams_blocked_bidi, .streams_blocked_uni => if (enabled)
            .peer_blocked
        else
            .ignored,
        .unknown => .ignored,
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

/// Returns whether an ID can identify a client-initiated bidirectional stream.
pub fn valid_session_id(session_id: u64) bool {
    return session_id <= max_quic_varint and session_id & 0x03 == 0;
}

fn flow_control_requested(settings: Settings) bool {
    return settings.initial_max_data != 0 or
        settings.initial_max_streams_uni != 0 or
        settings.initial_max_streams_bidi != 0;
}

const SettingKind = enum(u8) {
    wt_enabled,
    connect,
    datagram,
    max_data,
    max_streams_uni,
    max_streams_bidi,
};

const SettingField = struct {
    kind: SettingKind,
    bit: u3,
};

fn setting_field(identifier: u64) ?SettingField {
    return switch (identifier) {
        settings_wt_enabled => .{ .kind = .wt_enabled, .bit = 0 },
        settings_enable_connect_protocol => .{ .kind = .connect, .bit = 1 },
        settings_h3_datagram => .{ .kind = .datagram, .bit = 2 },
        settings_wt_initial_max_data => .{ .kind = .max_data, .bit = 3 },
        settings_wt_initial_max_streams_uni => .{ .kind = .max_streams_uni, .bit = 4 },
        settings_wt_initial_max_streams_bidi => .{ .kind = .max_streams_bidi, .bit = 5 },
        else => null,
    };
}

fn encode_setting_pair(identifier: u64, value: u64, output: []u8) VarintError!usize {
    const identifier_length = try encode_varint(identifier, output);
    const value_length = try encode_varint(value, output[identifier_length..]);
    return identifier_length + value_length;
}

fn encode_stream_header(prefix: u64, session_id: u64, output: []u8) StreamHeaderError!usize {
    const prefix_length = encode_varint(prefix, output) catch |encode_error| {
        return map_varint_stream_error(encode_error);
    };
    const session_length = encode_varint(session_id, output[prefix_length..]) catch |encode_error| {
        return map_varint_stream_error(encode_error);
    };
    return prefix_length + session_length;
}

fn decode_capsule_integer(payload: []const u8, stream_limit: bool) CapsuleError!u64 {
    const value = decode_varint(payload) catch |decode_error| return map_varint_capsule_error(decode_error);
    if (value.length != payload.len) return error.InvalidLength;
    if (stream_limit and value.value > max_stream_count) return error.InvalidStreamLimit;
    return value.value;
}

fn encode_capsule_header(capsule_type: u64, payload_length: usize, output: []u8) CapsuleError!usize {
    const type_length = encode_varint(capsule_type, output) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    const length_length = encode_varint(payload_length, output[type_length..]) catch |encode_error| {
        return map_varint_capsule_error(encode_error);
    };
    return type_length + length_length;
}

fn map_varint_stream_error(varint_error: VarintError) StreamHeaderError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}

fn map_varint_datagram_error(varint_error: VarintError) DatagramError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}

fn map_varint_capsule_error(varint_error: VarintError) CapsuleError {
    return switch (varint_error) {
        error.NeedMoreData => error.NeedMoreData,
        error.BufferTooSmall => error.BufferTooSmall,
        error.ValueTooLarge => error.ValueTooLarge,
    };
}
