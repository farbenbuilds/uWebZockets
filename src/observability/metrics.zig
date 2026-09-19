//! Fixed-capacity counter registry and allocation-free Prometheus rendering.

const std = @import("std");

pub const cache_line = 64;

pub const Slot = enum(u8) {
    connections_accepted,
    connections_closed,
    http_requests,
    http_rejections,
    ws_messages,
    ws_compressed_messages,
    datagrams_received,
    datagrams_sent,
    datagrams_dropped,
    xdp_frames_received,
    xdp_frames_sent,
    xdp_kernel_bypass_fallbacks,
    kernel_bypass_active,
};

const slot_fields = @typeInfo(Slot).@"enum".fields;

pub const Registry = struct {
    counters: [slot_fields.len]u64 align(cache_line) = .{0} ** slot_fields.len,

    pub fn add(self: *Registry, comptime which: Slot, delta: u64) void {
        self.counters[@intFromEnum(which)] +|= delta;
    }

    pub fn set(self: *Registry, comptime which: Slot, value: u64) void {
        self.counters[@intFromEnum(which)] = value;
    }

    pub fn get(self: *const Registry, comptime which: Slot) u64 {
        return self.counters[@intFromEnum(which)];
    }

    /// Writes the full Prometheus text exposition into `buffer` without allocating.
    /// Returns the written prefix of `buffer`, or error.NoSpaceLeft.
    pub fn write_prometheus(
        self: *const Registry,
        histogram_buckets: ?[]const u64,
        buffer: []u8,
    ) error{NoSpaceLeft}![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);

        inline for (slot_fields) |field| {
            const which: Slot = @enumFromInt(field.value);
            writer.print("# TYPE {s} {s}\n", .{ metric_name(which), metric_kind(which) }) catch
                return error.NoSpaceLeft;
            writer.print("{s} {d}\n", .{ metric_name(which), self.get(which) }) catch
                return error.NoSpaceLeft;
        }

        if (histogram_buckets) |buckets| {
            writer.writeAll("# TYPE uwz_latency_packets_bucket histogram\n") catch
                return error.NoSpaceLeft;
            var cumulative: u64 = 0;
            // Input buckets hold per-bucket counts; the exposition requires
            // cumulative values. Bucket 64 (upper bound (1 << 64) - 1) is the
            // last finite boundary a u64 count can reach, so later counts roll
            // into +Inf instead of overflowing the shift.
            const finite_buckets = @min(buckets.len, 65);
            for (buckets[0..finite_buckets], 0..) |count, index| {
                cumulative +|= count;
                const upper: u64 = if (index < 64)
                    (@as(u64, 1) << @intCast(index)) - 1
                else
                    std.math.maxInt(u64);
                writer.print(
                    "uwz_latency_packets_bucket{{le=\"{d}\"}} {d}\n",
                    .{ upper, cumulative },
                ) catch return error.NoSpaceLeft;
            }
            for (buckets[finite_buckets..]) |count| cumulative +|= count;
            writer.print(
                "uwz_latency_packets_bucket{{le=\"+Inf\"}} {d}\n",
                .{cumulative},
            ) catch return error.NoSpaceLeft;
        }

        return writer.buffered();
    }
};

pub fn metric_name(comptime which: Slot) []const u8 {
    const tag = @tagName(which);
    return switch (which) {
        .kernel_bypass_active => "uwz_" ++ tag,
        else => "uwz_" ++ tag ++ "_total",
    };
}

pub fn metric_kind(comptime which: Slot) []const u8 {
    return switch (which) {
        .kernel_bypass_active => "gauge",
        else => "counter",
    };
}
