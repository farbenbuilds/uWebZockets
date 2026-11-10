const std = @import("std");
const negotiate = @import("test_support").negotiate;
const fetch = @import("test_support").fetch;

const EncodingCase = struct {
    header: ?[]const u8,
    available: negotiate.EncodingAvailability = .{ .identity = true, .gzip = true, .br = true },
    expected: ?negotiate.Encoding,
};

const QualityCase = struct {
    value: []const u8,
    expected: ?u16,
};

const EncodingFieldsCase = struct {
    first: []const u8,
    second: []const u8,
    expected: ?negotiate.Encoding,
};

test "negotiate: qvalue permits an empty fractional part" {
    const accept = negotiate.parse("text/plain;q=0., application/json;q=1.");
    try std.testing.expectEqual(@as(usize, 2), accept.count);
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "text/plain"));
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "application/json"));
}

test "negotiate: qvalue limits the fractional part to three digits" {
    const accept = negotiate.parse("text/plain;q=1.0000, application/json;q=1.000");
    try std.testing.expectEqual(@as(usize, 1), accept.count);
    try std.testing.expectEqual(@as(u16, 0), negotiate.score(accept, "text/plain"));
    try std.testing.expectEqual(@as(u16, 1000), negotiate.score(accept, "application/json"));
}

test "negotiate: content coding selection preserves weights and explicit refusals" {
    const cases = [_]EncodingCase{
        .{ .header = null, .expected = .identity },
        .{ .header = "", .expected = .identity },
        .{ .header = " \t, ,", .expected = .identity },
        .{ .header = "gzip", .expected = .gzip },
        .{ .header = "br, gzip", .expected = .br },
        .{ .header = "gzip;q=0", .expected = .identity },
        .{ .header = "*;q=0", .expected = null },
        .{ .header = "*;q=0, gzip;q=1", .expected = .gzip },
        .{ .header = "*;q=1, gzip;q=0", .expected = .br },
        .{ .header = "*;q=0, identity;q=0.7", .expected = .identity },
        .{ .header = "identity;q=0, *;q=0.7", .expected = .br },
        .{ .header = "br;q=0.5, gzip;q=0.8, identity;q=0.1", .expected = .gzip },
        .{ .header = "br;q=0.5, gzip;q=0.8", .expected = .identity },
        .{ .header = "br;q=0, gzip;q=0, identity;q=0", .expected = null },
        .{ .header = " GZIP ; Q=1. , Br;q=0.999, IDENTITY;q=0.1", .expected = .gzip },
        .{ .header = "gzip;q=0.001, identity;q=0", .expected = .gzip },
        .{ .header = "gzip;q=0., identity;q=0", .expected = null },
        .{ .header = "zstd, unknown", .expected = .identity },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, negotiate.select_encoding(case.header, case.available));
    }
}

test "negotiate: content coding selection only considers available representations" {
    const cases = [_]EncodingCase{
        .{ .header = null, .available = .{ .identity = false, .br = true }, .expected = .br },
        .{ .header = "", .available = .{ .identity = false, .br = true }, .expected = null },
        .{ .header = "br, gzip", .available = .{ .gzip = true }, .expected = .gzip },
        .{ .header = "br;q=1, gzip;q=0.5, identity;q=0.1", .available = .{ .gzip = true }, .expected = .gzip },
        .{ .header = "br, gzip", .available = .{}, .expected = .identity },
        .{ .header = "*", .available = .{ .identity = false }, .expected = null },
        .{ .header = "gzip;q=0, identity;q=0", .available = .{ .gzip = true }, .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, negotiate.select_encoding(case.header, case.available));
    }
}

test "negotiate: duplicate coding refusals cannot be undone" {
    const cases = [_]EncodingCase{
        .{ .header = "gzip;q=0, gzip;q=1", .expected = .identity },
        .{ .header = "gzip;q=1, GZIP;q=0", .expected = .identity },
        .{ .header = "gzip;q=1, gzip;q=0.2, identity;q=0.5", .expected = .identity },
        .{ .header = "*;q=0, *;q=1", .expected = null },
        .{ .header = "identity;q=0, identity;q=1", .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, negotiate.select_encoding(case.header, case.available));
    }
}

