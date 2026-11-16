const c = @import("c");
const child_ledger = @import("child_ledger.zig");

/// Compile-time native contract presence, independent of listener activation.
pub const available = contract_available();

const max_varint = (@as(u64, 1) << 62) - 1;
const max_stream_count = @as(u64, 1) << 60;
const max_prefix_size = 16;

/// Query status; every result except `ok` preserves the caller's output.
pub const QueryResult = enum(u8) {
    ok,
    pending,
    invalid,
    unsupported,
};

/// Immediate creation or CONNECT marking; failures never queue a stream.
pub const CreateResult = enum(u8) {
    ok,
    blocked,
    unsupported,
    closed,
    out_of_memory,
    invalid,
    no_session,
};

/// Configuration validation is completed before any native field changes.
pub const ConfigureResult = enum(u8) {
    ok,
    invalid,
    unsupported,
};

/// A blocked reset retains its requested error until native write credit resumes.
pub const ResetResult = enum(u8) { ok, blocked, unsupported, invalid, closed };

/// Receive cancellation retains its error independently of the sending half.
pub const StopResult = enum(u8) { ok, blocked, unsupported, invalid, closed };

/// Role of the endpoint checking its peer's prerequisites.
pub const EndpointRole = enum(u8) { client, server };

/// Association represented by a completed native stream snapshot.
pub const Association = enum(u8) { connect, child };

/// Child direction; CONNECT always uses `bidi`.
pub const Direction = enum(u8) { bidi, uni };

/// Endpoint that initiated the QUIC stream, including its association prefix.
pub const Initiator = enum(u8) { local, peer };

/// Completed peer advertisements; transport flags report presence, not sizes.
pub const Peer = struct {
    initial_max_data: u64 = 0,
    initial_max_streams_bidi: u64 = 0,
    initial_max_streams_uni: u64 = 0,
    wt_enabled: bool = false,
    extended_connect: bool = false,
    http_datagram: bool = false,
    quic_datagram: bool = false,
    reliable_reset: bool = false,
};

/// Caller-owned metadata with a validated session ID and directional prefixes.
pub const StreamInfo = struct {
    session_id: u64 = 0,
    send_prefix_size: u8 = 0,
    receive_prefix_size: u8 = 0,
    association: Association = .connect,
    direction: Direction = .bidi,
    initiator: Initiator = .peer,
};

/// Copied receive facts distinguish known RESET metadata from delivery.
pub const ReceiveSnapshot = child_ledger.ReceiveSnapshot;

/// Advertised session limits; all zero selects single-session operation.
pub const LocalLimits = struct {
    initial_max_data: u64 = 0,
    initial_max_streams_bidi: u64 = 0,
    initial_max_streams_uni: u64 = 0,
};

/// Quiescent notification after validated peer SETTINGS and live parameters.
pub const SettingsCallback = *const fn (?*c.lsquic_conn) callconv(.c) void;

/// Quiescent child notification after native application context creation.
pub const ChildCallback = *const fn (?*c.lsquic_stream, ?*c.lsquic_stream_ctx) callconv(.c) void;

/// Explicit callbacks installed only when the full native contract is present.
pub const Callbacks = struct {
    settings: SettingsCallback,
    child: ChildCallback,
};

/// Copies peer facts only after native negotiation completes.
///
/// No native pointer is retained. The connection must still be valid, including
/// during its close callback; an `ok` snapshot does not authorize a session.
pub fn read_peer(connection: ?*c.lsquic_conn, output: *Peer) QueryResult {
    if (comptime !available) return .unsupported;
    var native: c.struct_lsquic_webtransport_peer = undefined;
    const result = c.lsquic_conn_get_webtransport_peer(connection, &native);
    switch (result) {
        c.LSQUIC_WTP_OK => {},
        c.LSQUIC_WTP_PENDING => return .pending,
        c.LSQUIC_WTP_UNSUPPORTED => return .unsupported,
        else => return .invalid,
    }
    const known_flags: c_uint = c.LSQUIC_WTP_WT_ENABLED | c.LSQUIC_WTP_CONNECT |
        c.LSQUIC_WTP_H3_DATAGRAM | c.LSQUIC_WTP_QUIC_DATAGRAM | c.LSQUIC_WTP_RELIABLE_RESET;
    if (native.flags & ~known_flags != 0 or
        !limits_valid(native.initial_max_data, native.initial_max_streams_bidi, native.initial_max_streams_uni))
    {
        return .invalid;
    }
    output.* = .{
        .initial_max_data = native.initial_max_data,
        .initial_max_streams_bidi = native.initial_max_streams_bidi,
        .initial_max_streams_uni = native.initial_max_streams_uni,
        .wt_enabled = native.flags & c.LSQUIC_WTP_WT_ENABLED != 0,
        .extended_connect = native.flags & c.LSQUIC_WTP_CONNECT != 0,
        .http_datagram = native.flags & c.LSQUIC_WTP_H3_DATAGRAM != 0,
        .quic_datagram = native.flags & c.LSQUIC_WTP_QUIC_DATAGRAM != 0,
        .reliable_reset = native.flags & c.LSQUIC_WTP_RELIABLE_RESET != 0,
    };
    return .ok;
}

