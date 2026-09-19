const std = @import("std");
const support = @import("test_support");
const metrics = support.metrics;

const Registry = metrics.Registry;
const Slot = metrics.Slot;

test "observability: metric names and kinds are exact" {
    try std.testing.expectEqualStrings(
        "uwz_connections_accepted_total",
        metrics.metric_name(.connections_accepted),
    );
    try std.testing.expectEqualStrings("counter", metrics.metric_kind(.connections_accepted));

    try std.testing.expectEqualStrings(
        "uwz_ws_compressed_messages_total",
        metrics.metric_name(.ws_compressed_messages),
    );
    try std.testing.expectEqualStrings("counter", metrics.metric_kind(.ws_compressed_messages));

    try std.testing.expectEqualStrings(
        "uwz_kernel_bypass_active",
        metrics.metric_name(.kernel_bypass_active),
    );
    try std.testing.expectEqualStrings("gauge", metrics.metric_kind(.kernel_bypass_active));
}

test "observability: every slot name matches its kind suffix" {
    inline for (@typeInfo(Slot).@"enum".fields) |field| {
        const which: Slot = @enumFromInt(field.value);
        const name = metrics.metric_name(which);
        const kind = metrics.metric_kind(which);

        try std.testing.expect(std.mem.startsWith(u8, name, "uwz_"));
        if (std.mem.eql(u8, kind, "counter")) {
            try std.testing.expect(std.mem.endsWith(u8, name, "_total"));
        } else {
            try std.testing.expectEqualStrings("gauge", kind);
            try std.testing.expect(!std.mem.endsWith(u8, name, "_total"));
        }
    }
}

test "observability: registry add set get saturates at maxInt" {
    var registry = Registry{};

    try std.testing.expectEqual(@as(u64, 0), registry.get(.connections_accepted));
    registry.add(.connections_accepted, 5);
    registry.add(.connections_accepted, 7);
    try std.testing.expectEqual(@as(u64, 12), registry.get(.connections_accepted));
    try std.testing.expectEqual(@as(u64, 0), registry.get(.http_requests));

    registry.set(.http_requests, 42);
    try std.testing.expectEqual(@as(u64, 42), registry.get(.http_requests));
    try std.testing.expectEqual(@as(u64, 12), registry.get(.connections_accepted));

    registry.set(.datagrams_dropped, std.math.maxInt(u64));
    registry.add(.datagrams_dropped, 1);
    try std.testing.expectEqual(std.math.maxInt(u64), registry.get(.datagrams_dropped));
    registry.add(.datagrams_dropped, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), registry.get(.datagrams_dropped));

    registry.set(.kernel_bypass_active, 1);
    registry.set(.kernel_bypass_active, 0);
    try std.testing.expectEqual(@as(u64, 0), registry.get(.kernel_bypass_active));
}

test "observability: counters live on a cache line boundary" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Registry, "counters"));
    try std.testing.expectEqual(@as(usize, metrics.cache_line), @alignOf(Registry));
}

test "observability: small registry renders exact text" {
    var registry = Registry{};
    registry.add(.connections_accepted, 2);
    registry.add(.http_requests, 1);

    var buffer: [2048]u8 = undefined;
    const output = try registry.write_prometheus(null, &buffer);

    const expected =
        \\# TYPE uwz_connections_accepted_total counter
        \\uwz_connections_accepted_total 2
        \\# TYPE uwz_connections_closed_total counter
        \\uwz_connections_closed_total 0
        \\# TYPE uwz_http_requests_total counter
        \\uwz_http_requests_total 1
        \\# TYPE uwz_http_rejections_total counter
        \\uwz_http_rejections_total 0
        \\# TYPE uwz_ws_messages_total counter
        \\uwz_ws_messages_total 0
        \\# TYPE uwz_ws_compressed_messages_total counter
        \\uwz_ws_compressed_messages_total 0
        \\# TYPE uwz_datagrams_received_total counter
        \\uwz_datagrams_received_total 0
        \\# TYPE uwz_datagrams_sent_total counter
        \\uwz_datagrams_sent_total 0
        \\# TYPE uwz_datagrams_dropped_total counter
        \\uwz_datagrams_dropped_total 0
        \\# TYPE uwz_xdp_frames_received_total counter
        \\uwz_xdp_frames_received_total 0
        \\# TYPE uwz_xdp_frames_sent_total counter
        \\uwz_xdp_frames_sent_total 0
        \\# TYPE uwz_xdp_kernel_bypass_fallbacks_total counter
        \\uwz_xdp_kernel_bypass_fallbacks_total 0
        \\# TYPE uwz_kernel_bypass_active gauge
        \\uwz_kernel_bypass_active 0
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "observability: block count matches slot field count" {
    const registry = Registry{};
    var buffer: [2048]u8 = undefined;
    const output = try registry.write_prometheus(null, &buffer);
    const field_count = @typeInfo(Slot).@"enum".fields.len;

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var type_lines: usize = 0;
    var value_lines: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# TYPE ")) {
            type_lines += 1;
            continue;
        }
        value_lines += 1;
    }
    try std.testing.expectEqual(field_count, type_lines);
    try std.testing.expectEqual(field_count, value_lines);

    inline for (@typeInfo(Slot).@"enum".fields) |field| {
        const which: Slot = @enumFromInt(field.value);
        const declaration = comptime "# TYPE " ++ metrics.metric_name(which) ++ " " ++
            metrics.metric_kind(which) ++ "\n";
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, declaration));
    }
}

