//! Tests for schema validation and cookie helper extensions.

const std = @import("std");
const support = @import("test_support");

const schema = support.schema;
const cookie = support.cookie;

test "schema: int and string rules keep their existing verdicts" {
    const User = struct {
        name: []const u8,
        age: u8,

        pub const validation = .{
            .name = schema.Rule{ .min_length = 2, .max_length = 4 },
            .age = schema.Rule{ .min = 18, .max = 120 },
        };
    };

    var issue = schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(User, std.testing.allocator, "{\"name\":\"A\",\"age\":42}", &issue),
    );
    try std.testing.expectEqualStrings("name", issue.field);
    try std.testing.expectEqual(schema.IssueKind.too_short, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(User, std.testing.allocator, "{\"name\":\"Zig\",\"age\":17}", &issue),
    );
    try std.testing.expectEqualStrings("age", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(User, std.testing.allocator, "{\"name\":\"Zig\",\"age\":121}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.above_maximum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(User, std.testing.allocator, "{\"name\":\"Ziggy\",\"age\":30}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.too_long, issue.kind);

    var parsed = try schema.validate_json(User, std.testing.allocator, "{\"name\":\"Zig\",\"age\":30}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Zig", parsed.value.name);
    try std.testing.expectEqual(@as(u8, 30), parsed.value.age);
}

test "schema: float bounds report below_minimum and above_maximum" {
    const Metrics = struct {
        ratio: f64,
        share: f32,

        pub const validation = .{
            // Integer bounds are ignored for float fields, so the success case
            // below proves them inert instead of accidentally passing.
            .ratio = schema.Rule{ .min = 100, .max = 0, .min_float = 0.5, .max_float = 2.0 },
            .share = schema.Rule{ .min_float = 0.5, .max_float = 2.0 },
        };
    };

    var issue = schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Metrics, std.testing.allocator, "{\"ratio\":0.25,\"share\":1.0}", &issue),
    );
    try std.testing.expectEqualStrings("ratio", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Metrics, std.testing.allocator, "{\"ratio\":3.5,\"share\":1.0}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.above_maximum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Metrics, std.testing.allocator, "{\"ratio\":1.0,\"share\":0.25}", &issue),
    );
    try std.testing.expectEqualStrings("share", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    var parsed = try schema.validate_json(Metrics, std.testing.allocator, "{\"ratio\":1.0,\"share\":1.5}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.ratio);

    var integer = try schema.validate_json(Metrics, std.testing.allocator, "{\"ratio\":1,\"share\":1}");
    defer integer.deinit();
    try std.testing.expectEqual(@as(f32, 1.0), integer.value.share);
}

test "schema: item bounds report too_few_items and too_many_items" {
    const Batch = struct {
        values: []const u16,

        pub const validation = .{
            .values = schema.Rule{ .min_items = 1, .max_items = 2 },
        };
    };
    const Short = struct {
        pair: [2]u8,

        pub const validation = .{
            .pair = schema.Rule{ .min_items = 3 },
        };
    };
    const Long = struct {
        pair: [2]u8,

        pub const validation = .{
            .pair = schema.Rule{ .max_items = 1 },
        };
    };

    var issue = schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Batch, std.testing.allocator, "{\"values\":[]}", &issue),
    );
    try std.testing.expectEqualStrings("values", issue.field);
    try std.testing.expectEqual(schema.IssueKind.too_few_items, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Batch, std.testing.allocator, "{\"values\":[1,2,3]}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.too_many_items, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Short, std.testing.allocator, "{\"pair\":[1,2]}", &issue),
    );
    try std.testing.expectEqualStrings("pair", issue.field);
    try std.testing.expectEqual(schema.IssueKind.too_few_items, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Long, std.testing.allocator, "{\"pair\":[1,2]}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.too_many_items, issue.kind);

    var parsed = try schema.validate_json(Batch, std.testing.allocator, "{\"values\":[7]}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.values.len);
}

test "schema: allowed values match whole strings and enum tag names" {
    const Mode = enum { fast, slow };
    const Command = struct {
        method: []const u8,
        mode: Mode,

        pub const validation = .{
            .method = schema.Rule{ .allowed = &.{ "GET", "POST" } },
            .mode = schema.Rule{ .allowed = &.{"fast"} },
        };
    };

    var issue = schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Command, std.testing.allocator, "{\"method\":\"get\",\"mode\":\"fast\"}", &issue),
    );
    try std.testing.expectEqualStrings("method", issue.field);
    try std.testing.expectEqual(schema.IssueKind.invalid_enum_tag, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Command, std.testing.allocator, "{\"method\":\"PUT\",\"mode\":\"fast\"}", &issue),
    );
    try std.testing.expectEqualStrings("method", issue.field);
    try std.testing.expectEqual(schema.IssueKind.invalid_enum_tag, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(Command, std.testing.allocator, "{\"method\":\"GET\",\"mode\":\"slow\"}", &issue),
    );
    try std.testing.expectEqualStrings("mode", issue.field);
    try std.testing.expectEqual(schema.IssueKind.invalid_enum_tag, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Command, std.testing.allocator, "{\"method\":\"GET\",\"mode\":\"Fast\"}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.invalid_enum_tag, issue.kind);

    var parsed = try schema.validate_json(Command, std.testing.allocator, "{\"method\":\"POST\",\"mode\":\"fast\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(Mode.fast, parsed.value.mode);
}

test "schema: nested validation reports the leaf field name" {
    const Leaf = struct {
        quantity: u8,

        pub const validation = .{
            .quantity = schema.Rule{ .min = 5 },
        };
    };
    const Outer = struct {
        leaf: Leaf,
        list: []const Leaf,
        fixed: [1]Leaf,

        pub const validation = .{};
    };

    var issue = schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(
            Outer,
            std.testing.allocator,
            "{\"leaf\":{\"quantity\":1},\"list\":[],\"fixed\":[{\"quantity\":9}]}",
            &issue,
        ),
    );
    try std.testing.expectEqualStrings("quantity", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(
            Outer,
            std.testing.allocator,
            "{\"leaf\":{\"quantity\":9},\"list\":[{\"quantity\":0}],\"fixed\":[{\"quantity\":9}]}",
            &issue,
        ),
    );
    try std.testing.expectEqualStrings("quantity", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    try std.testing.expectError(
        error.ConstraintViolation,
        schema.validate_json_detailed(
            Outer,
            std.testing.allocator,
            "{\"leaf\":{\"quantity\":9},\"list\":[],\"fixed\":[{\"quantity\":0}]}",
            &issue,
        ),
    );
    try std.testing.expectEqualStrings("quantity", issue.field);

    var parsed = try schema.validate_json(
        Outer,
        std.testing.allocator,
        "{\"leaf\":{\"quantity\":9},\"list\":[{\"quantity\":6}],\"fixed\":[{\"quantity\":7}]}",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 9), parsed.value.leaf.quantity);
    try std.testing.expectEqual(@as(u8, 7), parsed.value.fixed[0].quantity);
}

