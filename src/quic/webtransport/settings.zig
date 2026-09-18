const varint = @import("varint.zig");
const session = @import("session.zig");

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

/// Draft transport parameter enabling RESET_STREAM_AT.
pub const reset_stream_at_parameter: u64 = 0x1d;
/// Draft QUIC RESET_STREAM_AT frame type.
pub const reset_stream_at_frame: u64 = 0x24;

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
            if (value > session.max_stream_count) return error.InvalidStreamLimit;
            next.initial_max_streams_uni = value;
        },
        .max_streams_bidi => {
            if (value > session.max_stream_count) return error.InvalidStreamLimit;
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
        const identifier = varint.decode_varint(payload[offset..]) catch return error.TruncatedSettings;
        offset += identifier.length;
        const value = varint.decode_varint(payload[offset..]) catch return error.TruncatedSettings;
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
pub fn encode_server_settings(settings: Settings, output: []u8) varint.VarintError!usize {
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

fn encode_setting_pair(identifier: u64, value: u64, output: []u8) varint.VarintError!usize {
    const identifier_length = try varint.encode_varint(identifier, output);
    const value_length = try varint.encode_varint(value, output[identifier_length..]);
    return identifier_length + value_length;
}
