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

test "http: append_header rejects field splitting" {
    const Sink = struct {
        fn http3_end(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
            return error.UnexpectedDispatch;
        }

        fn http3_begin(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
            return error.UnexpectedDispatch;
        }

        fn http3_write(_: *anyopaque, _: []const u8) anyerror!void {
            return error.UnexpectedDispatch;
        }

        fn http3_finish(_: *anyopaque) anyerror!void {
            return error.UnexpectedDispatch;
        }
    };
    var res = response.Response{ .target = .{ .http3 = .{
        .context = undefined,
        .end_fn = Sink.http3_end,
        .begin_fn = Sink.http3_begin,
        .write_fn = Sink.http3_write,
        .finish_fn = Sink.http3_finish,
    } } };

    try std.testing.expectError(
        error.InvalidHeaders,
        res.append_header("X-Trace", "value\r\nX-Injected: yes"),
    );
    try std.testing.expectEqual(@as(usize, 0), res.pending_header_length);
    try std.testing.expect(!res.is_started());

    try res.append_header("X-Trace", "safe-value");
    try std.testing.expect(res.pending_header_length != 0);
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

test "http: send_file declines framed transports without taking ownership" {
    const Sink = struct {
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "asset.bin", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);

    var context: u8 = 0;
    var http2 = response.Response{ .target = .{ .http2 = .{
        .context = &context,
        .router = &context,
        .stream_id = 1,
        .end_fn = Sink.http2_end,
        .begin_fn = Sink.http2_begin,
        .write_fn = Sink.http2_write,
        .finish_fn = Sink.http2_finish,
    } } };
    try std.testing.expectError(
        error.ZeroCopyUnavailable,
        http2.send_file("200 OK", "", file, 0, 32),
    );
    try std.testing.expect(!http2.is_started());

    var http3 = response.Response{ .target = .{ .http3 = .{
        .context = &context,
        .end_fn = Sink.http3_end,
        .begin_fn = Sink.http3_begin,
        .write_fn = Sink.http3_write,
        .finish_fn = Sink.http3_finish,
    } } };
    try std.testing.expectError(
        error.ZeroCopyUnavailable,
        http3.send_file("200 OK", "", file, 0, 32),
    );
    try std.testing.expect(!http3.is_started());
}

/// HTTP/1.1 connection whose write ring accepts bytes without a live socket.
fn test_connection(ring: []u8) support.tcp.TcpConnection {
    return .{
        .socket = undefined,
        .write_queue = ring,
        .is_writing = true,
    };
}

fn fill_test_headers(buffer: []u8) ![]const u8 {
    var length: usize = 0;
    for (0..64) |index| {
        const line = try std.fmt.bufPrint(
            buffer[length..],
            "X-Fill-{d:0>3}: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\r\n",
            .{index},
        );
        length += line.len;
    }
    return buffer[0..length];
}

test "http: end_with_headers scatters fields beyond the old fixed buffer" {
    var ring: [16 * 1024]u8 = undefined;
    var conn = test_connection(&ring);
    var res = response.Response{ .target = .{ .tcp = &conn } };

    try res.append_header("X-Pending", "yes");
    var header_buffer: [5 * 1024]u8 = undefined;
    const headers = try fill_test_headers(&header_buffer);
    try res.end_with_headers("200 OK", headers, "payload");

    const written = ring[0..conn.write_len];
    const prefix = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nX-Pending: yes\r\n";
    try std.testing.expect(std.mem.startsWith(u8, written, prefix));
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\npayload"));
    try std.testing.expectEqual(prefix.len + headers.len + 2 + "payload".len, written.len);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Fill-063:") != null);
}

test "http: begin_chunked scatters headers and frames chunks" {
    var ring: [16 * 1024]u8 = undefined;
    var conn = test_connection(&ring);
    var res = response.Response{ .target = .{ .tcp = &conn } };

    var header_buffer: [5 * 1024]u8 = undefined;
    const headers = try fill_test_headers(&header_buffer);
    try res.begin_chunked("200 OK", headers);
    try res.write_chunk("hello");
    try res.end_chunks();

    const written = ring[0..conn.write_len];
    const framing = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n";
    try std.testing.expect(std.mem.startsWith(u8, written, framing));
    try std.testing.expect(std.mem.indexOf(u8, written, "5\r\nhello\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "0\r\n\r\n"));
}

test "http: body-forbidden statuses scatter headers without Content-Length" {
    var ring: [16 * 1024]u8 = undefined;
    var conn = test_connection(&ring);
    var res = response.Response{ .target = .{ .tcp = &conn } };

    var header_buffer: [5 * 1024]u8 = undefined;
    const headers = try fill_test_headers(&header_buffer);
    try res.end_with_headers("204 No Content", headers, "");

    const written = ring[0..conn.write_len];
    try std.testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 204 No Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "http: begin_stream resumes after write-ring backpressure" {
    const Producer = struct {
        remaining: usize = 64,
        chunk: [100]u8 = undefined,

        fn produce(
            context: *anyopaque,
            stream: *response.Response,
        ) anyerror!response.StreamStatus {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memset(&self.chunk, 'x');
            while (self.remaining != 0) {
                stream.write_chunk(&self.chunk) catch |err| switch (err) {
                    error.WouldBlock => return .pending,
                    else => return err,
                };
                self.remaining -= 1;
            }
            try stream.end_chunks();
            return .done;
        }
    };

    var ring: [4096]u8 = undefined;
    var conn = test_connection(&ring);
    conn.read_active = true;
    var res = response.Response{ .target = .{ .tcp = &conn } };

    var producer = Producer{};
    try res.begin_stream("200 OK", "", &producer, Producer.produce);
    try std.testing.expect(conn.stream_producer != null);
    try std.testing.expect(producer.remaining != 0);
    try std.testing.expect(!res.is_complete());

    var total: usize = conn.write_len;
    var iterations: usize = 0;
    while (conn.stream_producer != null and iterations < 64) : (iterations += 1) {
        conn.write_len = 0;
        conn.pump_stream_body();
        total += conn.write_len;
    }

    try std.testing.expectEqual(@as(usize, 0), producer.remaining);
    try std.testing.expect(conn.stream_producer == null);
    try std.testing.expect(total >= 64 * 100);
}

test "http: begin_stream completes synchronously when the body fits" {
    const Producer = struct {
        fn produce(
            _: *anyopaque,
            stream: *response.Response,
        ) anyerror!response.StreamStatus {
            try stream.write_chunk("small body");
            try stream.end_chunks();
            return .done;
        }
    };

    var ring: [4096]u8 = undefined;
    var conn = test_connection(&ring);
    var res = response.Response{ .target = .{ .tcp = &conn } };

    var marker: u8 = 0;
    try res.begin_stream("200 OK", "", &marker, Producer.produce);
    try std.testing.expect(res.is_complete());
    try std.testing.expect(conn.stream_producer == null);
    const written = ring[0..conn.write_len];
    try std.testing.expect(std.mem.indexOf(u8, written, "a\r\nsmall body\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "0\r\n\r\n"));
}

test "http: begin_stream fails closed on transports without producer support" {
    var context: u8 = 0;

    var http2 = response.Response{ .target = .{ .http2 = .{
        .context = &context,
        .router = &context,
        .stream_id = 1,
        .end_fn = undefined,
        .begin_fn = undefined,
        .write_fn = undefined,
        .finish_fn = undefined,
    } } };
    try std.testing.expectError(
        error.ProducerStreamingUnsupported,
        http2.begin_stream("200 OK", "", &context, undefined),
    );
    try std.testing.expect(!http2.is_started());

    var http3 = response.Response{ .target = .{ .http3 = .{
        .context = &context,
        .end_fn = undefined,
        .begin_fn = undefined,
        .write_fn = undefined,
        .finish_fn = undefined,
    } } };
    try std.testing.expectError(
        error.ProducerStreamingUnsupported,
        http3.begin_stream("200 OK", "", &context, undefined),
    );
    try std.testing.expect(!http3.is_started());
}

test "http: honors per-connection request line limits" {
    var wire: [16 * 1024]u8 = undefined;
    const prefix = "GET /";
    const suffix = " HTTP/1.1\r\nHost: example.test\r\n\r\n";
    const fill = 9000;
    @memcpy(wire[0..prefix.len], prefix);
    @memset(wire[prefix.len .. prefix.len + fill], 'a');
    @memcpy(wire[prefix.len + fill .. prefix.len + fill + suffix.len], suffix);
    const length = prefix.len + fill + suffix.len;

    var raised = parser.HttpParser{ .max_request_line_bytes = 12 * 1024 };
    var raised_request = Request{};
    const consumed = parser.consume(&raised, &raised_request, wire[0..length]);
    try std.testing.expectEqual(length, consumed);
    try std.testing.expectEqual(parser.ParserState.done, raised.state);
    try std.testing.expectEqual(@as(usize, 1 + fill), raised_request.path.len);

    var lowered = parser.HttpParser{ .max_request_line_bytes = 1024 };
    var lowered_request = Request{};
    _ = parser.consume(&lowered, &lowered_request, wire[0..length]);
    try std.testing.expectEqual(parser.ParserState.error_headers_too_large, lowered.state);
}

test "http: honors per-connection header block limits" {
    var wire: [12 * 1024]u8 = undefined;
    const head = "GET / HTTP/1.1\r\nHost: example.test\r\nX-Fill: ";
    const tail = "\r\n\r\n";
    const fill = 5000;
    @memcpy(wire[0..head.len], head);
    @memset(wire[head.len .. head.len + fill], 'v');
    @memcpy(wire[head.len + fill .. head.len + fill + tail.len], tail);
    const length = head.len + fill + tail.len;

    var raised = parser.HttpParser{ .max_header_bytes = 8 * 1024 };
    var raised_request = Request{};
    const consumed = parser.consume(&raised, &raised_request, wire[0..length]);
    try std.testing.expectEqual(length, consumed);
    try std.testing.expectEqual(parser.ParserState.done, raised.state);
    try std.testing.expectEqual(@as(usize, fill), raised_request.get_header("X-Fill").?.len);

    var lowered = parser.HttpParser{ .max_header_bytes = 2 * 1024 };
    var lowered_request = Request{};
    _ = parser.consume(&lowered, &lowered_request, wire[0..length]);
    try std.testing.expectEqual(parser.ParserState.error_headers_too_large, lowered.state);
}

test "http: stores headers beyond the inline arrays in extras" {
    var wire: [8 * 1024]u8 = undefined;
    const head = "GET /many HTTP/1.1\r\nHost: example.test\r\n";
    @memcpy(wire[0..head.len], head);
    var length = head.len;
    for (0..99) |index| {
        const line = try std.fmt.bufPrint(
            wire[length..],
            "X-Fill-{d:0>3}: value-{d}\r\n",
            .{ index, index },
        );
        length += line.len;
    }
    wire[length] = '\r';
    wire[length + 1] = '\n';
    length += 2;

    var names: [40][]const u8 = undefined;
    var values: [40][]const u8 = undefined;
    var p = parser.HttpParser{
        .extra_header_names = &names,
        .extra_header_values = &values,
    };
    var req = Request{};

    const consumed = parser.consume(&p, &req, wire[0..length]);
    try std.testing.expectEqual(length, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqual(@as(usize, support.http_request.max_headers), req.header_count);
    try std.testing.expectEqual(@as(usize, 36), req.extra_header_names.?.len);
    try std.testing.expectEqualStrings("example.test", req.get_header("Host").?);
    try std.testing.expectEqualStrings("value-0", req.get_header("X-Fill-000").?);
    try std.testing.expectEqualStrings("value-98", req.get_header("X-Fill-098").?);

    var iterator = req.header_entries();
    var total: usize = 0;
    while (iterator.next()) |_| total += 1;
    try std.testing.expectEqual(@as(usize, 100), total);

    var owned = try req.clone(std.testing.allocator);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 100), owned.header_names.len);
    try std.testing.expectEqualStrings("value-98", owned.request.get_header("X-Fill-098").?);
}

test "http: extra header overflow fails closed" {
    var wire: [8 * 1024]u8 = undefined;
    const head = "GET / HTTP/1.1\r\nHost: example.test\r\n";
    @memcpy(wire[0..head.len], head);
    var length = head.len;
    for (0..69) |index| {
        const line = try std.fmt.bufPrint(wire[length..], "X-Over-{d:0>3}: v\r\n", .{index});
        length += line.len;
    }
    wire[length] = '\r';
    wire[length + 1] = '\n';
    length += 2;

    var names: [4][]const u8 = undefined;
    var values: [4][]const u8 = undefined;
    var p = parser.HttpParser{
        .extra_header_names = &names,
        .extra_header_values = &values,
    };
    var req = Request{};

    _ = parser.consume(&p, &req, wire[0..length]);
    try std.testing.expectEqual(parser.ParserState.error_headers_too_large, p.state);
    try std.testing.expectEqual(@as(usize, 4), p.extra_header_count);
}

test "http: parser reset clears extras for the next request" {
    var wire: [8 * 1024]u8 = undefined;
    const head = "GET /first HTTP/1.1\r\nHost: example.test\r\n";
    @memcpy(wire[0..head.len], head);
    var length = head.len;
    for (0..69) |index| {
        const line = try std.fmt.bufPrint(wire[length..], "X-Old-{d:0>3}: v\r\n", .{index});
        length += line.len;
    }
    wire[length] = '\r';
    wire[length + 1] = '\n';
    length += 2;

    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    var p = parser.HttpParser{
        .extra_header_names = &names,
        .extra_header_values = &values,
    };
    var req = Request{};
    _ = parser.consume(&p, &req, wire[0..length]);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqual(@as(usize, 6), req.extra_header_names.?.len);
    try std.testing.expect(req.get_header("X-Old-068") != null);

    parser.reset(&p);
    req = .{};

    var next = "GET /second HTTP/1.1\r\nHost: example.test\r\n\r\n".*;
    _ = parser.consume(&p, &req, &next);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqual(@as(usize, 0), req.extra_header_names.?.len);
    try std.testing.expect(req.get_header("X-Old-068") == null);
}

test "http: configured extras stride parses a max-size header block" {
    const config = support.config.ServerConfig{
        .max_connections = 1,
        .max_header_size = 24 * 1024,
        .max_header_count = 256,
    };
    try config.validate();
    const capacity = try config.extra_header_capacity();
    const stride = try config.extra_header_stride();
    const storage = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(support.config.request_buffer_alignment),
        stride,
    );
    defer std.testing.allocator.free(storage);

    const slots = std.mem.bytesAsSlice([]const u8, storage);
    var p = parser.HttpParser{
        .max_header_bytes = config.max_header_size,
        .extra_header_names = slots[0..capacity],
        .extra_header_values = slots[capacity .. capacity * 2],
    };

    var wire: [24 * 1024]u8 = undefined;
    const head = "GET /big HTTP/1.1\r\nHost: example.test\r\n";
    @memcpy(wire[0..head.len], head);
    var length = head.len;
    for (0..127) |index| {
        const line = try std.fmt.bufPrint(
            wire[length..],
            "X-Large-{d:0>3}: " ++ ("v" ** 160) ++ "\r\n",
            .{index},
        );
        length += line.len;
    }
    wire[length] = '\r';
    wire[length + 1] = '\n';
    length += 2;
    try std.testing.expect(length - head.len <= config.max_header_size);

    var req = Request{};
    const consumed = parser.consume(&p, &req, wire[0..length]);
    try std.testing.expectEqual(length, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqual(@as(usize, 64), req.extra_header_names.?.len);
    try std.testing.expectEqual(@as(usize, 160), req.get_header("X-Large-126").?.len);
    try std.testing.expectEqual(@as(usize, 160), req.get_header("X-Large-063").?.len);
}

/// Records the route captures observed by a wide HTTP/2 handler.
const WideCaptureSink = struct {
    inline_count: usize = 0,
    extra_count: usize = 0,
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,

    fn handle(context: *anyopaque, request: *Request, res: *response.Response) void {
        const self: *WideCaptureSink = @ptrCast(@alignCast(context));
        self.inline_count = request.route_param_count;
        self.extra_count = request.extra_param_count;
        self.first = request.get_param("p0");
        self.last = request.get_param("p19");
        res.end("200 OK", "") catch {};
    }
};

test "http2: captures beyond 16 resolve from the connection extras" {
    const capacities = support.radix.Capacities{ .max_route_params = 20 };
    var bundle = support.radix.Bundle(capacities){};
    var router = try support.radix.Router.init(bundle.storage());
    const pattern = "/:p0/:p1/:p2/:p3/:p4/:p5/:p6/:p7/:p8/:p9/:p10/:p11/:p12/:p13/:p14/:p15/:p16/:p17/:p18/:p19";
    const path = "/a0/a1/a2/a3/a4/a5/a6/a7/a8/a9/a10/a11/a12/a13/a14/a15/a16/a17/a18/a19";
    var sink = WideCaptureSink{};
    try router.route_context(.get, pattern, &sink, WideCaptureSink.handle);

    var ring: [4096]u8 = undefined;
    var names: [4][]const u8 = undefined;
    var values: [4][]const u8 = undefined;
    var conn = test_connection(&ring);
    conn.router = &router;
    conn.route_param_names = &names;
    conn.route_param_values = &values;
    try conn.h2.reset();

    // HPACK block: static GET, static https, then a raw literal :path.
    var header_block: [96]u8 = undefined;
    header_block[0] = 0x82;
    header_block[1] = 0x86;
    header_block[2] = 0x04;
    header_block[3] = @intCast(path.len);
    @memcpy(header_block[4 .. 4 + path.len], path);
    const block_length = 4 + path.len;

    var input: [256]u8 = undefined;
    @memcpy(input[0..support.http2.client_preface.len], support.http2.client_preface);
    var input_length: usize = support.http2.client_preface.len;
    const settings = [_]u8{ 0, 0, 0, 4, 0, 0, 0, 0, 0 };
    @memcpy(input[input_length..][0..settings.len], &settings);
    input_length += settings.len;
    var frame_header: [9]u8 = .{ 0, 0, 0, 1, 0x5, 0, 0, 0, 1 };
    std.mem.writeInt(u24, frame_header[0..3], @intCast(block_length), .big);
    @memcpy(input[input_length..][0..frame_header.len], &frame_header);
    input_length += frame_header.len;
    @memcpy(input[input_length..][0..block_length], header_block[0..block_length]);
    input_length += block_length;

    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
    try std.testing.expectEqual(@as(usize, 16), sink.inline_count);
    try std.testing.expectEqual(@as(usize, 4), sink.extra_count);
    try std.testing.expectEqualStrings("a0", sink.first.?);
    try std.testing.expectEqualStrings("a19", sink.last.?);
}