/// Copies complete association metadata while its native stream remains valid.
///
/// `pending` does not promise later WebTransport classification. The copied
/// value survives close; querying the native pointer after close is invalid.
/// An `ok` child snapshot may precede its quiescent typed notification.
pub fn read_stream(stream: ?*c.lsquic_stream, output: *StreamInfo) QueryResult {
    if (comptime !available) return .unsupported;
    var native: c.struct_lsquic_webtransport_stream_info = undefined;
    const result = c.lsquic_stream_get_webtransport_info(stream, &native);
    switch (result) {
        c.LSQUIC_WTS_OK => {},
        c.LSQUIC_WTS_PENDING => return .pending,
        c.LSQUIC_WTS_UNSUPPORTED => return .unsupported,
        else => return .invalid,
    }
    const known_flags: c_uint = c.LSQUIC_WTSF_CONNECT | c.LSQUIC_WTSF_CHILD |
        c.LSQUIC_WTSF_LOCAL | c.LSQUIC_WTSF_UNI;
    if (native.flags & ~known_flags != 0 or
        native.session_id > max_varint or native.session_id & 3 != 0 or
        native.send_prefix_size > max_prefix_size or native.receive_prefix_size > max_prefix_size)
    {
        return .invalid;
    }
    const association: Association = switch (native.flags & (c.LSQUIC_WTSF_CONNECT | c.LSQUIC_WTSF_CHILD)) {
        c.LSQUIC_WTSF_CONNECT => .connect,
        c.LSQUIC_WTSF_CHILD => .child,
        else => return .invalid,
    };
    const info: StreamInfo = .{
        .session_id = native.session_id,
        .send_prefix_size = @intCast(native.send_prefix_size),
        .receive_prefix_size = @intCast(native.receive_prefix_size),
        .association = association,
        .direction = if (native.flags & c.LSQUIC_WTSF_UNI != 0) .uni else .bidi,
        .initiator = if (native.flags & c.LSQUIC_WTSF_LOCAL != 0) .local else .peer,
    };
    if (!stream_info_valid(info)) return .invalid;
    output.* = info;
    return .ok;
}

/// Copies validated receive metadata while the native stream is still valid.
///
/// STOP does not imply a final size, and FIN receipt does not imply read EOF.
/// The caller may query during `on_close`, but never after that callback.
pub fn read_receive(stream: ?*c.lsquic_stream, output: *ReceiveSnapshot) QueryResult {
    if (comptime !available) return .unsupported;
    var native: c.struct_lsquic_stream_recv_state = undefined;
    switch (c.lsquic_stream_get_recv_state(stream, &native)) {
        c.LSQUIC_SRG_OK => {},
        c.LSQUIC_SRG_UNSUPPORTED => return .unsupported,
        else => return .invalid,
    }
    const known_flags: c_uint = c.LSQUIC_SRS_FINAL_SIZE_KNOWN | c.LSQUIC_SRS_RESET_KNOWN |
        c.LSQUIC_SRS_RELIABLE_RESET_SEEN | c.LSQUIC_SRS_RESET_VISIBLE |
        c.LSQUIC_SRS_STOP_SENDING_KNOWN | c.LSQUIC_SRS_FIN_RECEIVED | c.LSQUIC_SRS_READ_CANCELED;
    if (native.flags & ~known_flags != 0) return .invalid;
    const final_known = native.flags & c.LSQUIC_SRS_FINAL_SIZE_KNOWN != 0;
    const reset_known = native.flags & c.LSQUIC_SRS_RESET_KNOWN != 0;
    const stop_known = native.flags & c.LSQUIC_SRS_STOP_SENDING_KNOWN != 0;
    if ((!final_known and (native.final_size != 0 or native.reliable_size != 0)) or
        (!reset_known and native.reset_error_code != 0) or
        (!stop_known and native.stop_error_code != 0) or
        (!reset_known and native.flags & c.LSQUIC_SRS_RELIABLE_RESET_SEEN != 0)) return .invalid;
    const snapshot: ReceiveSnapshot = .{
        .final_size = if (final_known) native.final_size else null,
        .reliable_size = if (final_known) native.reliable_size else null,
        .reset_error = if (reset_known) native.reset_error_code else null,
        .reset_visible = native.flags & c.LSQUIC_SRS_RESET_VISIBLE != 0,
        .stop_error = if (stop_known) native.stop_error_code else null,
        .fin_received = native.flags & c.LSQUIC_SRS_FIN_RECEIVED != 0,
        .read_cancelled = native.flags & c.LSQUIC_SRS_READ_CANCELED != 0,
    };
    if (!child_ledger.snapshot_valid(snapshot)) return .invalid;
    output.* = snapshot;
    return .ok;
}

