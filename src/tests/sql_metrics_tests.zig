const std = @import("std");
const metrics = @import("test_support").metrics;

test "sql metrics: pool occupancy is gauges and reconnects a counter" {
    inline for (.{ .sql_active, .sql_idle, .sql_waiting, .sql_failed }) |slot| {
        try std.testing.expectEqualStrings("gauge", metrics.metric_kind(slot));
    }
    try std.testing.expectEqualStrings("uwz_sql_active", metrics.metric_name(.sql_active));
    try std.testing.expectEqualStrings("counter", metrics.metric_kind(.sql_reconnects));
    try std.testing.expectEqualStrings("uwz_sql_reconnects_total", metrics.metric_name(.sql_reconnects));

    var registry = metrics.Registry{};
    registry.set(.sql_active, 8);
    registry.set(.sql_active, 2);
    registry.add(.sql_reconnects, 3);
    var output: [4096]u8 = undefined;
    const rendered = try registry.write_prometheus(null, &output);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "uwz_sql_active 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "uwz_sql_reconnects_total 3\n") != null);
}