test "negotiate: coding refusals beyond media entry capacity are honored" {
    const header = ("unknown, " ** 20) ++ "gzip;q=0, br;q=0, identity;q=0, *;q=1";
    try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding(
        header,
        .{ .gzip = true, .br = true },
    ));
}

test "negotiate: malformed known coding weights fail closed" {
    const headers = [_][]const u8{
        "gzip;q=1.0000", "gzip;q=.5", "gzip;q=01",    "gzip;q=1.001",
        "gzip;q=0.1234", "gzip;q=-1", "gzip;q=NaN",   "gzip;q=\"1\"",
        "gzip;q=1;q=1",  "gzip;q",    "gzip;level=1", "gzip;q=1;",
    };
    for (headers) |header| {
        var buffer: [128]u8 = undefined;
        const field = try std.fmt.bufPrint(&buffer, "{s}, *;q=1, identity;q=0", .{header});
        try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding(
            field,
            .{ .identity = false, .gzip = true },
        ));
    }
}

test "negotiate: shared qvalue parser follows the complete RFC grammar" {
    const cases = [_]QualityCase{
        .{ .value = "0", .expected = 0 },
        .{ .value = "0.", .expected = 0 },
        .{ .value = "0.0", .expected = 0 },
        .{ .value = "0.001", .expected = 1 },
        .{ .value = "0.999", .expected = 999 },
        .{ .value = "1", .expected = 1000 },
        .{ .value = "1.", .expected = 1000 },
        .{ .value = "1.0", .expected = 1000 },
        .{ .value = "1.000", .expected = 1000 },
        .{ .value = ".5", .expected = null },
        .{ .value = "01", .expected = null },
        .{ .value = "1.001", .expected = null },
        .{ .value = "1.0000", .expected = null },
        .{ .value = "0.1234", .expected = null },
        .{ .value = "-1", .expected = null },
        .{ .value = "NaN", .expected = null },
        .{ .value = "\"1\"", .expected = null },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        const field = try std.fmt.bufPrint(&buffer, "text/plain;q={s}", .{case.value});
        const accept = negotiate.parse(field);
        if (case.expected) |quality| {
            try std.testing.expectEqual(@as(usize, 1), accept.count);
            try std.testing.expectEqual(quality, negotiate.score(accept, "text/plain"));
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), accept.count);
    }
}

test "negotiate: all coding field lines preserve later refusals" {
    const headers = fetch.HeadersView.init(
        &.{ "Accept-Encoding", "x-other", "aCcEpT-EnCoDiNg", "ACCEPT-ENCODING" },
        &.{ "gzip, br", "*;q=1", "gzip;q=0, br;q=0", "identity;q=0" },
    );
    try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding_headers(
        headers,
        .{ .gzip = true, .br = true },
    ));
}

test "negotiate: coding fields beyond inline header storage preserve refusals" {
    var names = [_][]const u8{"x-other"} ** 64;
    var values = [_][]const u8{"ignored"} ** 64;
    names[0] = "Accept-Encoding";
    values[0] = ("unknown, " ** 20) ++ "gzip, br";
    const headers = fetch.HeadersView.init_with_extra(
        &names,
        &values,
        &.{ "x-other", "accept-encoding", "ACCEPT-ENCODING" },
        &.{ "*;q=1", "gzip;q=0, br;q=0", "identity;q=0" },
    );
    try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding_headers(
        headers,
        .{ .gzip = true, .br = true },
    ));
}

