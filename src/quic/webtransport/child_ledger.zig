const max_varint: u64 = (1 << 62) - 1;

/// Native receive facts; unknown sizes stay absent rather than becoming zero.
pub const ReceiveSnapshot = struct {
    final_size: ?u64 = null,
    reliable_size: ?u64 = null,
    reset_error: ?u64 = null,
    reset_visible: bool = false,
    stop_error: ?u64 = null,
    fin_received: bool = false,
    read_cancelled: bool = false,
};

/// Final gaps are a subset of accounted bytes, never another amount to add.
pub const AccountingDelta = struct {
    accounted_bytes: u64 = 0,
    final_gap_bytes: u64 = 0,
};

/// EOF and visible reset share one receive-terminal notification.
pub const ReceiveTerminal = enum(u8) { none, eof, reset };
/// Native close preserves known final accounting or abandons an unknown size.
pub const CloseState = enum(u8) { final_known, abandoned };
/// Invalid transitions preserve every ledger field.
pub const LedgerError = error{
    InvalidSnapshot,
    InvalidPrefix,
    FinalSizeChanged,
    FinalSizeBelowRead,
    FinalSizeBelowPrefix,
    ErrorCodeChanged,
    SizeOverflow,
    ReceiveComplete,
    IncompleteEof,
    Closed,
};

pub fn snapshot_valid(snapshot: ReceiveSnapshot) bool {
    if ((snapshot.final_size == null) != (snapshot.reliable_size == null)) return false;
    if (snapshot.final_size) |size| {
        if (size > max_varint or snapshot.reliable_size.? > size) return false;
    }
    if (snapshot.reset_error) |code| {
        if (code > max_varint or snapshot.final_size == null) return false;
    }
    if (snapshot.stop_error) |code| if (code > max_varint) return false;
    if (snapshot.reset_visible and snapshot.reset_error == null) return false;
    if (!snapshot.fin_received) return true;
    if (snapshot.final_size == null) return false;
    return snapshot.reset_error != null or snapshot.reliable_size.? == snapshot.final_size.?;
}

/// Caller-owned receive accounting; initialize before observing native facts.
pub const Ledger = struct {
    receive_prefix_size: u8,
    payload_read: u64 = 0,
    accounted_bytes: u64 = 0,
    final_size: ?u64 = null,
    final_payload_size: ?u64 = null,
    reliable_size: ?u64 = null,
    reset_error: ?u64 = null,
    stop_error: ?u64 = null,
    reset_visible: bool = false,
    fin_received: bool = false,
    read_cancelled: bool = false,
    receive_terminal: ReceiveTerminal = .none,
    stop_delivered: bool = false,
    closed: bool = false,

    /// Only the prefix on the receive half is excluded from transport offsets.
    pub fn init(receive_prefix_size: u8) LedgerError!Ledger {
        if (receive_prefix_size != 0 and (receive_prefix_size < 3 or receive_prefix_size > 16)) return error.InvalidPrefix;
        return .{ .receive_prefix_size = receive_prefix_size };
    }

    /// Records actual payload reads, including reads after final accounting.
    pub fn record_read(ledger: *Ledger, payload_bytes: u64) LedgerError!AccountingDelta {
        if (ledger.closed) return error.Closed;
        if (ledger.receive_terminal != .none and payload_bytes != 0) return error.ReceiveComplete;
        if (payload_bytes > max_varint - ledger.receive_prefix_size - ledger.payload_read) return error.SizeOverflow;
        const total = ledger.payload_read + payload_bytes;
        if (ledger.final_payload_size) |final| if (total > final) return error.FinalSizeBelowRead;
        const accounted = if (ledger.final_payload_size != null) ledger.accounted_bytes else total;
        const delta = accounted - ledger.accounted_bytes;
        ledger.payload_read = total;
        ledger.accounted_bytes = accounted;
        return .{ .accounted_bytes = delta };
    }

    /// Final size and error codes are immutable; reliable boundaries may shrink.
    pub fn observe(ledger: *Ledger, snapshot: ReceiveSnapshot) LedgerError!AccountingDelta {
        if (ledger.closed) return error.Closed;
        if (!snapshot_valid(snapshot)) return error.InvalidSnapshot;
        if (ledger.reset_error) |code| {
            if (snapshot.reset_error != null and snapshot.reset_error.? != code) return error.ErrorCodeChanged;
        }
        if (ledger.stop_error) |code| {
            if (snapshot.stop_error != null and snapshot.stop_error.? != code) return error.ErrorCodeChanged;
        }
        var final_payload = ledger.final_payload_size;
        if (snapshot.final_size) |size| {
            if (ledger.final_size != null and ledger.final_size.? != size) return error.FinalSizeChanged;
            if (size < ledger.receive_prefix_size) return error.FinalSizeBelowPrefix;
            final_payload = size - ledger.receive_prefix_size;
            if (final_payload.? < ledger.payload_read) return error.FinalSizeBelowRead;
        }
        const accounted = final_payload orelse ledger.payload_read;
        const delta = accounted - ledger.accounted_bytes;
        ledger.final_size = ledger.final_size orelse snapshot.final_size;
        ledger.final_payload_size = final_payload;
        if (snapshot.reliable_size) |size| ledger.reliable_size = @min(ledger.reliable_size orelse size, size);
        ledger.reset_error = ledger.reset_error orelse snapshot.reset_error;
        ledger.stop_error = ledger.stop_error orelse snapshot.stop_error;
        ledger.reset_visible = ledger.reset_visible or snapshot.reset_visible;
        ledger.fin_received = ledger.fin_received or snapshot.fin_received;
        ledger.read_cancelled = ledger.read_cancelled or snapshot.read_cancelled;
        ledger.accounted_bytes = accounted;
        return .{ .accounted_bytes = delta, .final_gap_bytes = delta };
    }

    /// Known-but-hidden resets cannot publish a receive-terminal event.
    pub fn take_reset(ledger: *Ledger) ?u64 {
        if (ledger.closed or !ledger.reset_visible or ledger.receive_terminal != .none) return null;
        const code = ledger.reset_error orelse return null;
        ledger.receive_terminal = .reset;
        return code;
    }

    /// STOP terminates sending independently of EOF or reset on receiving.
    pub fn take_stop(ledger: *Ledger) ?u64 {
        if (ledger.closed or ledger.stop_delivered) return null;
        const code = ledger.stop_error orelse return null;
        ledger.stop_delivered = true;
        return code;
    }

    /// The caller must have received native read zero; a FIN flag is insufficient.
    pub fn record_eof(ledger: *Ledger) LedgerError!bool {
        if (ledger.closed) return error.Closed;
        const final = ledger.final_payload_size orelse return error.IncompleteEof;
        if (ledger.payload_read != final) return error.IncompleteEof;
        if (ledger.receive_terminal != .none) return false;
        ledger.receive_terminal = .eof;
        return true;
    }

    /// Only native on-close or connection destruction may end observation.
    pub fn close(ledger: *Ledger) CloseState {
        ledger.closed = true;
        return if (ledger.final_size != null) .final_known else .abandoned;
    }
};
