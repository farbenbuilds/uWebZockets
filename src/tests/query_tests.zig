const std = @import("std");
const support = @import("test_support");
const query = support.query;
const form = support.form;
const Request = support.http_request.Request;

test "query: parse_link slices pairs from the target without copying" {
    const target = "/api/items?page=2&q=hello%20world&tag=a&tag=b";
    const params = try query.QueryParams.parse_link(target);

    try std.testing.expectEqual(@as(usize, 4), params.count);
    try std.testing.expectEqualStrings("page", params.at(0).?.key);
    try std.testing.expectEqualStrings("2", params.at(0).?.value);
    try std.testing.expectEqualStrings("hello%20world", params.get("q").?);
    try std.testing.expectEqualStrings("a", params.get("tag").?);
    try std.testing.expectEqualStrings("b", params.get_last("tag").?);
    try std.testing.expectEqual(@as(usize, 2), params.count_named("tag"));
    try std.testing.expect(params.has("page"));
    try std.testing.expect(!params.has("missing"));

    const target_start = @intFromPtr(target.ptr);
    const target_end = target_start + target.len;
    for (0..params.count) |index| {
        const pair = params.at(index).?;
        try std.testing.expect(@intFromPtr(pair.key.ptr) >= target_start);
        try std.testing.expect(@intFromPtr(pair.key.ptr) + pair.key.len <= target_end);
        try std.testing.expect(@intFromPtr(pair.value.ptr) >= target_start);
        try std.testing.expect(@intFromPtr(pair.value.ptr) + pair.value.len <= target_end);
    }
}

test "query: parse handles empty segments, flags, and embedded equals" {
    const params = try query.QueryParams.parse("&&a=1&flag&b=x=y&&");
    try std.testing.expectEqual(@as(usize, 3), params.count);
    try std.testing.expectEqualStrings("a", params.at(0).?.key);
    try std.testing.expectEqualStrings("1", params.at(0).?.value);
    try std.testing.expectEqualStrings("flag", params.at(1).?.key);
    try std.testing.expectEqualStrings("", params.at(1).?.value);
    try std.testing.expectEqualStrings("b", params.at(2).?.key);
    try std.testing.expectEqualStrings("x=y", params.at(2).?.value);
}

test "query: flag values keep their slice inside the parsed buffer" {
    const target = "/search?flag&name=zig";
    const params = try query.QueryParams.parse_link(target);

    const start = @intFromPtr(target.ptr);
    const end = start + target.len;
    for (0..params.count) |index| {
        const pair = params.at(index).?;
        try std.testing.expect(@intFromPtr(pair.key.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.key.ptr) + pair.key.len <= end);
        try std.testing.expect(@intFromPtr(pair.value.ptr) >= start);
        try std.testing.expect(@intFromPtr(pair.value.ptr) + pair.value.len <= end);
    }
}

test "query: empty keys are skipped" {
    const params = try query.QueryParams.parse("=1&a=2");
    try std.testing.expectEqual(@as(usize, 1), params.count);
    try std.testing.expectEqualStrings("a", params.at(0).?.key);
}

test "query: parse_link without a question mark yields an empty view" {
    const params = try query.QueryParams.parse_link("/api/items");
    try std.testing.expectEqual(@as(usize, 0), params.count);
    try std.testing.expect(params.get("page") == null);
}

test "query: pair iterator borrows the parsed view" {
    const params = try query.QueryParams.parse("first=1&second=2");
    var iterator = params.pairs();
    try std.testing.expectEqualStrings("first", iterator.next().?.key);
    try std.testing.expectEqualStrings("second", iterator.next().?.key);
    try std.testing.expect(iterator.next() == null);
}

test "query: overflow fails closed instead of truncating" {
    var buffer: [512]u8 = undefined;
    var offset: usize = 0;
    for (0..query.max_params + 1) |index| {
        const written = try std.fmt.bufPrint(buffer[offset..], "k{d}=v&", .{index});
        offset += written.len;
    }
    try std.testing.expectError(
        error.TooManyQueryParameters,
        query.QueryParams.parse(buffer[0..offset]),
    );
}

