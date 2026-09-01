const std = @import("std");

/// HTTP/2 client connection preface defined by RFC 9113 section 3.4.
pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Minimum frame payload limit every HTTP/2 peer must accept.
pub const default_max_frame_size: u32 = 16_384;

/// Largest legal HTTP/2 frame payload.
pub const maximum_frame_size: u32 = 16_777_215;

/// Initial per-stream and connection flow-control window.
pub const default_window_size: i64 = 65_535;

/// HTTP/2 frame types understood by the bounded connection state machine.
pub const FrameType = enum(u8) {
    /// Carries request or response body bytes.
    data = 0x0,
    /// Begins a compressed header block.
    headers = 0x1,
    /// Updates a stream dependency and weight.
    priority = 0x2,
    /// Terminates one stream with an error code.
    rst_stream = 0x3,
    /// Exchanges connection settings.
    settings = 0x4,
    /// Announces a server-initiated response.
    push_promise = 0x5,
    /// Carries eight bytes for liveness and latency checks.
    ping = 0x6,
    /// Begins graceful connection shutdown.
    goaway = 0x7,
    /// Raises connection or stream send credit.
    window_update = 0x8,
    /// Continues an unfinished compressed header block.
    continuation = 0x9,
};

/// Decoded nine-byte HTTP/2 frame header.
pub const FrameHeader = struct {
    /// Payload byte count encoded in the 24-bit length field.
    payload_length: u32,
    /// Raw frame type; unknown extension types remain representable.
    frame_type: u8,
    /// Raw frame-type-specific flags.
    flags: u8,
    /// 31-bit stream ID, or zero for connection-scoped frames.
    stream_id: u32,

    /// Parses exactly nine borrowed bytes without retaining them.
    pub fn parse(bytes: *const [9]u8) !FrameHeader {
        const raw_stream_id = std.mem.readInt(u32, bytes[5..9], .big);

        return .{
            .payload_length = (@as(u32, bytes[0]) << 16) |
                (@as(u32, bytes[1]) << 8) |
                bytes[2],
            .frame_type = bytes[3],
            .flags = bytes[4],
            .stream_id = raw_stream_id & 0x7fff_ffff,
        };
    }

    /// Encodes this header into caller-owned nine-byte storage.
    ///
    /// `FrameTooLarge` and `InvalidStreamId` are detected before writing.
    pub fn encode(self: FrameHeader, out: *[9]u8) !void {
        if (self.payload_length > maximum_frame_size) return error.FrameTooLarge;
        if (self.stream_id & 0x8000_0000 != 0) return error.InvalidStreamId;

        out[0] = @intCast((self.payload_length >> 16) & 0xff);
        out[1] = @intCast((self.payload_length >> 8) & 0xff);
        out[2] = @intCast(self.payload_length & 0xff);
        out[3] = self.frame_type;
        out[4] = self.flags;
        std.mem.writeInt(u32, out[5..9], self.stream_id, .big);
    }
};

/// Bounded peer settings used by the server-side state machine.
pub const Settings = struct {
    /// Peer HPACK dynamic table capacity.
    header_table_size: u32 = 4096,
    /// Whether the receiving endpoint permits server push.
    enable_push: bool = true,
    /// Advisory maximum number of concurrent streams.
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    /// Initial flow-control window for newly created streams.
    initial_window_size: u32 = @intCast(default_window_size),
    /// Largest frame payload the receiving endpoint accepts.
    max_frame_size: u32 = default_max_frame_size,
    /// Advisory maximum uncompressed header-list size.
    max_header_list_size: u32 = std.math.maxInt(u32),
    /// Whether the receiving endpoint permits extended CONNECT.
    enable_connect_protocol: bool = false,
};

/// Lifecycle state for one client-initiated HTTP/2 stream.
pub const StreamState = enum(u8) {
    /// No stream occupies the slab slot.
    idle,
    /// Both endpoints may send frames.
    open,
    /// The peer has ended its sending side.
    half_closed_remote,
    /// The local endpoint has ended its sending side.
    half_closed_local,
    /// Neither endpoint may send stream frames.
    closed,
};

