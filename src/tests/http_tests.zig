const std = @import("std");
const support = @import("test_support");
const parser = support.http_parser;
const Request = support.http_request.Request;
const response = support.http_response;

const AsyncCapture = struct {
    completion_count: usize = 0,
    wake_count: usize = 0,

    fn complete(
        context: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !void {
        const self: *AsyncCapture = @ptrCast(@alignCast(context));
        self.completion_count += 1;
    }

    fn wake(context: *anyopaque) void {
        const self: *AsyncCapture = @ptrCast(@alignCast(context));
        self.wake_count += 1;
    }
};

// tests the zero-allocation http parser state machine
test "http: parse basic get request" {
    var p = parser.HttpParser{};
    var req = Request{};

    var request_data = "GET /index.html HTTP/1.1\r\nHost: localhost\r\nUser-Agent: curl\r\n\r\n".*;

    const consumed = parser.consume(&p, &req, &request_data);

    try std.testing.expectEqual(request_data.len, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/index.html", req.path);
    try std.testing.expectEqual(@as(usize, 2), req.header_count);

    try std.testing.expectEqualStrings("localhost", req.get_header("Host").?);
    try std.testing.expectEqualStrings("curl", req.get_header("User-Agent").?);
}

test "http: preserves parser state across split input" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET /split HTTP/1.1\r\nHost: example.test\r\n\r\n".*;
    const split = 19;

    _ = parser.consume(&p, &req, data[0..split]);
    try std.testing.expect(p.state != .done);

    const consumed = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(data.len, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/split", req.path);
}

test "http: separates a query from the routed path" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET /search?q=zig%20websocket HTTP/1.1\r\nHost: example.test\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/search?q=zig%20websocket", req.target);
    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("q=zig%20websocket", req.query);
}

test "http: RFC 10008 QUERY requires a valid Content-Type" {
    var parser_state = parser.HttpParser{};
    var request = Request{};
    var valid = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Type: application/sql; charset=utf-8\r\nContent-Length: 8\r\n\r\nselect 1".*;
    _ = parser.consume(&parser_state, &request, &valid);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(request.valid_query_content_type());

    parser.reset(&parser_state);
    request = .{};
    var missing = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Length: 8\r\n\r\nselect 1".*;
    _ = parser.consume(&parser_state, &request, &missing);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(!request.valid_query_content_type());

    parser.reset(&parser_state);
    request = .{};
    var malformed = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Type: application sql\r\nContent-Length: 8\r\n\r\nselect 1".*;
    _ = parser.consume(&parser_state, &request, &malformed);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(!request.valid_query_content_type());

    parser.reset(&parser_state);
    request = .{};
    var empty_parameter = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Type: text/plain; charset=\r\nContent-Length: 0\r\n\r\n".*;
    _ = parser.consume(&parser_state, &request, &empty_parameter);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(!request.valid_query_content_type());

    parser.reset(&parser_state);
    request = .{};
    var quoted_parameter = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Type: text/plain; profile=\"a\\\"b\"\r\nContent-Length: 0\r\n\r\n".*;
    _ = parser.consume(&parser_state, &request, &quoted_parameter);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(request.valid_query_content_type());

    parser.reset(&parser_state);
    request = .{};
    var trailing_garbage = "QUERY /search HTTP/1.1\r\nHost: example.test\r\nContent-Type: text/plain; profile=\"a\"garbage\r\nContent-Length: 0\r\n\r\n".*;
    _ = parser.consume(&parser_state, &request, &trailing_garbage);
    try std.testing.expectEqual(parser.ParserState.done, parser_state.state);
    try std.testing.expect(!request.valid_query_content_type());
}

test "http: reports first request boundary for pipelining" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = ("GET /one HTTP/1.1\r\nHost: example.test\r\n\r\n" ++
        "GET /two HTTP/1.1\r\nHost: example.test\r\n\r\n").*;
    const first_len = std.mem.indexOf(u8, &data, "GET /two").?;

    const consumed = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(first_len, consumed);
    try std.testing.expectEqualStrings("/one", req.path);

    std.mem.copyForwards(u8, data[0 .. data.len - consumed], data[consumed..]);
    parser.reset(&p);
    req = .{};
    _ = parser.consume(&p, &req, data[0 .. data.len - consumed]);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/two", req.path);
}

test "http: rejects unsupported transfer codings" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: bounds declared request bodies" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 16385\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_too_large, p.state);
}

test "http: accepts only decimal content lengths" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: +1\r\n\r\nx".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: rejects empty header names" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET / HTTP/1.1\r\nHost: example.test\r\n: invalid\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: accepts only hexadecimal chunk sizes" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: decodes bounded chunked bodies" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("test", req.body);
}

