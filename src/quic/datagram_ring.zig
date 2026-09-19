//! Bounded SoA queue for unreliable WebTransport datagrams.
//!
//! The ring owns no memory: `init` binds caller-provided metadata arrays and a
//! contiguous payload slab, so one application slab can be carved into a ring
//! per connection without a per-datagram allocation. Metadata is stored as
//! parallel arrays and every payload is copied into a fixed stride.
//!
//! `head` and `tail` are wrapping u32 cursors; the live length is
//! `tail -% head`, which stays correct across cursor rollover. Capacity is
//! fixed at init and must fit the u32 cursor range. The value is a cursor pair
//! over caller storage, so do not copy it after mutation.

const std = @import("std");

/// Payload and metadata offered to `push`.
pub const Datagram = struct {
    session_id: u64,
    sequence_number: u64,
    /// Bytes are copied into the ring slot, not retained.
    payload: []const u8,
};

/// Borrowed datagram returned by `peek` and `pop`.
///
/// `payload` points into the ring's caller-owned payload slab and stays valid
/// until its slot is reused or the ring is cleared.
pub const DatagramView = struct {
    session_id: u64,
    sequence_number: u64,
    payload: []const u8,
};

/// Construction and enqueue failures.
pub const Error = error{
    /// Metadata slice lengths disagree, capacity is zero, or capacity exceeds
    /// the u32 cursor range.
    InvalidCapacity,
    /// `payload_stride` is zero, exceeds the u32 length bound, overflows
    /// `capacity * payload_stride`, or does not fit `payload_storage`.
    InvalidStride,
    /// No free slot remains.
    Full,
    /// The payload is longer than `payload_stride`.
    PayloadTooLarge,
};

