const capsule = @import("capsule.zig");
const max_data = @import("varint.zig").max_quic_varint;
const max_streams = @import("session.zig").max_stream_count;

/// Only child streams consume the corresponding cumulative stream count.
pub const Direction = @import("child_runtime.zig").Direction;
/// Independently ordered session credit carried on the CONNECT stream.
pub const Credit = enum(u8) { data, streams_bidi, streams_uni };

/// Cumulative body bytes and child counts; closed streams remain counted.
pub const Limits = struct {
    data: u64 = 0,
    streams_bidi: u64 = 0,
    streams_uni: u64 = 0,
};

/// Invalid transitions leave all caller-owned state unchanged.
pub const FlowError = error{ InvalidLimit, FlowControlViolation, InvalidConsumption, InvalidProgress };

/// Instantiate only for negotiated flow; QUIC limits remain independently enforced.
pub const Budget = struct {
    limits: Limits,
    used: Limits = .{},

    pub fn init(limits: Limits) FlowError!Budget {
        if (limits.data > max_data or limits.streams_bidi > max_streams or limits.streams_uni > max_streams) {
            return error.InvalidLimit;
        }
        return .{ .limits = limits };
    }

    /// Checking before native creation does not reserve or spend credit.
    pub fn can_open(budget: *const Budget, direction: Direction) bool {
        return switch (direction) {
            .bidi => budget.used.streams_bidi < budget.limits.streams_bidi,
            .uni => budget.used.streams_uni < budget.limits.streams_uni,
        };
    }

    /// Limits a native write; commit only its actual positive return value.
    pub fn allowance(budget: *const Budget, requested: usize) usize {
        return @intCast(@min(@as(u64, requested), budget.limits.data - budget.used.data));
    }

    /// Charge a successful local creation or a newly classified peer child once.
    pub fn commit_open(budget: *Budget, direction: Direction) FlowError!void {
        if (!budget.can_open(direction)) return error.FlowControlViolation;
        switch (direction) {
            .bidi => budget.used.streams_bidi += 1,
            .uni => budget.used.streams_uni += 1,
        }
    }

    /// Receive deltas come from native high-water observation, never read/final gaps again.
    pub fn commit_data(budget: *Budget, body_bytes: u64) FlowError!void {
        if (body_bytes > budget.limits.data - budget.used.data) return error.FlowControlViolation;
        budget.used.data += body_bytes;
    }

    /// Ordered MAX_* capsules must strictly increase their corresponding limit.
    pub fn grant(budget: *Budget, kind: Credit, value: u64) FlowError!void {
        const slot = switch (kind) {
            .data => &budget.limits.data,
            .streams_bidi => &budget.limits.streams_bidi,
            .streams_uni => &budget.limits.streams_uni,
        };
        const maximum = if (kind == .data) max_data else max_streams;
        if (value <= slot.* or value > maximum) return error.FlowControlViolation;
        slot.* = value;
    }
};

/// Desired grants may advance while a capsule advertising an older limit is in flight.
pub const Receiver = struct {
    budget: Budget,
    desired: Limits,
    reclaimed: Limits = .{},

    pub fn init(limits: Limits) FlowError!Receiver {
        return .{ .budget = try Budget.init(limits), .desired = limits };
    }

    /// Supply each consumed or discarded body byte once, after native receipt debit.
    pub fn consume_data(receiver: *Receiver, body_bytes: u64) FlowError!void {
        if (body_bytes > receiver.budget.used.data - receiver.reclaimed.data) return error.InvalidConsumption;
        receiver.reclaimed.data += body_bytes;
        receiver.desired.data += @min(body_bytes, max_data - receiver.desired.data);
    }

    /// Caller lifecycle guards ensure one call per closed peer-initiated child.
    pub fn close_stream(receiver: *Receiver, direction: Direction) FlowError!void {
        const used = switch (direction) {
            .bidi => receiver.budget.used.streams_bidi,
            .uni => receiver.budget.used.streams_uni,
        };
        const reclaimed = switch (direction) {
            .bidi => &receiver.reclaimed.streams_bidi,
            .uni => &receiver.reclaimed.streams_uni,
        };
        const desired = switch (direction) {
            .bidi => &receiver.desired.streams_bidi,
            .uni => &receiver.desired.streams_uni,
        };
        if (reclaimed.* == used) return error.InvalidConsumption;
        reclaimed.* += 1;
        desired.* += @intFromBool(desired.* < max_streams);
    }
};

/// One stable capsule per receiver; round-robin service bounds coalesced credit work.
pub const CreditOutput = struct {
    value: u64 = 0,
    buffer: [13]u8 = @splat(0),
    length: u8 = 0,
    offset: u8 = 0,
    kind: Credit = .data,
    next: Credit = .data,

    /// Borrowed bytes remain immutable until advance accepts the complete capsule.
    pub fn prepare(output: *CreditOutput, receiver: *const Receiver) ?[]const u8 {
        if (output.offset < output.length) return output.buffer[output.offset..output.length];
        var kind = output.next;
        for (0..3) |_| {
            const desired, const advertised = switch (kind) {
                .data => .{ receiver.desired.data, receiver.budget.limits.data },
                .streams_bidi => .{ receiver.desired.streams_bidi, receiver.budget.limits.streams_bidi },
                .streams_uni => .{ receiver.desired.streams_uni, receiver.budget.limits.streams_uni },
            };
            if (desired > advertised) return output.encode(kind, desired);
            kind = next_credit(kind);
        }
        return null;
    }

    /// Supply only bytes positively accepted by native CONNECT output, using the same receiver.
    pub fn advance(output: *CreditOutput, receiver: *Receiver, accepted: usize) FlowError!void {
        const remaining = output.length - output.offset;
        if (accepted > remaining) return error.InvalidProgress;
        if (accepted == 0) return;
        if (accepted < remaining) {
            output.offset += @intCast(accepted);
            return;
        }
        try receiver.budget.grant(output.kind, output.value);
        output.next = next_credit(output.kind);
        output.length = 0;
        output.offset = 0;
    }

    fn encode(output: *CreditOutput, kind: Credit, value: u64) []const u8 {
        const capsule_type = switch (kind) {
            .data => capsule.wt_max_data,
            .streams_bidi => capsule.wt_max_streams_bidi,
            .streams_uni => capsule.wt_max_streams_uni,
        };
        // Validated values need at most 8 bytes, known types 4, and payload length 1.
        const length = capsule.encode_integer_capsule(capsule_type, value, &output.buffer) catch unreachable;
        output.value = value;
        output.kind = kind;
        output.length = @intCast(length);
        output.offset = 0;
        return output.buffer[0..length];
    }
};

fn next_credit(kind: Credit) Credit {
    return switch (kind) {
        .data => .streams_bidi,
        .streams_bidi => .streams_uni,
        .streams_uni => .data,
    };
}