test "observability: exact capacity succeeds and one byte less fails" {
    const registry = Registry{};
    var measured: [2048]u8 = undefined;
    var storage: [2048]u8 = undefined;

    const full = try registry.write_prometheus(null, &measured);
    const required = full.len;
    try std.testing.expect(required > 0);

    const exact = try registry.write_prometheus(null, storage[0..required]);
    try std.testing.expectEqualStrings(full, exact);
    try std.testing.expectEqual(storage[0..].ptr, exact.ptr);

    try std.testing.expectError(
        error.NoSpaceLeft,
        registry.write_prometheus(null, storage[0 .. required - 1]),
    );
}

test "observability: NoSpaceLeft never writes outside the provided slice" {
    const registry = Registry{};
    const guard = 16;
    const tiny = 8;
    var guarded = [_]u8{0xA5} ** (guard * 2 + tiny);

    try std.testing.expectError(
        error.NoSpaceLeft,
        registry.write_prometheus(null, guarded[guard..][0..tiny]),
    );

    for (guarded[0..guard]) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
    for (guarded[guard + tiny ..]) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);

    var empty_guard = [_]u8{0x5A} ** (guard * 2);
    try std.testing.expectError(
        error.NoSpaceLeft,
        registry.write_prometheus(null, empty_guard[guard..][0..0]),
    );
    for (empty_guard) |byte| try std.testing.expectEqual(@as(u8, 0x5A), byte);
}

test "observability: histogram buckets render cumulative counts with +Inf" {
    const registry = Registry{};
    var buffer: [2048]u8 = undefined;
    const buckets = [_]u64{ 2, 3, 5, 0 };
    const output = try registry.write_prometheus(&buckets, &buffer);

    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "# TYPE uwz_latency_packets_bucket histogram\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"0\"} 2\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"1\"} 5\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"3\"} 10\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"7\"} 10\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"+Inf\"} 10\n",
    ) != null);

    var bucket_lines: usize = 0;
    var rest = output;
    while (std.mem.indexOf(u8, rest, "uwz_latency_packets_bucket{le=")) |index| {
        bucket_lines += 1;
        rest = rest[index + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 5), bucket_lines);

    const without = try registry.write_prometheus(null, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, without, "latency") == null);
    try std.testing.expect(std.mem.indexOf(u8, without, "_bucket") == null);
}

test "observability: histogram cumulative totals saturate" {
    const registry = Registry{};
    var buffer: [2048]u8 = undefined;
    const buckets = [_]u64{ std.math.maxInt(u64), 1 };
    const output = try registry.write_prometheus(&buckets, &buffer);

    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"0\"} 18446744073709551615\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"1\"} 18446744073709551615\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"+Inf\"} 18446744073709551615\n",
    ) != null);
}

test "observability: buckets beyond the u64 boundary roll into +Inf" {
    const registry = Registry{};
    var buffer: [4096]u8 = undefined;
    var buckets = [_]u64{0} ** 70;
    buckets[0] = 1;
    buckets[64] = 2;
    buckets[69] = 4;
    const output = try registry.write_prometheus(&buckets, &buffer);

    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"18446744073709551615\"} 3\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "uwz_latency_packets_bucket{le=\"+Inf\"} 7\n",
    ) != null);

    var bucket_lines: usize = 0;
    var rest = output;
    while (std.mem.indexOf(u8, rest, "uwz_latency_packets_bucket{le=")) |index| {
        bucket_lines += 1;
        rest = rest[index + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 66), bucket_lines);
}