test "schema: nested validation stops at max_nested_depth" {
    const Leaf = struct {
        score: u8,

        pub const validation = .{
            .score = schema.Rule{ .min = 1 },
        };
    };
    const Level1 = struct {
        leaf: Leaf,

        pub const validation = .{};
    };
    const Level2 = struct {
        child: Level1,

        pub const validation = .{};
    };
    const Level3 = struct {
        child: Level2,

        pub const validation = .{};
    };
    const Level4 = struct {
        child: Level3,

        pub const validation = .{};
    };
    const Level5 = struct {
        child: Level4,

        pub const validation = .{};
    };

    var issue = schema.Issue{};
    const shallow = Level2{ .child = .{ .leaf = .{ .score = 0 } } };
    try std.testing.expectError(error.ConstraintViolation, schema.validate(Level2, shallow, &issue));
    try std.testing.expectEqualStrings("score", issue.field);
    try std.testing.expectEqual(schema.IssueKind.below_minimum, issue.kind);

    const deep = Level5{ .child = .{ .child = .{ .child = .{ .child = .{ .leaf = .{ .score = 0 } } } } } };
    issue = .{};
    try schema.validate(Level5, deep, &issue);
    try std.testing.expectEqualStrings("", issue.field);
    try std.testing.expectEqual(schema.IssueKind.malformed_json, issue.kind);

    // A self-referential pointer must not be chased by the walker.
    const Node = struct {
        child: ?*const @This(),
        score: u8,

        pub const validation = .{
            .score = schema.Rule{ .min = 1 },
        };
    };
    const node = Node{ .child = null, .score = 0 };
    try std.testing.expectError(error.ConstraintViolation, schema.validate(Node, node, &issue));
    try std.testing.expectEqualStrings("score", issue.field);
}