test "query: compile-time capacity expands the pair table" {
    var buffer: [512]u8 = undefined;
    var offset: usize = 0;
    for (0..40) |index| {
        const written = try std.fmt.bufPrint(buffer[offset..], "k{d}=v{d}&", .{ index, index });
        offset += written.len;
    }
    const input = buffer[0..offset];

    const params = try query.QueryParamsOf(64).parse(input);
    try std.testing.expectEqual(@as(usize, 40), params.count);
    try std.testing.expectEqualStrings("k0", params.at(0).?.key);
    try std.testing.expectEqualStrings("v0", params.at(0).?.value);
    try std.testing.expectEqualStrings("k39", params.at(39).?.key);
    try std.testing.expectEqualStrings("v39", params.get_last("k39").?);

    try std.testing.expectError(
        error.TooManyQueryParameters,
        query.QueryParams.parse(input),
    );
}

test "query: small capacity fails closed on the first overflow" {
    const params = try query.QueryParamsOf(4).parse("a=1&b=2&c=3&d=4");
    try std.testing.expectEqual(@as(usize, 4), params.count);
    try std.testing.expectEqualStrings("4", params.get("d").?);

    try std.testing.expectError(
        error.TooManyQueryParameters,
        query.QueryParamsOf(4).parse("a=1&b=2&c=3&d=4&e=5"),
    );

    const empty = try query.QueryParamsOf(0).parse("");
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expectError(
        error.TooManyQueryParameters,
        query.QueryParamsOf(0).parse("a=1"),
    );
}

test "query: percent_decode decodes escapes and preserves plus" {
    var scratch: [64]u8 = undefined;

    try std.testing.expectEqualStrings(
        "a b/c",
        try query.percent_decode("a%20b%2Fc", &scratch),
    );
    try std.testing.expectEqualStrings(
        "a+b",
        try query.percent_decode("a+b", &scratch),
    );
    try std.testing.expectEqualStrings(
        "~",
        try query.percent_decode("%7e", &scratch),
    );
}

test "query: percent_decode rejects malformed escapes" {
    var scratch: [64]u8 = undefined;

    try std.testing.expectError(
        error.InvalidPercentEncoding,
        query.percent_decode("bad%2", &scratch),
    );
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        query.percent_decode("bad%zz", &scratch),
    );
    try std.testing.expectError(
        error.NoSpaceLeft,
        query.percent_decode("abc", scratch[0..2]),
    );
}

test "query: form_decode maps plus to space" {
    var scratch: [64]u8 = undefined;

    try std.testing.expectEqualStrings(
        "hello world",
        try query.form_decode("hello+world", &scratch),
    );
    try std.testing.expectEqualStrings(
        "a b%c",
        try query.form_decode("a+b%25c", &scratch),
    );
}

test "form: media type validation ignores parameters and case" {
    try std.testing.expect(form.is_form_content_type("application/x-www-form-urlencoded"));
    try std.testing.expect(form.is_form_content_type(
        "Application/X-WWW-Form-Urlencoded; charset=UTF-8",
    ));
    try std.testing.expect(!form.is_form_content_type("multipart/form-data; boundary=x"));
    try std.testing.expect(!form.is_form_content_type(""));
}

test "form: parse validates the media type before slicing" {
    const body = "name=uWebZockets&tag=zig&tag=network";
    const params = try form.parse("application/x-www-form-urlencoded", body);

    try std.testing.expectEqual(@as(usize, 3), params.count);
    try std.testing.expectEqualStrings("uWebZockets", params.get("name").?);
    try std.testing.expectEqual(@as(usize, 2), params.count_named("tag"));

    try std.testing.expectError(
        error.UnsupportedMediaType,
        form.parse("application/json", body),
    );
}