/// Fixed-capacity FIFO for WebTransport datagrams.
pub const DatagramRing = struct {
    /// Session id per slot; entries below `len` are valid.
    session_ids: []u64,
    /// Application sequence number per slot.
    sequence_numbers: []u64,
    /// Initialized payload byte count per slot.
    payload_lengths: []u32,
    /// Fixed-stride payload region; slot `n` starts at `n * payload_stride`.
    payload_storage: []u8,
    /// Reserved bytes per payload slot.
    payload_stride: usize,
    /// Oldest live slot cursor.
    head: u32 = 0,
    /// Next free slot cursor.
    tail: u32 = 0,
    /// Datagrams discarded because the queue was full; survives `clear`.
    dropped: u64 = 0,

    /// Binds caller storage and validates the ring geometry.
    ///
    /// The metadata slices must share a nonzero length and `payload_storage`
    /// must hold `capacity * payload_stride` bytes. No memory changes owner.
    pub fn init(
        session_ids: []u64,
        sequence_numbers: []u64,
        payload_lengths: []u32,
        payload_storage: []u8,
        payload_stride: usize,
    ) Error!DatagramRing {
        const slot_count = session_ids.len;
        if (slot_count == 0) return error.InvalidCapacity;
        if (sequence_numbers.len != slot_count or payload_lengths.len != slot_count) {
            return error.InvalidCapacity;
        }
        // The u32 cursors cannot address more slots than a u32 length.
        if (std.math.cast(u32, slot_count) == null) return error.InvalidCapacity;
        if (payload_stride == 0) return error.InvalidStride;
        if (std.math.cast(u32, payload_stride) == null) return error.InvalidStride;

        const required = std.math.mul(usize, slot_count, payload_stride) catch {
            return error.InvalidStride;
        };
        if (payload_storage.len < required) return error.InvalidStride;

        return .{
            .session_ids = session_ids,
            .sequence_numbers = sequence_numbers,
            .payload_lengths = payload_lengths,
            .payload_storage = payload_storage,
            .payload_stride = payload_stride,
        };
    }

    /// Slot count fixed by `init`.
    pub fn capacity(self: *const @This()) usize {
        return self.session_ids.len;
    }

    /// Number of queued datagrams.
    pub fn len(self: *const @This()) usize {
        // The wrapping difference is exact while the live count fits the u32
        // cursor range, which init enforces.
        return @as(usize, self.tail -% self.head);
    }

    /// Whether no datagrams are queued.
    pub fn is_empty(self: *const @This()) bool {
        return self.head == self.tail;
    }

    /// Whether the next `push` would report `error.Full`.
    pub fn is_full(self: *const @This()) bool {
        return self.len() == self.capacity();
    }

    /// Makes every slot reusable. `dropped` is a lifetime counter.
    pub fn clear(self: *@This()) void {
        self.head = 0;
        self.tail = 0;
    }

    /// Copies `value` into the next free slot or reports `error.Full`.
    ///
    /// `value.payload` must not overlap `payload_storage`; `@memcpy` rejects
    /// overlapping ranges in safety-checked builds.
    pub fn push(self: *@This(), value: Datagram) Error!void {
        // Validate size before fullness so a drop policy never evicts a slot
        // for a datagram that cannot be stored.
        if (value.payload.len > self.payload_stride) return error.PayloadTooLarge;
        if (self.is_full()) return error.Full;

        self.write_slot(self.tail, value);
        self.tail +%= 1;
    }

    /// Drops the oldest queued datagram when full, then pushes `value`.
    ///
    /// The evicted datagram increments `dropped`. An oversized payload is
    /// rejected before anything is evicted.
    pub fn push_dropping_oldest(self: *@This(), value: Datagram) Error!void {
        if (value.payload.len > self.payload_stride) return error.PayloadTooLarge;
        if (self.is_full()) {
            self.head +%= 1;
            self.dropped +%= 1;
        }

        self.write_slot(self.tail, value);
        self.tail +%= 1;
    }

    /// Returns the oldest queued datagram without removing it.
    pub fn peek(self: *const @This()) ?DatagramView {
        if (self.is_empty()) return null;
        return self.view_at(self.slot_index(self.head));
    }

    /// Removes and returns the oldest queued datagram.
    ///
    /// The returned payload remains valid until its slot is reused.
    pub fn pop(self: *@This()) ?DatagramView {
        const view = self.peek() orelse return null;
        self.head +%= 1;
        return view;
    }

    /// Counts a datagram discarded by the caller because the queue was full.
    pub fn note_dropped(self: *@This()) void {
        self.dropped +%= 1;
    }

    /// Maps a wrapping cursor onto a slot.
    ///
    /// Power-of-two capacities use a mask instead of division; the branch is
    /// decided per call so the ring carries no derived mask state.
    fn slot_index(self: *const @This(), index: u32) usize {
        const slot_count = self.capacity();
        if (std.math.isPowerOfTwo(slot_count)) {
            return @as(usize, index) & (slot_count - 1);
        }
        return @as(usize, index) % slot_count;
    }

    /// Copies one datagram into the slot selected by `cursor`.
    fn write_slot(self: *@This(), cursor: u32, value: Datagram) void {
        const slot = self.slot_index(cursor);
        const offset = slot * self.payload_stride;
        self.session_ids[slot] = value.session_id;
        self.sequence_numbers[slot] = value.sequence_number;
        // push limits the payload to `payload_stride`, which is u32-bounded.
        self.payload_lengths[slot] = @intCast(value.payload.len);
        @memcpy(self.payload_storage[offset .. offset + value.payload.len], value.payload);
    }

    /// Builds a borrowed view of the slot selected by `slot`.
    fn view_at(self: *const @This(), slot: usize) DatagramView {
        const offset = slot * self.payload_stride;
        const length: usize = self.payload_lengths[slot];
        return .{
            .session_id = self.session_ids[slot],
            .sequence_number = self.sequence_numbers[slot],
            .payload = self.payload_storage[offset .. offset + length],
        };
    }
};