/// Asserts application admission; native HTTP framing remains active for capsules.
pub fn accept_connect(stream: ?*c.lsquic_stream) CreateResult {
    if (comptime !available) return .unsupported;
    return create_result(c.lsquic_stream_accept_webtransport(stream));
}

/// Creates one child synchronously; the caller owns session-flow reservation.
pub fn create_child(connection: ?*c.lsquic_conn, session_id: u64, direction: Direction) CreateResult {
    if (comptime !available) return .unsupported;
    const kind: c.enum_lsquic_webtransport_stream_kind = switch (direction) {
        .bidi => c.LSQUIC_WTS_BIDI,
        .uni => c.LSQUIC_WTS_UNI,
    };
    return create_result(c.lsquic_conn_make_webtransport_stream(connection, session_id, kind));
}

/// Zero uses ordinary RESET_STREAM; native children preserve their prefix floor.
pub fn reset_stream(stream: ?*c.lsquic_stream, application_error: u64) ResetResult {
    if (comptime !available) return .unsupported;
    return switch (c.lsquic_stream_reset_at(stream, application_error, 0)) {
        c.LSQUIC_SRA_OK => .ok,
        c.LSQUIC_SRA_BLOCKED => .blocked,
        c.LSQUIC_SRA_UNSUPPORTED => .unsupported,
        c.LSQUIC_SRA_CLOSED => .closed,
        else => .invalid,
    };
}

/// Cancels receiving with the exact QUIC error while preserving local writes.
///
/// A successful call queues STOP even for an unread received FIN. Unknown
/// final size still requires retaining the native stream until `on_close`.
pub fn stop_receiving(stream: ?*c.lsquic_stream, application_error: u64) StopResult {
    if (comptime !available) return .unsupported;
    return switch (c.lsquic_stream_stop_sending(stream, application_error)) {
        c.LSQUIC_SST_OK => .ok,
        c.LSQUIC_SST_BLOCKED => .blocked,
        c.LSQUIC_SST_UNSUPPORTED => .unsupported,
        c.LSQUIC_SST_CLOSED => .closed,
        else => .invalid,
    };
}

/// Known cancellation prevents admission even before its reset callback is due.
pub fn admission_canceled(stream: ?*c.lsquic_stream) bool {
    if (comptime !available) return false;
    var state: c.struct_lsquic_stream_recv_state = undefined;
    if (c.lsquic_stream_get_recv_state(stream, &state) != c.LSQUIC_SRG_OK) return true;
    return state.flags & (c.LSQUIC_SRS_RESET_KNOWN | c.LSQUIC_SRS_STOP_SENDING_KNOWN |
        c.LSQUIC_SRS_READ_CANCELED) != 0;
}

/// Enables native draft-16 negotiation with bounded session limits.
///
/// The caller supplies an HTTP engine and its datagram callback. No listener
/// policy or application admission is enabled by changing these settings.
pub fn configure(settings: *c.lsquic_engine_settings, limits: LocalLimits) ConfigureResult {
    if (comptime !available) return .unsupported;
    if (!limits_valid(limits.initial_max_data, limits.initial_max_streams_bidi, limits.initial_max_streams_uni)) {
        return .invalid;
    }
    settings.es_datagrams = 1;
    settings.es_reset_stream_at = 1;
    settings.es_webtransport = .{
        .initial_max_data = limits.initial_max_data,
        .initial_max_streams_bidi = limits.initial_max_streams_bidi,
        .initial_max_streams_uni = limits.initial_max_streams_uni,
        .enabled = 1,
    };
    return .ok;
}

/// Installs the two optional callbacks atomically, preserving older interfaces.
pub fn install_callbacks(interface: *c.lsquic_stream_if, callbacks: Callbacks) bool {
    if (comptime !available) return false;
    interface.on_h3_settings = callbacks.settings;
    interface.on_webtransport_stream = callbacks.child;
    return true;
}

/// Checks the role-specific prerequisite set, independently of local admission.
pub fn peer_requirements_met(peer: Peer, role: EndpointRole) bool {
    if (!peer.wt_enabled or !peer.http_datagram or !peer.quic_datagram or !peer.reliable_reset) return false;
    return role == .server or peer.extended_connect;
}

fn limits_valid(data: u64, bidi: u64, uni: u64) bool {
    return data <= max_varint and bidi <= max_stream_count and uni <= max_stream_count;
}