/// Stream metadata returned without exposing mutable slab internals.
pub const StreamView = struct {
    /// HTTP/2 stream identifier.
    id: u32,
    /// Current lifecycle state.
    state: StreamState,
    /// Remaining inbound flow-control credit.
    receive_window: i64,
    /// Remaining outbound flow-control credit.
    send_window: i64,
};

/// Returns fixed-capacity structure-of-arrays HTTP/2 stream storage.
///
/// `capacity` is embedded at compile time; no operation allocates. Call `init`
/// before use, keep one stable instance, and do not mutate its public storage
/// fields or copy it after mutation.
pub fn stream_slab(comptime capacity: usize) type {
    if (capacity == 0) @compileError("HTTP/2 stream capacity must be positive");
    if (capacity > std.math.maxInt(u16)) @compileError("HTTP/2 stream capacity exceeds slab index width");

    return struct {
        const Self = @This();
        const null_index = std.math.maxInt(u16);

        /// Stream IDs indexed by slot; callers must not mutate them.
        stream_ids: [capacity]u32 = .{0} ** capacity,
        /// Lifecycle state parallel to `stream_ids`.
        states: [capacity]StreamState = .{.idle} ** capacity,
        /// Inbound windows parallel to `stream_ids`.
        receive_windows: [capacity]i64 = .{default_window_size} ** capacity,
        /// Outbound windows parallel to `stream_ids`.
        send_windows: [capacity]i64 = .{default_window_size} ** capacity,
        /// Embedded freelist links initialized by `init`.
        next_free: [capacity]u16 = undefined,
        /// Slot occupancy flags parallel to `stream_ids`.
        active: [capacity]bool = .{false} ** capacity,
        /// Head of the freelist, or an internal sentinel when full.
        free_head: u16 = 0,
        /// Number of occupied slots.
        active_count: u16 = 0,

        /// Initializes the freelist without allocating memory.
        pub fn init() Self {
            var self = Self{};
            for (&self.next_free, 0..) |*next, index| {
                next.* = if (index + 1 < capacity) @intCast(index + 1) else null_index;
            }
            return self;
        }

        /// Acquires a slot for a new client-initiated stream.
        ///
        /// IDs must be nonzero, odd, and unique. Returns a stable slot index
        /// until `release`; all failures leave the slab unchanged.
        pub fn acquire(
            self: *Self,
            stream_id: u32,
            receive_window: u32,
            send_window: u32,
        ) !u16 {
            if (stream_id == 0 or stream_id & 1 == 0) return error.InvalidStreamId;
            if (self.find(stream_id) != null) return error.StreamAlreadyExists;
            if (self.free_head == null_index) return error.StreamCapacityReached;

            const index = self.free_head;
            self.free_head = self.next_free[index];
            self.stream_ids[index] = stream_id;
            self.states[index] = .open;
            self.receive_windows[index] = receive_window;
            self.send_windows[index] = send_window;
            self.active[index] = true;
            self.active_count += 1;
            return index;
        }

        /// Finds an active slot by its HTTP/2 stream identifier in O(capacity).
        pub fn find(self: *const Self, stream_id: u32) ?u16 {
            for (self.active, self.stream_ids, 0..) |is_active, candidate, index| {
                if (is_active and candidate == stream_id) return @intCast(index);
            }
            return null;
        }

        /// Returns a copied view of an active slot, or `null` for an invalid one.
        pub fn view(self: *const Self, index: u16) ?StreamView {
            if (index >= capacity or !self.active[index]) return null;
            return .{
                .id = self.stream_ids[index],
                .state = self.states[index],
                .receive_window = self.receive_windows[index],
                .send_window = self.send_windows[index],
            };
        }

        /// Releases a slot back to the freelist after the stream closes.
        ///
        /// Returns false for an out-of-range or already free index. A successful
        /// release invalidates the index, which may be reused by the next acquire.
        pub fn release(self: *Self, index: u16) bool {
            if (index >= capacity or !self.active[index]) return false;
            self.active[index] = false;
            self.stream_ids[index] = 0;
            self.states[index] = .idle;
            self.receive_windows[index] = default_window_size;
            self.send_windows[index] = default_window_size;
            self.next_free[index] = self.free_head;
            self.free_head = index;
            self.active_count -= 1;
            return true;
        }
    };
}

