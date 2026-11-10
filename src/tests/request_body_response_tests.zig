const std = @import("std");
const support = @import("test_support");
const response = support.http_response;
const file_tests = @import("file_stream_tests.zig");

/// Records transport effects so phase refusals cannot hide an attempted start.
const Effects = struct {
    starts: usize = 0,
    writes: usize = 0,
    finishes: usize = 0,
    ends: usize = 0,
    arms: usize = 0,
    files: usize = 0,
    producers: usize = 0,
    status: []const u8 = "",
    headers: [128]u8 = undefined,
    headers_len: usize = 0,
    body: [32]u8 = undefined,
    body_len: usize = 0,

    fn target(effects: *Effects) response.Http3Target {
        return .{
            .context = effects,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
            .begin_stream_fn = arm,
            .stream_file_fn = file,
        };
    }

    fn end(context: *anyopaque, status: []const u8, headers: []const u8, body: []const u8) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.ends += 1;
        if (headers.len > effects.headers.len or body.len > effects.body.len) return error.BufferOverflow;
        effects.status = status;
        @memcpy(effects.headers[0..headers.len], headers);
        effects.headers_len = headers.len;
        @memcpy(effects.body[0..body.len], body);
        effects.body_len = body.len;
    }

    fn begin(context: *anyopaque, _: []const u8, _: []const u8) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.starts += 1;
    }

    fn write(context: *anyopaque, _: []const u8) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.writes += 1;
    }

    fn finish(context: *anyopaque) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.finishes += 1;
    }

    fn arm(context: *anyopaque, _: []const u8, _: []const u8, _: *anyopaque, _: response.StreamProducer) !bool {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.arms += 1;
        return false;
    }

    fn file(context: *anyopaque, _: []const u8, _: []const u8, _: response.FileSource) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.files += 1;
    }

    fn produce(context: *anyopaque, _: *response.Response) !response.StreamStatus {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.producers += 1;
        return .pending;
    }
};

fn expect_unstarted(output: *const response.Response, effects: *const Effects) !void {
    try std.testing.expectEqual(response.ResponseState.idle, output.state);
    try std.testing.expect(!output.close_after_end);
    try std.testing.expectEqual(response.StreamFraming.chunked, output.stream_framing);
    try std.testing.expectEqualStrings("X-Pending: retained\r\n", output.pending_headers[0..output.pending_header_length]);
    try std.testing.expectEqual(@as(usize, 0), effects.starts + effects.writes + effects.finishes + effects.ends + effects.arms + effects.files + effects.producers);
}

test "request body response: incomplete uploads refuse stream starts without effects" {
    var effects = Effects{};
    var output = response.Response{
        .target = .{ .http3 = effects.target() },
        .request_body_complete = false,
    };
    try output.append_header("X-Pending", "retained");
    try std.testing.expectError(error.BodyNotComplete, output.begin_chunked("200 OK", "Connection: close\r\n"));
    try expect_unstarted(&output, &effects);
    try std.testing.expectError(error.BodyNotComplete, output.begin_stream("200 OK", "Connection: close\r\n", &effects, Effects.produce));
    try expect_unstarted(&output, &effects);
    try std.testing.expectError(error.BodyNotComplete, output.begin_json());
    try expect_unstarted(&output, &effects);
    try std.testing.expectError(error.BodyNotComplete, output.sse());
    try expect_unstarted(&output, &effects);
    var writable = output.writable_stream();
    try std.testing.expectEqual(support.streams.StreamState.readable, writable.state);
    try std.testing.expectError(error.BodyNotComplete, writable.write("body"));
    try std.testing.expectEqual(support.streams.StreamState.errored, writable.state);
    try expect_unstarted(&output, &effects);
    try std.testing.expectError(error.BodyNotComplete, output.begin_chunked("invalid", "invalid"));
    try expect_unstarted(&output, &effects);
}