test "http: response metadata rejects framing ambiguity" {
    try std.testing.expectEqual(@as(?u16, 200), response.status_code("200 OK"));
    try std.testing.expect(response.status_code("099 Invalid") == null);
    try std.testing.expect(response.status_code("600 Invalid") == null);
    try std.testing.expect(response.status_code("200 OK\r\nX-Test: injected") == null);
    try std.testing.expect(response.status_forbids_body(204));
    try std.testing.expect(response.status_forbids_body(205));
    try std.testing.expect(response.status_forbids_body(304));
    try std.testing.expect(response.valid_headers("Content-Type: text/plain\r\nConnection: close\r\n"));
    try std.testing.expect(!response.valid_headers("Content-Length: 1\r\n"));
    try std.testing.expect(!response.valid_headers("Transfer-Encoding: chunked\r\n"));
    try std.testing.expect(!response.valid_headers("X-Test: valid\r\n\r\nInjected: value\r\n"));
    try std.testing.expect(response.headers_have_token(
        "Connection: keep-alive, close\r\n",
        "Connection",
        "close",
    ));
}

test "http: async response validates metadata before completion" {
    var capture = AsyncCapture{};
    var state = response.AsyncResponseState{};
    const token = state.arm(.{
        .context = &capture,
        .complete_fn = AsyncCapture.complete,
        .wake_fn = AsyncCapture.wake,
    });

    try std.testing.expectError(error.InvalidStatus, token.complete("", ""));
    try std.testing.expectError(error.InvalidStatus, token.complete("20", ""));
    try std.testing.expectError(error.InvalidStatus, token.complete("600 Invalid", ""));
    try std.testing.expectError(
        error.InvalidStatus,
        token.complete("200 OK\r\nX-Injected: yes", ""),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        token.complete_with_headers("200 OK", "X-Test: missing terminator", ""),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        token.complete_with_headers("200 OK", "Content-Length: 0\r\n", ""),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        token.complete_with_headers("200 OK", "Transfer-Encoding: chunked\r\n", ""),
    );
    try std.testing.expectError(
        error.BodyNotAllowed,
        token.complete("204 No Content", "not allowed"),
    );
    try std.testing.expectError(
        error.BodyNotAllowed,
        token.complete("205 Reset Content", "not allowed"),
    );

    try std.testing.expect(token.is_pending());
    try std.testing.expectEqual(@as(usize, 0), capture.completion_count);
    try std.testing.expectEqual(@as(usize, 0), capture.wake_count);

    try token.complete_with_headers("200 OK", "X-Test: valid\r\n", "done");
    try std.testing.expectEqual(@as(usize, 1), capture.completion_count);
    try std.testing.expectEqual(@as(usize, 1), capture.wake_count);
    try std.testing.expectError(
        error.AsyncResponseAlreadyCompleted,
        token.complete("200 OK", "again"),
    );
}

test "http: 205 responses reject payloads before transport dispatch" {
    const RejectSink = struct {
        fn http2_end(_: *anyopaque, _: u32, _: []const u8, _: []const u8, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http2_begin(_: *anyopaque, _: u32, _: []const u8, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http2_write(_: *anyopaque, _: u32, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http2_finish(_: *anyopaque, _: u32) !void {
            return error.UnexpectedDispatch;
        }

        fn http3_end(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http3_begin(_: *anyopaque, _: []const u8, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http3_write(_: *anyopaque, _: []const u8) !void {
            return error.UnexpectedDispatch;
        }

        fn http3_finish(_: *anyopaque) !void {
            return error.UnexpectedDispatch;
        }
    };

    var context: u8 = 0;
    var tcp_connection = support.tcp.TcpConnection{ .socket = undefined };
    var http1 = response.Response{ .target = .{ .tcp = &tcp_connection } };
    try std.testing.expectError(
        error.BodyNotAllowed,
        http1.end("205 Reset Content", "not allowed"),
    );

    var http2 = response.Response{ .target = .{ .http2 = .{
        .context = &context,
        .router = &context,
        .stream_id = 1,
        .end_fn = RejectSink.http2_end,
        .begin_fn = RejectSink.http2_begin,
        .write_fn = RejectSink.http2_write,
        .finish_fn = RejectSink.http2_finish,
    } } };
    try std.testing.expectError(
        error.BodyNotAllowed,
        http2.end("205 Reset Content", "not allowed"),
    );

    var http3 = response.Response{ .target = .{ .http3 = .{
        .context = &context,
        .end_fn = RejectSink.http3_end,
        .begin_fn = RejectSink.http3_begin,
        .write_fn = RejectSink.http3_write,
        .finish_fn = RejectSink.http3_finish,
    } } };
    try std.testing.expectError(
        error.BodyNotAllowed,
        http3.end("205 Reset Content", "not allowed"),
    );
}