test "negotiate: absent coding fields differ from all present empty fields" {
    const available = negotiate.EncodingAvailability{ .identity = false, .br = true };
    const absent = fetch.HeadersView.init(&.{"x-other"}, &.{"br"});
    try std.testing.expectEqual(@as(?negotiate.Encoding, .br), negotiate.select_encoding_headers(absent, available));
    const empty = fetch.HeadersView.init_with_extra(
        &.{ "Accept-Encoding", "x-other" },
        &.{ "", "br" },
        &.{"accept-encoding"},
        &.{" \t, ,"},
    );
    try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding_headers(empty, available));
    try std.testing.expectEqual(@as(?negotiate.Encoding, .identity), negotiate.select_encoding_headers(
        empty,
        .{ .br = true },
    ));
    const later = fetch.HeadersView.init(&.{ "Accept-Encoding", "accept-encoding" }, &.{ "", "br" });
    try std.testing.expectEqual(@as(?negotiate.Encoding, .br), negotiate.select_encoding_headers(later, available));
}

test "negotiate: malformed later coding weights cannot be undone" {
    const malformed = [_][]const u8{
        "gzip;q=1.0000", "gzip;q=.5", "gzip;q=01",    "gzip;q=1.001",
        "gzip;q=0.1234", "gzip;q=-1", "gzip;q=NaN",   "gzip;q=\"1\"",
        "gzip;q=1;q=1",  "gzip;q",    "gzip;level=1", "gzip;q=1;",
    };
    for (malformed) |field| {
        const headers = fetch.HeadersView.init_with_extra(
            &.{"Accept-Encoding"},
            &.{"*;q=1, identity;q=0"},
            &.{ "accept-encoding", "ACCEPT-ENCODING" },
            &.{ field, "gzip;q=1" },
        );
        try std.testing.expectEqual(@as(?negotiate.Encoding, null), negotiate.select_encoding_headers(
            headers,
            .{ .identity = false, .gzip = true },
        ));
    }
}

test "negotiate: coding fields share wildcard precedence and identity defaults" {
    const cases = [_]EncodingFieldsCase{
        .{ .first = "*;q=0", .second = "gzip;q=1", .expected = .gzip },
        .{ .first = "*;q=1", .second = "gzip;q=0", .expected = .br },
        .{ .first = "*;q=0", .second = "identity;q=0.7", .expected = .identity },
        .{ .first = "identity;q=0", .second = "*;q=0.7", .expected = .br },
        .{ .first = "br;q=0.5", .second = "gzip;q=0.8", .expected = .identity },
        .{ .first = "br;q=1, identity;q=1", .second = "gzip;q=1", .expected = .br },
        .{ .first = "gzip;q=1, br;q=0", .second = "identity;q=1", .expected = .gzip },
        .{ .first = "*;q=1", .second = "*;q=0", .expected = null },
        .{ .first = "*;q=1", .second = "*;q=invalid", .expected = null },
        .{ .first = "identity;q=1", .second = "identity;q=invalid", .expected = null },
    };
    for (cases) |case| {
        const forward = fetch.HeadersView.init(&.{ "Accept-Encoding", "accept-encoding" }, &.{ case.first, case.second });
        const reverse = fetch.HeadersView.init(&.{ "accept-encoding", "Accept-Encoding" }, &.{ case.second, case.first });
        const available = negotiate.EncodingAvailability{ .gzip = true, .br = true };
        try std.testing.expectEqual(case.expected, negotiate.select_encoding_headers(forward, available));
        try std.testing.expectEqual(case.expected, negotiate.select_encoding_headers(reverse, available));
    }
}

test "negotiate: coding duplicate minimum weights survive field permutations" {
    const fields = [_][]const u8{ "gzip;q=1, identity;q=0.5", "GZIP;q=0.2", "gzip;q=0.8, br;q=0" };
    const permutations = [_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } };
    for (permutations) |order| {
        const headers = fetch.HeadersView.init_with_extra(
            &.{"Accept-Encoding"},
            &.{fields[order[0]]},
            &.{ "accept-encoding", "ACCEPT-ENCODING" },
            &.{ fields[order[1]], fields[order[2]] },
        );
        try std.testing.expectEqual(@as(?negotiate.Encoding, .identity), negotiate.select_encoding_headers(
            headers,
            .{ .gzip = true, .br = true },
        ));
    }
}