/// A validated frame event whose payload borrows the input frame.
pub const Event = union(enum) {
    /// A valid but unsupported or intentionally unhandled frame.
    ignored,
    /// Non-ACK peer settings were applied.
    settings,
    /// The peer acknowledged local settings.
    settings_ack,
    /// Initial fragment of an HPACK header block.
    headers: struct {
        /// Active slab slot for the stream at event creation.
        stream_index: u16,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
        /// Whether the peer ended its sending side.
        end_stream: bool,
    },
    /// Initial header fragment for a new stream refused at slab capacity.
    refused_headers: struct {
        /// Refused peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Initial header fragment received after this endpoint reset the stream.
    locally_reset_headers: struct {
        /// Locally reset peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Initial header fragment received for an ordinarily closed stream.
    closed_headers: struct {
        /// Closed peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Subsequent fragment of an HPACK header block.
    continuation: struct {
        /// Active slab slot for the stream at event creation.
        stream_index: u16,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Subsequent header fragment for a stream refused at slab capacity.
    refused_continuation: struct {
        /// Refused peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Subsequent header fragment received after a local stream reset.
    locally_reset_continuation: struct {
        /// Locally reset peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Subsequent header fragment received for an ordinarily closed stream.
    closed_continuation: struct {
        /// Closed peer stream identifier.
        stream_id: u32,
        /// Header-block fragment borrowed from the input frame.
        block: []const u8,
        /// Whether this fragment completes the header block.
        end_headers: bool,
    },
    /// Application bytes from a DATA frame.
    data: struct {
        /// Active slab slot for the stream at event creation.
        stream_index: u16,
        /// Unpadded bytes borrowed from the input frame.
        bytes: []const u8,
        /// Whether the peer ended its sending side.
        end_stream: bool,
    },
    /// DATA discarded during the bounded local-reset grace window.
    discarded_data: struct {
        /// Full flow-controlled payload size, including padding.
        flow_length: u32,
    },
    /// Peer reset carrying both the released slab index and stable wire ID.
    stream_reset: struct {
        /// Slab index that was released and may now be reused.
        stream_index: u16,
        /// Peer stream identifier retained after the slab fields are cleared.
        stream_id: u32,
    },
    /// Opaque bytes from a PING that requires an acknowledgement.
    ping: [8]u8,
    /// Opaque bytes from a PING acknowledgement.
    ping_ack: [8]u8,
    /// Peer graceful-shutdown notification.
    goaway: struct {
        /// Last peer-selected stream that may have been processed.
        last_stream_id: u32,
        /// Peer-supplied HTTP/2 error code.
        error_code: u32,
        /// Optional diagnostic bytes borrowed from the input frame.
        debug_data: []const u8,
    },
    /// Applied connection- or stream-level send-credit increment.
    window_update: struct {
        /// Active stream slot, or `null` for the connection window.
        stream_index: ?u16,
        /// Nonzero credit increment.
        increment: u32,
    },
};

/// Returns bounded, allocation-free server-side HTTP/2 connection state.
///
/// `max_streams` fixes the simultaneous stream capacity and is embedded in the
/// value. The zero/default initializer is ready for use. Keep a stable instance
/// per connection and do not mutate its public fields behind these methods.
pub fn connection(comptime max_streams: usize) type {
    return struct {
        const Self = @This();
        const Slab = stream_slab(max_streams);
        const MissingStreamState = enum {
            idle,
            closed,
            locally_reset,
        };

        /// Fixed-capacity active-stream storage.
        streams: Slab = Slab.init(),
        /// Most recently applied peer settings.
        peer_settings: Settings = .{},
        /// Settings enforced locally and intended for advertisement to the peer.
        local_settings: Settings = .{
            .enable_push = false,
            .max_concurrent_streams = max_streams,
            .enable_connect_protocol = false,
        },
        /// Remaining inbound connection flow-control credit.
        connection_receive_window: i64 = default_window_size,
        /// Remaining outbound connection flow-control credit.
        connection_send_window: i64 = default_window_size,
        /// Greatest client-initiated stream ID observed.
        highest_peer_stream_id: u32 = 0,
        /// Stream that must supply the next CONTINUATION frame, if any.
        continuation_stream_id: ?u32 = null,
        /// Refused stream whose compressed block still needs CONTINUATION.
        refused_continuation_stream_id: ?u32 = null,
        /// Locally reset stream whose block still needs CONTINUATION.
        local_reset_continuation_stream_id: ?u32 = null,
        /// Ordinarily closed stream whose block still needs CONTINUATION.
        closed_continuation_stream_id: ?u32 = null,
        /// Recently locally reset stream IDs retained for bounded race handling.
        local_reset_stream_ids: [max_streams]u32 = .{0} ** max_streams,
        /// Next local-reset tombstone slot to replace.
        local_reset_cursor: u16 = 0,
        /// Number of validated client-preface bytes.
        preface_offset: u8 = 0,
        /// Whether at least one non-ACK peer SETTINGS frame was applied.
        peer_settings_seen: bool = false,
        /// Whether GOAWAY was received and new streams must be rejected.
        shutting_down: bool = false,

        /// Incrementally validates a borrowed client-preface fragment.
        ///
        /// Returns the consumed byte count. On mismatch, validation progress for
        /// earlier bytes in this call remains committed. Extra bytes after the
        /// completed preface are not consumed and no input is retained.
        pub fn consume_preface(self: *Self, input: []const u8) !usize {
            var consumed: usize = 0;
            while (consumed < input.len and self.preface_offset < client_preface.len) : (consumed += 1) {
                if (input[consumed] != client_preface[self.preface_offset]) {
                    return error.InvalidClientPreface;
                }
                self.preface_offset += 1;
            }
            return consumed;
        }

        /// Reports whether the complete client preface has been validated.
        pub fn preface_complete(self: *const Self) bool {
            return self.preface_offset == client_preface.len;
        }

        /// Validates and applies exactly one complete HTTP/2 frame.
        ///
        /// The supplied slice must contain the nine-byte header and exactly the
        /// declared payload. Slice fields in the returned event borrow `frame`
        /// and must be consumed before its storage is reused. State may change
        /// before some late validation errors are returned.
        pub fn receive_frame(self: *Self, frame: []const u8) !Event {
            if (!self.preface_complete()) return error.ClientPrefaceRequired;
            if (frame.len < 9) return error.IncompleteFrame;

            const header = try FrameHeader.parse(frame[0..9]);
            if (header.payload_length > self.local_settings.max_frame_size) return error.FrameTooLarge;
            if (header.payload_length != frame.len - 9) return error.IncompleteFrame;
            const payload = frame[9..];

            if (self.continuation_stream_id) |stream_id| {
                if (header.frame_type != @intFromEnum(FrameType.continuation) or
                    header.stream_id != stream_id)
                {
                    return error.ExpectedContinuation;
                }
            } else if (header.frame_type == @intFromEnum(FrameType.continuation)) {
                return error.UnexpectedContinuation;
            }

            return switch (header.frame_type) {
                @intFromEnum(FrameType.data) => self.receive_data(header, payload),
                @intFromEnum(FrameType.headers) => self.receive_headers(header, payload),
                @intFromEnum(FrameType.priority) => receive_priority(header, payload),
                @intFromEnum(FrameType.rst_stream) => self.receive_reset(header, payload),
                @intFromEnum(FrameType.settings) => self.receive_settings(header, payload),
                @intFromEnum(FrameType.push_promise) => error.ClientPushPromise,
                @intFromEnum(FrameType.ping) => receive_ping(header, payload),
                @intFromEnum(FrameType.goaway) => self.receive_goaway(header, payload),
                @intFromEnum(FrameType.window_update) => self.receive_window_update(header, payload),
                @intFromEnum(FrameType.continuation) => self.receive_continuation(header, payload),
                else => .ignored,
            };
        }

        /// Reserves outbound connection and stream credit before writing DATA.
        ///
        /// The reservation is atomic: insufficient credit leaves both windows
        /// unchanged so a bounded transport can retry after WINDOW_UPDATE.
        /// Values larger than `i64` fail without changing either window.
        pub fn reserve_send_credit(self: *Self, index: u16, amount: usize) !void {
            if (index >= max_streams or !self.streams.active[index]) {
                return error.StreamClosed;
            }
            if (amount > @as(usize, @intCast(std.math.maxInt(i64)))) {
                return error.SendWindowExhausted;
            }
            const credit: i64 = @intCast(amount);
            if (credit > self.connection_send_window or
                credit > self.streams.send_windows[index])
            {
                return error.SendWindowExhausted;
            }
            self.connection_send_window -= credit;
            self.streams.send_windows[index] -= credit;
        }

        /// Returns a failed DATA write reservation to both outbound windows.
        pub fn refund_send_credit(self: *Self, index: u16, amount: usize) void {
            if (amount > @as(usize, @intCast(std.math.maxInt(i64)))) return;
            const credit: i64 = @intCast(amount);
            self.connection_send_window += credit;
            if (index >= max_streams or !self.streams.active[index]) return;
            self.streams.send_windows[index] += credit;
        }

        /// Restores consumed inbound credit after application bytes are copied.
        ///
        /// Returns the increment to advertise at both connection and stream
        /// scope. Zero is accepted as a no-op and values above 2^31-1 fail.
        /// Both window additions are validated before either field is changed.
        pub fn restore_receive_credit(self: *Self, index: u16, amount: usize) !u32 {
            if (index >= max_streams or !self.streams.active[index]) {
                return error.StreamClosed;
            }
            if (amount > 0x7fff_ffff) return error.FlowControlError;
            const increment: u32 = @intCast(amount);
            if (increment == 0) return 0;

            const connection_window = try add_window(
                self.connection_receive_window,
                increment,
            );
            const stream_window = try add_window(
                self.streams.receive_windows[index],
                increment,
            );
            self.connection_receive_window = connection_window;
            self.streams.receive_windows[index] = stream_window;
            return increment;
        }

        /// Restores connection credit for DATA discarded after a local reset.
        pub fn restore_connection_receive_credit(self: *Self, amount: usize) !u32 {
            if (amount > 0x7fff_ffff) return error.FlowControlError;
            const increment: u32 = @intCast(amount);
            if (increment == 0) return 0;
            self.connection_receive_window = try add_window(
                self.connection_receive_window,
                increment,
            );
            return increment;
        }

        /// Closes the local side and releases a fully closed stream slot.
        ///
        /// The return value reports whether the slot was released and may be
        /// reused immediately. Unknown, idle, or already locally closed slots
        /// return `StreamClosed` without changing state.
        pub fn close_local(self: *Self, index: u16) !bool {
            if (index >= max_streams or !self.streams.active[index]) {
                return error.StreamClosed;
            }
            switch (self.streams.states[index]) {
                .open => {
                    self.streams.states[index] = .half_closed_local;
                    return false;
                },
                .half_closed_remote => {
                    self.streams.states[index] = .closed;
                    return self.streams.release(index);
                },
                else => return error.StreamClosed,
            }
        }

        /// Discards an active stream after a locally generated RST_STREAM.
        ///
        /// Returns false for an invalid or inactive slot. Success invalidates
        /// the index, which can be reused by the next incoming stream.
        pub fn reset_local(self: *Self, index: u16) bool {
            if (index >= max_streams or !self.streams.active[index]) return false;
            const stream_id = self.streams.stream_ids[index];
            if (!self.streams.release(index)) return false;
            self.record_local_reset(stream_id);
            return true;
        }

        /// Retains one locally reset peer stream in a fixed-size grace window.
        pub fn record_local_reset(self: *Self, stream_id: u32) void {
            if (stream_id == 0 or stream_id & 1 == 0) return;
            if (self.was_locally_reset(stream_id)) return;
            self.local_reset_stream_ids[self.local_reset_cursor] = stream_id;
            self.local_reset_cursor = @intCast(
                (@as(usize, self.local_reset_cursor) + 1) % max_streams,
            );
        }

        fn receive_headers(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (header.stream_id == 0 or header.stream_id & 1 == 0) return error.InvalidStreamId;

            const parsed = try header_block_payload(header, payload);

            var index = self.streams.find(header.stream_id);
            if (index == null) {
                switch (self.classify_missing_stream(header.stream_id)) {
                    .closed => {
                        if (header.flags & 0x4 == 0) {
                            self.continuation_stream_id = header.stream_id;
                            self.closed_continuation_stream_id = header.stream_id;
                        }
                        return .{ .closed_headers = .{
                            .stream_id = header.stream_id,
                            .block = parsed,
                            .end_headers = header.flags & 0x4 != 0,
                        } };
                    },
                    .locally_reset => {
                        if (header.flags & 0x4 == 0) {
                            self.continuation_stream_id = header.stream_id;
                            self.local_reset_continuation_stream_id = header.stream_id;
                        }
                        return .{ .locally_reset_headers = .{
                            .stream_id = header.stream_id,
                            .block = parsed,
                            .end_headers = header.flags & 0x4 != 0,
                        } };
                    },
                    .idle => {},
                }
                if (self.shutting_down) return error.StreamClosed;
                if (self.streams.active_count >= max_streams) {
                    self.highest_peer_stream_id = header.stream_id;
                    if (header.flags & 0x4 == 0) {
                        self.continuation_stream_id = header.stream_id;
                        self.refused_continuation_stream_id = header.stream_id;
                    }
                    return .{ .refused_headers = .{
                        .stream_id = header.stream_id,
                        .block = parsed,
                        .end_headers = header.flags & 0x4 != 0,
                    } };
                }
                index = try self.streams.acquire(
                    header.stream_id,
                    self.local_settings.initial_window_size,
                    self.peer_settings.initial_window_size,
                );
                self.highest_peer_stream_id = header.stream_id;
            } else switch (self.streams.states[index.?]) {
                .open, .half_closed_local => {},
                .half_closed_remote, .closed => {
                    if (header.flags & 0x4 == 0) {
                        self.continuation_stream_id = header.stream_id;
                        self.closed_continuation_stream_id = header.stream_id;
                    }
                    return .{ .closed_headers = .{
                        .stream_id = header.stream_id,
                        .block = parsed,
                        .end_headers = header.flags & 0x4 != 0,
                    } };
                },
                .idle => unreachable,
            }

            if (header.flags & 0x4 == 0) self.continuation_stream_id = header.stream_id;
            if (header.flags & 0x1 != 0) try self.close_remote(index.?);
            return .{ .headers = .{
                .stream_index = index.?,
                .block = parsed,
                .end_headers = header.flags & 0x4 != 0,
                .end_stream = header.flags & 0x1 != 0,
            } };
        }

        fn receive_continuation(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (self.refused_continuation_stream_id == header.stream_id) {
                if (header.flags & 0x4 != 0) {
                    self.continuation_stream_id = null;
                    self.refused_continuation_stream_id = null;
                }
                return .{ .refused_continuation = .{
                    .stream_id = header.stream_id,
                    .block = payload,
                    .end_headers = header.flags & 0x4 != 0,
                } };
            }
            if (self.local_reset_continuation_stream_id == header.stream_id) {
                if (header.flags & 0x4 != 0) {
                    self.continuation_stream_id = null;
                    self.local_reset_continuation_stream_id = null;
                }
                return .{ .locally_reset_continuation = .{
                    .stream_id = header.stream_id,
                    .block = payload,
                    .end_headers = header.flags & 0x4 != 0,
                } };
            }
            if (self.closed_continuation_stream_id == header.stream_id) {
                if (header.flags & 0x4 != 0) {
                    self.continuation_stream_id = null;
                    self.closed_continuation_stream_id = null;
                }
                return .{ .closed_continuation = .{
                    .stream_id = header.stream_id,
                    .block = payload,
                    .end_headers = header.flags & 0x4 != 0,
                } };
            }
            const index = self.streams.find(header.stream_id) orelse return error.StreamClosed;
            if (header.flags & 0x4 != 0) self.continuation_stream_id = null;
            return .{ .continuation = .{
                .stream_index = index,
                .block = payload,
                .end_headers = header.flags & 0x4 != 0,
            } };
        }

        fn receive_data(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (header.stream_id == 0 or header.stream_id & 1 == 0) {
                return error.InvalidStreamId;
            }
            const index = self.streams.find(header.stream_id) orelse {
                switch (self.classify_missing_stream(header.stream_id)) {
                    .idle => return error.IdleStream,
                    .closed => {
                        try self.consume_closed_data(header.flags, payload);
                        return error.StreamClosed;
                    },
                    .locally_reset => {
                        _ = try data_payload(header.flags, payload);
                        const flow_length: i64 = @intCast(payload.len);
                        if (flow_length > self.connection_receive_window) {
                            return error.ConnectionFlowControlError;
                        }
                        self.connection_receive_window -= flow_length;
                        return .{ .discarded_data = .{
                            .flow_length = @intCast(payload.len),
                        } };
                    },
                }
            };
            switch (self.streams.states[index]) {
                .open, .half_closed_local => {},
                .half_closed_remote, .closed => {
                    try self.consume_closed_data(header.flags, payload);
                    return error.StreamClosed;
                },
                .idle => unreachable,
            }
            const bytes = try data_payload(header.flags, payload);
            const flow_length: i64 = @intCast(payload.len);
            if (flow_length > self.connection_receive_window) {
                return error.ConnectionFlowControlError;
            }
            if (flow_length > self.streams.receive_windows[index]) {
                return error.StreamFlowControlError;
            }
            self.connection_receive_window -= flow_length;
            self.streams.receive_windows[index] -= flow_length;
            if (header.flags & 0x1 != 0) try self.close_remote(index);
            return .{ .data = .{
                .stream_index = index,
                .bytes = bytes,
                .end_stream = header.flags & 0x1 != 0,
            } };
        }

        fn receive_settings(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (header.stream_id != 0) return error.InvalidStreamId;
            if (header.flags & 0x1 != 0) {
                if (payload.len != 0) return error.InvalidFrameSize;
                return .settings_ack;
            }
            if (payload.len % 6 != 0) return error.InvalidFrameSize;

            var next = self.peer_settings;
            var offset: usize = 0;
            while (offset < payload.len) : (offset += 6) {
                const identifier = std.mem.readInt(u16, payload[offset..][0..2], .big);
                const value = std.mem.readInt(u32, payload[offset + 2 ..][0..4], .big);
                switch (identifier) {
                    0x1 => next.header_table_size = value,
                    0x2 => {
                        if (value > 1) return error.InvalidSetting;
                        next.enable_push = value == 1;
                    },
                    0x3 => next.max_concurrent_streams = value,
                    0x4 => {
                        if (value > 0x7fff_ffff) return error.FlowControlError;
                        next.initial_window_size = value;
                    },
                    0x5 => {
                        if (value < default_max_frame_size or value > maximum_frame_size) {
                            return error.InvalidSetting;
                        }
                        next.max_frame_size = value;
                    },
                    0x6 => next.max_header_list_size = value,
                    0x8 => {
                        if (value > 1) return error.InvalidSetting;
                        next.enable_connect_protocol = value == 1;
                    },
                    else => {},
                }
            }
            try self.update_initial_send_window(
                self.peer_settings.initial_window_size,
                next.initial_window_size,
            );
            self.peer_settings = next;
            self.peer_settings_seen = true;
            return .settings;
        }

        fn update_initial_send_window(self: *Self, old: u32, new: u32) !void {
            const delta = @as(i64, new) - @as(i64, old);
            for (self.streams.active, self.streams.send_windows) |is_active, window| {
                if (!is_active) continue;
                const updated = window + delta;
                if (updated > 0x7fff_ffff or updated < -0x7fff_ffff) {
                    return error.FlowControlError;
                }
            }
            for (self.streams.active, &self.streams.send_windows) |is_active, *window| {
                if (is_active) window.* += delta;
            }
        }

        fn receive_reset(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (header.stream_id == 0 or header.stream_id & 1 == 0) {
                return error.InvalidStreamId;
            }
            if (payload.len != 4) return error.InvalidFrameSize;
            const index = self.streams.find(header.stream_id) orelse {
                return switch (self.classify_missing_stream(header.stream_id)) {
                    .idle => error.IdleStream,
                    .closed, .locally_reset => .ignored,
                };
            };
            _ = self.streams.release(index);
            return .{ .stream_reset = .{
                .stream_index = index,
                .stream_id = header.stream_id,
            } };
        }

        fn receive_window_update(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (payload.len != 4) return error.InvalidFrameSize;
            if (header.stream_id == 0) {
                const increment = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                if (increment == 0) return error.ConnectionProtocolError;
                self.connection_send_window = add_window(
                    self.connection_send_window,
                    increment,
                ) catch return error.ConnectionFlowControlError;
                return .{ .window_update = .{ .stream_index = null, .increment = increment } };
            }

            if (header.stream_id & 1 == 0) return error.InvalidStreamId;
            const index = self.streams.find(header.stream_id) orelse {
                return switch (self.classify_missing_stream(header.stream_id)) {
                    .idle => error.IdleStream,
                    .closed, .locally_reset => .ignored,
                };
            };
            const increment = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
            if (increment == 0) return error.StreamProtocolError;
            self.streams.send_windows[index] = add_window(
                self.streams.send_windows[index],
                increment,
            ) catch return error.StreamFlowControlError;
            return .{ .window_update = .{ .stream_index = index, .increment = increment } };
        }

        fn receive_goaway(self: *Self, header: FrameHeader, payload: []const u8) !Event {
            if (header.stream_id != 0) return error.InvalidStreamId;
            if (payload.len < 8) return error.InvalidFrameSize;
            const raw_last_stream = std.mem.readInt(u32, payload[0..4], .big);
            self.shutting_down = true;
            return .{ .goaway = .{
                .last_stream_id = raw_last_stream & 0x7fff_ffff,
                .error_code = std.mem.readInt(u32, payload[4..8], .big),
                .debug_data = payload[8..],
            } };
        }

        fn close_remote(self: *Self, index: u16) !void {
            switch (self.streams.states[index]) {
                .open => self.streams.states[index] = .half_closed_remote,
                .half_closed_local => {
                    self.streams.states[index] = .closed;
                    _ = self.streams.release(index);
                },
                else => return error.StreamClosed,
            }
        }

        fn classify_missing_stream(self: *const Self, stream_id: u32) MissingStreamState {
            std.debug.assert(stream_id != 0 and stream_id & 1 != 0);
            if (stream_id > self.highest_peer_stream_id) return .idle;
            if (self.was_locally_reset(stream_id)) return .locally_reset;
            return .closed;
        }

        fn was_locally_reset(self: *const Self, stream_id: u32) bool {
            for (self.local_reset_stream_ids) |candidate| {
                if (candidate == stream_id) return true;
            }
            return false;
        }

        fn consume_closed_data(self: *Self, flags: u8, payload: []const u8) !void {
            _ = try data_payload(flags, payload);
            const flow_length: i64 = @intCast(payload.len);
            if (flow_length > self.connection_receive_window) {
                return error.ConnectionFlowControlError;
            }
            self.connection_receive_window -= flow_length;
        }
    };
}

fn receive_priority(header: FrameHeader, payload: []const u8) !Event {
    if (header.stream_id == 0) return error.InvalidStreamId;
    if (payload.len != 5) return error.InvalidFrameSize;
    const dependency = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
    if (dependency == header.stream_id) return error.StreamDependsOnItself;
    return .ignored;
}

fn receive_ping(header: FrameHeader, payload: []const u8) !Event {
    if (header.stream_id != 0) return error.InvalidStreamId;
    if (payload.len != 8) return error.InvalidFrameSize;
    const opaque_data = payload[0..8].*;
    return if (header.flags & 0x1 == 0)
        .{ .ping = opaque_data }
    else
        .{ .ping_ack = opaque_data };
}

fn header_block_payload(header: FrameHeader, payload: []const u8) ![]const u8 {
    var start: usize = 0;
    var end = payload.len;
    if (header.flags & 0x8 != 0) {
        if (payload.len == 0) return error.InvalidPadding;
        start = 1;
        const padding = payload[0];
        if (padding > payload.len - 1) return error.InvalidPadding;
        end -= padding;
    }
    if (header.flags & 0x20 != 0) {
        if (end - start < 5) return error.InvalidFrameSize;
        const dependency = std.mem.readInt(u32, payload[start..][0..4], .big) & 0x7fff_ffff;
        if (dependency == header.stream_id) return error.StreamDependsOnItself;
        start += 5;
    }
    return payload[start..end];
}

fn data_payload(flags: u8, payload: []const u8) ![]const u8 {
    if (flags & 0x8 == 0) return payload;
    if (payload.len == 0) return error.InvalidPadding;
    const padding = payload[0];
    if (padding > payload.len - 1) return error.InvalidPadding;
    return payload[1 .. payload.len - padding];
}

fn add_window(current: i64, increment: u32) !i64 {
    const updated = current + @as(i64, increment);
    if (updated > 0x7fff_ffff) return error.FlowControlError;
    return updated;
}