test "request body response: file refusal retains caller ownership and queued state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "asset", .{ .read = true });
    var caller_owns = true;
    defer if (caller_owns) file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "original", 0);
    var ring = [_]u8{0xa5} ** 256;
    var scratch = [_]u8{0x5a} ** 8;
    var fixture = file_tests.TestConnection{};
    try fixture.init(&ring);
    defer fixture.deinit();
    var output = response.Response{
        .target = .{ .tcp = &fixture.connection },
        .request_body_complete = false,
    };
    try output.append_header("X-Pending", "retained");
    const kernel = output.send_file("200 OK", "Connection: close\r\n", file, 0, 8);
    if (kernel) |_| {
        caller_owns = false;
        return error.ExpectedFileRefusal;
    } else |err| try std.testing.expectEqual(error.BodyNotAllowed, err);
    const framed = output.stream_file("200 OK", "Connection: close\r\n", .{
        .io = std.testing.io,
        .file = file,
        .buffer = &scratch,
        .offset = 0,
        .length = 8,
    });
    if (framed) |_| {
        caller_owns = false;
        return error.ExpectedFileRefusal;
    } else |err| try std.testing.expectEqual(error.BodyNotComplete, err);
    try expect_unstarted(&output, &.{});
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.write_len);
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.write_head);
    try std.testing.expect(fixture.connection.file_body == null);
    try std.testing.expect(fixture.connection.buffered_file.file == null);
    try std.testing.expect(fixture.connection.stream_producer == null);
    try std.testing.expect(!fixture.connection.dispatch_suspended);
    try std.testing.expect(!fixture.connection.close_when_drained);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 256), &ring);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 8), &scratch);
    var actual: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try file.readPositionalAll(std.testing.io, &actual, 0));
    try std.testing.expectEqualStrings("original", &actual);
}

test "request body response: target file arming is refused before capability or source checks" {
    var effects = Effects{};
    var output = response.Response{
        .target = .{ .http3 = effects.target() },
        .request_body_complete = false,
    };
    try output.append_header("X-Pending", "retained");
    try std.testing.expectError(error.BodyNotAllowed, output.send_file("invalid", "invalid", undefined, 0, 1));
    try std.testing.expectError(error.BodyNotComplete, output.stream_file("invalid", "invalid", undefined));
    try expect_unstarted(&output, &effects);
}

test "request body response: already-started validation retains precedence" {
    var effects = Effects{};
    var output = response.Response{
        .target = .{ .http3 = effects.target() },
        .state = .streaming,
        .request_body_complete = false,
    };
    try std.testing.expectError(error.ResponseAlreadyStarted, output.begin_chunked("200 OK", ""));
    try std.testing.expectError(error.ResponseAlreadyStarted, output.begin_stream("200 OK", "", &effects, Effects.produce));
    try std.testing.expectError(error.ResponseAlreadyStarted, output.stream_file("200 OK", "", undefined));
    try std.testing.expectError(error.ResponseAlreadyStarted, output.send_file("200 OK", "", undefined, 0, 1));
    try std.testing.expectError(error.ResponseAlreadyStarted, output.begin_json());
    try std.testing.expectError(error.ResponseAlreadyStarted, output.sse());
    try std.testing.expectEqual(@as(usize, 0), effects.starts + effects.arms + effects.files + effects.producers);
}

test "request body response: incomplete uploads allow metadata and fixed final responses" {
    var effects = Effects{};
    var output = response.Response{
        .target = .{ .http3 = effects.target() },
        .request_body_complete = false,
    };
    try output.append_header("X-Early", "yes");
    try output.end_with_headers("413 Payload Too Large", "Content-Type: text/plain\r\n", "refused");
    try std.testing.expectEqual(response.ResponseState.ended, output.state);
    try std.testing.expectEqual(@as(usize, 1), effects.ends);
    try std.testing.expectEqualStrings("413 Payload Too Large", effects.status);
    try std.testing.expectEqualStrings("X-Early: yes\r\nContent-Type: text/plain\r\n", effects.headers[0..effects.headers_len]);
    try std.testing.expectEqualStrings("refused", effects.body[0..effects.body_len]);
}

test "request body response: buffered construction remains complete by default" {
    var effects = Effects{};
    var output = response.Response{ .target = .{ .http3 = effects.target() } };
    try std.testing.expect(output.request_body_complete);
    try output.begin_chunked("200 OK", "");
    try output.write_chunk("buffered");
    try output.end_chunks();
    try std.testing.expect(output.is_complete());
    try std.testing.expectEqual(@as(usize, 1), effects.starts);
    try std.testing.expectEqual(@as(usize, 1), effects.writes);
    try std.testing.expectEqual(@as(usize, 1), effects.finishes);
}