test "form: parse_of honors the requested capacity" {
    var buffer: [512]u8 = undefined;
    var offset: usize = 0;
    for (0..36) |index| {
        const written = try std.fmt.bufPrint(buffer[offset..], "f{d}=v{d}&", .{ index, index });
        offset += written.len;
    }
    const body = buffer[0..offset];

    const fields = try form.parse_of(48, "application/x-www-form-urlencoded", body);
    try std.testing.expectEqual(@as(usize, 36), fields.count);
    try std.testing.expectEqualStrings("v0", fields.get("f0").?);
    try std.testing.expectEqualStrings("v35", fields.get_last("f35").?);

    try std.testing.expectError(
        error.TooManyQueryParameters,
        form.parse("application/x-www-form-urlencoded", body),
    );
    try std.testing.expectError(
        error.UnsupportedMediaType,
        form.parse_of(48, "application/json", body),
    );
}

test "query: Request helpers expose query and form views" {
    var get_request = Request{
        .method = "GET",
        .target = "/search?q=zig&page=2",
        .path = "/search",
        .query = "q=zig&page=2",
    };
    const query_params = try get_request.query_params();
    try std.testing.expectEqualStrings("zig", query_params.get("q").?);
    try std.testing.expectEqualStrings("q=zig&page=2", get_request.query);

    var post_request = Request{
        .method = "POST",
        .body = "name=uWebZockets&tag=zig",
    };
    post_request.header_names[0] = "Content-Type";
    post_request.header_values[0] = "application/x-www-form-urlencoded; charset=UTF-8";
    post_request.header_count = 1;

    const fields = try post_request.form();
    try std.testing.expectEqualStrings("uWebZockets", fields.get("name").?);

    var missing = Request{ .method = "POST", .body = "name=x" };
    try std.testing.expectError(error.MissingContentType, missing.form());

    var wrong = Request{ .method = "POST", .body = "name=x" };
    wrong.header_names[0] = "Content-Type";
    wrong.header_values[0] = "application/json";
    wrong.header_count = 1;
    try std.testing.expectError(error.UnsupportedMediaType, wrong.form());
}

test "query: Request.query_params_of uses the requested capacity" {
    var query_buffer: [512]u8 = undefined;
    var query_offset: usize = 0;
    for (0..36) |index| {
        const written = try std.fmt.bufPrint(
            query_buffer[query_offset..],
            "k{d}=v{d}&",
            .{ index, index },
        );
        query_offset += written.len;
    }
    const query_bytes = query_buffer[0..query_offset];

    var target_buffer: [512]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "/items?{s}", .{query_bytes});

    const request = Request{
        .method = "GET",
        .target = target,
        .path = "/items",
        .query = query_bytes,
    };
    const params = try request.query_params_of(48);
    try std.testing.expectEqual(@as(usize, 36), params.count);
    try std.testing.expectEqualStrings("k0", params.at(0).?.key);
    try std.testing.expectEqualStrings("v35", params.get("k35").?);

    try std.testing.expectError(error.TooManyQueryParameters, request.query_params());
}

test "query: get_int parses page-style values and reports absence" {
    const params = try query.QueryParams.parse("page=42&limit=1000&signed=-7&bad=abc");

    try std.testing.expectEqual(@as(?u32, 42), try params.get_int(u32, "page"));
    try std.testing.expectEqual(@as(?i32, -7), try params.get_int(i32, "signed"));
    try std.testing.expectEqual(@as(?u64, null), try params.get_int(u64, "missing"));
    try std.testing.expectError(error.InvalidCharacter, params.get_int(u32, "bad"));
    try std.testing.expectError(error.Overflow, params.get_int(u8, "limit"));

    const expanded = try query.QueryParamsOf(64).parse("page=999");
    try std.testing.expectEqual(@as(?u16, 999), try expanded.get_int(u16, "page"));
}