fn stream_info_valid(info: StreamInfo) bool {
    if (info.association == .connect) {
        return info.direction == .bidi and info.send_prefix_size == 0 and info.receive_prefix_size == 0;
    }
    const prefix = if (info.initiator == .local) info.send_prefix_size else info.receive_prefix_size;
    const other = if (info.initiator == .local) info.receive_prefix_size else info.send_prefix_size;
    return prefix >= 3 and other == 0;
}

fn create_result(result: c_int) CreateResult {
    return switch (result) {
        c.LSQUIC_MWTS_OK => .ok,
        c.LSQUIC_MWTS_BLOCKED => .blocked,
        c.LSQUIC_MWTS_UNSUPPORTED => .unsupported,
        c.LSQUIC_MWTS_CLOSED => .closed,
        c.LSQUIC_MWTS_NOMEM => .out_of_memory,
        c.LSQUIC_MWTS_NO_SESSION => .no_session,
        else => .invalid,
    };
}

fn contract_available() bool {
    const declarations = [_][]const u8{
        "lsquic_conn_get_webtransport_peer",
        "lsquic_stream_get_webtransport_info",
        "lsquic_stream_accept_webtransport",
        "lsquic_conn_make_webtransport_stream",
        "lsquic_stream_reset_at",
        "lsquic_stream_stop_sending",
        "lsquic_stream_get_recv_state",
        "lsquic_stream_get_reset_error",
        "struct_lsquic_stream_recv_state",
        "LSQUIC_SRG_OK",
        "LSQUIC_SRG_UNSUPPORTED",
        "LSQUIC_SRS_FINAL_SIZE_KNOWN",
        "LSQUIC_SRS_RESET_KNOWN",
        "LSQUIC_SRS_RELIABLE_RESET_SEEN",
        "LSQUIC_SRS_RESET_VISIBLE",
        "LSQUIC_SRS_STOP_SENDING_KNOWN",
        "LSQUIC_SRS_FIN_RECEIVED",
        "LSQUIC_SRS_READ_CANCELED",
        "LSQUIC_SRA_OK",
        "LSQUIC_SRA_BLOCKED",
        "LSQUIC_SRA_UNSUPPORTED",
        "LSQUIC_SRA_CLOSED",
        "LSQUIC_SST_OK",
        "LSQUIC_SST_BLOCKED",
        "LSQUIC_SST_UNSUPPORTED",
        "LSQUIC_SST_INVALID",
        "LSQUIC_SST_CLOSED",
        "struct_lsquic_webtransport_peer",
        "struct_lsquic_webtransport_stream_info",
        "enum_lsquic_webtransport_stream_kind",
        "LSQUIC_WTP_OK",
        "LSQUIC_WTP_PENDING",
        "LSQUIC_WTP_UNSUPPORTED",
        "LSQUIC_WTP_WT_ENABLED",
        "LSQUIC_WTP_CONNECT",
        "LSQUIC_WTP_H3_DATAGRAM",
        "LSQUIC_WTP_QUIC_DATAGRAM",
        "LSQUIC_WTP_RELIABLE_RESET",
        "LSQUIC_WTS_OK",
        "LSQUIC_WTS_PENDING",
        "LSQUIC_WTS_UNSUPPORTED",
        "LSQUIC_WTSF_CONNECT",
        "LSQUIC_WTSF_CHILD",
        "LSQUIC_WTSF_LOCAL",
        "LSQUIC_WTSF_UNI",
        "LSQUIC_WTS_BIDI",
        "LSQUIC_WTS_UNI",
        "LSQUIC_MWTS_OK",
        "LSQUIC_MWTS_BLOCKED",
        "LSQUIC_MWTS_UNSUPPORTED",
        "LSQUIC_MWTS_CLOSED",
        "LSQUIC_MWTS_NOMEM",
        "LSQUIC_MWTS_NO_SESSION",
    };
    inline for (declarations) |name| {
        if (!@hasDecl(c, name)) return false;
    }
    inline for (.{ "final_size", "reliable_size", "reset_error_code", "stop_error_code", "flags" }) |name| {
        if (!@hasField(c.struct_lsquic_stream_recv_state, name)) return false;
    }
    if (!@hasField(c.lsquic_stream_if, "on_h3_settings") or
        !@hasField(c.lsquic_stream_if, "on_webtransport_stream") or
        !@hasField(c.lsquic_engine_settings, "es_reset_stream_at") or
        !@hasField(c.lsquic_engine_settings, "es_webtransport")) return false;
    const NativeLimits = @FieldType(c.lsquic_engine_settings, "es_webtransport");
    return @hasField(NativeLimits, "enabled") and
        @hasField(NativeLimits, "initial_max_data") and
        @hasField(NativeLimits, "initial_max_streams_bidi") and
        @hasField(NativeLimits, "initial_max_streams_uni");
}