test "schema: parse failures map to issue kinds" {
    const Counted = struct { count: u8 };
    const Pair = struct { pair: [2]u8 };
    const Mode = enum { fast, slow };
    const Tagged = struct { mode: Mode };

    var issue = schema.Issue{};

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{1:2}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.syntax_error, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{\"count\":1", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.unexpected_end_of_input, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "[1,]", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.unexpected_token, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{\"count\":\"abc\"}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.invalid_number, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{\"count\":300}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.number_overflow, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Pair, std.testing.allocator, "{\"pair\":\"abc\"}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.length_mismatch, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.missing_field, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{\"count\":1,\"extra\":2}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.unknown_field, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Counted, std.testing.allocator, "{\"count\":1,\"count\":2}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.duplicate_field, issue.kind);

    try std.testing.expectError(
        error.MalformedJson,
        schema.validate_json_detailed(Tagged, std.testing.allocator, "{\"mode\":\"Fast\"}", &issue),
    );
    try std.testing.expectEqual(schema.IssueKind.invalid_enum_tag, issue.kind);
}

test "schema: out of memory propagates unchanged" {
    const Counted = struct { count: u8 };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var issue = schema.Issue{};
    try std.testing.expectError(
        error.OutOfMemory,
        schema.validate_json_detailed(Counted, failing.allocator(), "{\"count\":1}", &issue),
    );
}

test "cookie: iterator yields valid pairs and skips malformed ones" {
    const header = "good=1; bad; =novalue; also_good=2; broken name=3; empty=; spaced = 4";
    var pairs = cookie.iterator(header);

    const first = pairs.next().?;
    try std.testing.expectEqualStrings("good", first.name);
    try std.testing.expectEqualStrings("1", first.value);

    const second = pairs.next().?;
    try std.testing.expectEqualStrings("also_good", second.name);
    try std.testing.expectEqualStrings("2", second.value);

    const third = pairs.next().?;
    try std.testing.expectEqualStrings("empty", third.name);
    try std.testing.expectEqualStrings("", third.value);

    const fourth = pairs.next().?;
    try std.testing.expectEqualStrings("spaced", fourth.name);
    try std.testing.expectEqualStrings("4", fourth.value);

    try std.testing.expect(pairs.next() == null);
}

test "cookie: iterator on an empty header yields no pairs" {
    var empty = cookie.iterator("");
    try std.testing.expect(empty.next() == null);

    var blank = cookie.iterator("   ");
    try std.testing.expect(blank.next() == null);
}

test "cookie: versioned signing round trips and verifies with rotation keys" {
    const secret = "0123456789abcdef0123456789abcdef";
    const rotated_secret = "abcdef0123456789abcdef0123456789";
    const key = cookie.Key{ .id = "v1", .secret = secret };
    const rotated_key = cookie.Key{ .id = "v2", .secret = rotated_secret };

    var buffer: [128]u8 = undefined;
    const signed = try cookie.sign_versioned(&buffer, "payload", key);
    try std.testing.expect(std.mem.startsWith(u8, signed, "v1.payload."));
    try std.testing.expectEqual(@as(usize, 2 + 1 + 7 + 1 + 64), signed.len);
    try std.testing.expectEqualStrings("payload", try cookie.verify_versioned(signed, &.{key}));
    try std.testing.expectEqualStrings("payload", try cookie.verify_versioned(signed, &.{ rotated_key, key }));

    var rotated_buffer: [128]u8 = undefined;
    const signed_rotated = try cookie.sign_versioned(&rotated_buffer, "payload", rotated_key);
    try std.testing.expectEqualStrings("payload", try cookie.verify_versioned(signed_rotated, &.{ rotated_key, key }));
    try std.testing.expectError(error.UnknownKeyId, cookie.verify_versioned(signed_rotated, &.{key}));
}

test "cookie: versioned verification rejects tampered values" {
    const secret = "0123456789abcdef0123456789abcdef";
    const key = cookie.Key{ .id = "v1", .secret = secret };

    var buffer: [128]u8 = undefined;
    const signed = try cookie.sign_versioned(&buffer, "payload", key);

    try std.testing.expectError(error.UnknownKeyId, cookie.verify_versioned(signed, &.{}));
    try std.testing.expectError(error.InvalidCookieSignature, cookie.verify_versioned("nodots", &.{key}));
    try std.testing.expectError(error.InvalidCookieSignature, cookie.verify_versioned("v1.payload", &.{key}));

    var tampered: [128]u8 = undefined;
    @memcpy(tampered[0..signed.len], signed);
    tampered[3] = 'x';
    try std.testing.expectError(
        error.InvalidCookieSignature,
        cookie.verify_versioned(tampered[0..signed.len], &.{key}),
    );

    @memcpy(tampered[0..signed.len], signed);
    tampered[signed.len - 1] = if (tampered[signed.len - 1] == '0') '1' else '0';
    try std.testing.expectError(
        error.InvalidCookieSignature,
        cookie.verify_versioned(tampered[0..signed.len], &.{key}),
    );

    @memcpy(tampered[0..signed.len], signed);
    @memset(tampered[signed.len - 64 ..], 'z');
    try std.testing.expectError(
        error.InvalidCookieSignature,
        cookie.verify_versioned(tampered[0..signed.len], &.{key}),
    );
}

test "cookie: versioned signing rejects invalid keys and payloads" {
    const secret = "0123456789abcdef0123456789abcdef";
    var buffer: [128]u8 = undefined;

    try std.testing.expectError(
        error.InvalidKeyId,
        cookie.sign_versioned(&buffer, "payload", .{ .id = "", .secret = secret }),
    );
    try std.testing.expectError(
        error.InvalidKeyId,
        cookie.sign_versioned(&buffer, "payload", .{ .id = "v.1", .secret = secret }),
    );
    try std.testing.expectError(
        error.InvalidKeyId,
        cookie.sign_versioned(&buffer, "payload", .{ .id = "bad id", .secret = secret }),
    );
    try std.testing.expectError(
        error.InvalidKeyId,
        cookie.sign_versioned(&buffer, "payload", .{ .id = "a" ** 33, .secret = secret }),
    );
    try std.testing.expectError(
        error.CookieSecretTooShort,
        cookie.sign_versioned(&buffer, "payload", .{ .id = "v1", .secret = "short" }),
    );
    try std.testing.expectError(
        error.InvalidCookieValue,
        cookie.sign_versioned(&buffer, "bad value", .{ .id = "v1", .secret = secret }),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        cookie.sign_versioned(buffer[0..10], "payload", .{ .id = "v1", .secret = secret }),
    );
}

test "cookie: prefix enforcement opts in without changing defaults" {
    var buffer: [256]u8 = undefined;

    const host = try cookie.format(&buffer, "__Host-id", "v", .{
        .secure = true,
        .enforce_prefixes = true,
    });
    try std.testing.expectEqualStrings("Set-Cookie: __Host-id=v; Path=/; Secure\r\n", host);

    try std.testing.expectError(
        error.InsecureCookiePrefix,
        cookie.format(&buffer, "__Host-id", "v", .{
            .secure = true,
            .path = null,
            .enforce_prefixes = true,
        }),
    );
    try std.testing.expectError(
        error.InsecureCookiePrefix,
        cookie.format(&buffer, "__Host-id", "v", .{
            .secure = true,
            .path = "/sub",
            .enforce_prefixes = true,
        }),
    );
    try std.testing.expectError(
        error.InsecureCookiePrefix,
        cookie.format(&buffer, "__Host-id", "v", .{
            .secure = true,
            .domain = "example.com",
            .enforce_prefixes = true,
        }),
    );
    try std.testing.expectError(
        error.InsecureCookiePrefix,
        cookie.format(&buffer, "__Host-id", "v", .{ .enforce_prefixes = true }),
    );

    const secure = try cookie.format(&buffer, "__Secure-id", "v", .{
        .secure = true,
        .enforce_prefixes = true,
    });
    try std.testing.expectEqualStrings("Set-Cookie: __Secure-id=v; Path=/; Secure\r\n", secure);
    try std.testing.expectError(
        error.InsecureCookiePrefix,
        cookie.format(&buffer, "__Secure-id", "v", .{ .enforce_prefixes = true }),
    );

    // The prefix check is case-sensitive, so a lowercase name is not constrained.
    const lowercase = try cookie.format(&buffer, "__host-id", "v", .{
        .enforce_prefixes = true,
    });
    try std.testing.expectEqualStrings("Set-Cookie: __host-id=v; Path=/\r\n", lowercase);

    const legacy = try cookie.format(&buffer, "__Host-id", "v", .{});
    try std.testing.expectEqualStrings("Set-Cookie: __Host-id=v; Path=/\r\n", legacy);
}

test "cookie: format_http_date matches the RFC 9110 IMF-fixdate examples" {
    var buffer: cookie.HttpDateBuffer = undefined;
    try std.testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        try cookie.format_http_date(&buffer, 0),
    );
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        try cookie.format_http_date(&buffer, 784111777),
    );
    try std.testing.expectEqual(@as(usize, 29), (try cookie.format_http_date(&buffer, 784111777)).len);
}

test "cookie: format_http_date handles a leap day, post-2038, and year 9999" {
    var buffer: cookie.HttpDateBuffer = undefined;
    try std.testing.expectEqualStrings(
        "Tue, 29 Feb 2000 00:00:00 GMT",
        try cookie.format_http_date(&buffer, 951782400),
    );
    try std.testing.expectEqualStrings(
        "Tue, 19 Jan 2038 03:14:07 GMT",
        try cookie.format_http_date(&buffer, 2147483647),
    );
    try std.testing.expectEqualStrings(
        "Fri, 31 Dec 9999 23:59:59 GMT",
        try cookie.format_http_date(&buffer, 253402300799),
    );
}

test "cookie: format_http_date pads one-digit days and names Sunday" {
    var buffer: cookie.HttpDateBuffer = undefined;
    try std.testing.expectEqualStrings(
        "Fri, 01 Jan 2016 00:00:00 GMT",
        try cookie.format_http_date(&buffer, 1451606400),
    );
    try std.testing.expectEqualStrings(
        "Sun, 04 Jan 1970 00:00:00 GMT",
        try cookie.format_http_date(&buffer, 259200),
    );
}

test "cookie: format_http_date rejects negative seconds and years past 9999" {
    var buffer: cookie.HttpDateBuffer = undefined;
    try std.testing.expectError(error.InvalidExpires, cookie.format_http_date(&buffer, -1));
    try std.testing.expectError(error.InvalidExpires, cookie.format_http_date(&buffer, std.math.minInt(i64)));
    try std.testing.expectError(error.InvalidExpires, cookie.format_http_date(&buffer, 253402300800));
    try std.testing.expectError(error.InvalidExpires, cookie.format_http_date(&buffer, std.math.maxInt(i64)));
}

test "cookie: format emits Expires once and only after Max-Age" {
    var buffer: [256]u8 = undefined;
    const field = try cookie.format(&buffer, "session", "abc", .{
        .path = "/",
        .max_age = 60,
        .http_only = true,
        .expires_unix = 784111777,
    });
    try std.testing.expectEqualStrings(
        "Set-Cookie: session=abc; Path=/; Max-Age=60; Expires=Sun, 06 Nov 1994 08:49:37 GMT; HttpOnly\r\n",
        field,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, field, "Expires="));
}

test "cookie: format without expires_unix keeps the previous bytes" {
    var buffer: [256]u8 = undefined;
    const field = try cookie.format(&buffer, "session", "abc", .{
        .path = "/",
        .max_age = 60,
        .http_only = true,
    });
    try std.testing.expectEqualStrings("Set-Cookie: session=abc; Path=/; Max-Age=60; HttpOnly\r\n", field);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, field, "Expires"));
}

test "cookie: format writes both Max-Age and Expires when both are set" {
    var buffer: [256]u8 = undefined;
    const field = try cookie.format(&buffer, "session", "abc", .{
        .max_age = 3600,
        .expires_unix = 1451606400,
    });
    try std.testing.expectEqualStrings(
        "Set-Cookie: session=abc; Path=/; Max-Age=3600; Expires=Fri, 01 Jan 2016 00:00:00 GMT\r\n",
        field,
    );
    const max_age_position = std.mem.indexOf(u8, field, "Max-Age=3600").?;
    const expires_position = std.mem.indexOf(u8, field, "Expires=").?;
    try std.testing.expect(max_age_position < expires_position);
}

test "cookie: format propagates an invalid expires value" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidExpires,
        cookie.format(&buffer, "session", "abc", .{ .expires_unix = -1 }),
    );
}
