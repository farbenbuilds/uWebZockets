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
