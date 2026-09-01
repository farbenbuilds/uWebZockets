const std = @import("std");
const http2 = @import("test_support").http2;

fn append_frame(
    storage: []u8,
    frame_type: http2.FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
) ![]const u8 {
    if (storage.len < 9 + payload.len) return error.BufferTooSmall;
    try (http2.FrameHeader{
        .payload_length = @intCast(payload.len),
        .frame_type = @intFromEnum(frame_type),
        .flags = flags,
        .stream_id = stream_id,
    }).encode(storage[0..9]);
    @memcpy(storage[9 .. 9 + payload.len], payload);
    return storage[0 .. 9 + payload.len];
}

test "http2: frame header ignores the reserved stream bit" {
    const expected = http2.FrameHeader{
        .payload_length = 16_384,
        .frame_type = @intFromEnum(http2.FrameType.headers),
        .flags = 0x5,
        .stream_id = 7,
    };
    var bytes: [9]u8 = undefined;
    try expected.encode(&bytes);
    const actual = try http2.FrameHeader.parse(&bytes);
    try std.testing.expectEqualDeep(expected, actual);

    bytes[5] |= 0x80;
    const reserved = try http2.FrameHeader.parse(&bytes);
    try std.testing.expectEqual(expected.stream_id, reserved.stream_id);
}

test "http2: fragmented preface and bounded stream slab" {
    const Connection = http2.connection(2);
    var connection = Connection{};
    const split = 11;
    try std.testing.expectEqual(
        split,
        try connection.consume_preface(http2.client_preface[0..split]),
    );
    try std.testing.expect(!connection.preface_complete());
    try std.testing.expectEqual(
        http2.client_preface.len - split,
        try connection.consume_preface(http2.client_preface[split..]),
    );
    try std.testing.expect(connection.preface_complete());

    var storage: [64]u8 = undefined;
    const first = try append_frame(&storage, .headers, 0x5, 1, "header-one");
    const first_event = try connection.receive_frame(first);
    try std.testing.expectEqual(@as(u16, 0), first_event.headers.stream_index);
    try std.testing.expectEqualStrings("header-one", first_event.headers.block);
    try std.testing.expectEqual(http2.StreamState.half_closed_remote, connection.streams.states[0]);

    const second = try append_frame(&storage, .headers, 0x4, 3, "header-two");
    _ = try connection.receive_frame(second);
    const third = try append_frame(&storage, .headers, 0x4, 5, "header-three");
    const refused = try connection.receive_frame(third);
    try std.testing.expectEqual(@as(u32, 5), refused.refused_headers.stream_id);
    try std.testing.expectEqualStrings("header-three", refused.refused_headers.block);
    try std.testing.expect(refused.refused_headers.end_headers);
    try std.testing.expectEqual(@as(u32, 5), connection.highest_peer_stream_id);
}

test "http2: settings update every active send window" {
    const Connection = http2.connection(4);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 1, "h");
    _ = try connection.receive_frame(headers);

    const settings_payload = [_]u8{
        0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x04, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
    };
    const settings = try append_frame(&storage, .settings, 0, 0, &settings_payload);
    const event = try connection.receive_frame(settings);
    try std.testing.expect(event == .settings);
    try std.testing.expectEqual(@as(u32, 2), connection.peer_settings.max_concurrent_streams);
    try std.testing.expectEqual(@as(i64, 65_536), connection.streams.send_windows[0]);
    try std.testing.expect(connection.peer_settings.enable_connect_protocol);
}

test "http2: continuation sequencing and padded data are strict" {
    const Connection = http2.connection(2);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0, 1, "first");
    _ = try connection.receive_frame(headers);

    const ping = try append_frame(&storage, .ping, 0, 0, "12345678");
    try std.testing.expectError(error.ExpectedContinuation, connection.receive_frame(ping));

    const continuation = try append_frame(&storage, .continuation, 0x4, 1, "last");
    const continuation_event = try connection.receive_frame(continuation);
    try std.testing.expect(continuation_event.continuation.end_headers);

    const padded_payload = [_]u8{ 2, 'a', 'b', 'c', 0, 0 };
    const data = try append_frame(&storage, .data, 0x9, 1, &padded_payload);
    const data_event = try connection.receive_frame(data);
    try std.testing.expectEqualStrings("abc", data_event.data.bytes);
    try std.testing.expect(data_event.data.end_stream);
    try std.testing.expectEqual(
        http2.default_window_size - padded_payload.len,
        connection.connection_receive_window,
    );
}

test "http2: invalid settings and window overflow fail closed" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const invalid_push = [_]u8{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x02 };
    const settings = try append_frame(&storage, .settings, 0, 0, &invalid_push);
    try std.testing.expectError(error.InvalidSetting, connection.receive_frame(settings));

    connection.connection_send_window = 0x7fff_ffff;
    const increment = [_]u8{ 0, 0, 0, 1 };
    const update = try append_frame(&storage, .window_update, 0, 0, &increment);
    try std.testing.expectError(
        error.ConnectionFlowControlError,
        connection.receive_frame(update),
    );
}

test "http2: undefined frame flags are ignored" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const settings = try append_frame(&storage, .settings, 0x80, 0, "");
    try std.testing.expect((try connection.receive_frame(settings)) == .settings);
    const ping = try append_frame(&storage, .ping, 0x80, 0, "12345678");
    const ping_event = try connection.receive_frame(ping);
    try std.testing.expect(std.meta.activeTag(ping_event) == .ping);
    const headers = try append_frame(&storage, .headers, 0x84, 1, "h");
    const headers_event = try connection.receive_frame(headers);
    try std.testing.expect(std.meta.activeTag(headers_event) == .headers);
    const data = try append_frame(&storage, .data, 0x81, 1, "body");
    const data_event = try connection.receive_frame(data);
    try std.testing.expect(std.meta.activeTag(data_event) == .data);
}

test "http2: stream flow-control failures remain stream scoped" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 1, "h");
    const event = try connection.receive_frame(headers);
    const index = event.headers.stream_index;
    connection.streams.receive_windows[index] = 0;
    const data = try append_frame(&storage, .data, 0, 1, "x");
    try std.testing.expectError(
        error.StreamFlowControlError,
        connection.receive_frame(data),
    );

    connection.streams.send_windows[index] = 0x7fff_ffff;
    const increment = [_]u8{ 0, 0, 0, 1 };
    const update = try append_frame(&storage, .window_update, 0, 1, &increment);
    try std.testing.expectError(
        error.StreamFlowControlError,
        connection.receive_frame(update),
    );
}

test "http2: peer stream limit does not constrain inbound client streams" {
    const Connection = http2.connection(2);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const peer_limit = [_]u8{ 0x00, 0x03, 0x00, 0x00, 0x00, 0x01 };
    const settings = try append_frame(&storage, .settings, 0, 0, &peer_limit);
    _ = try connection.receive_frame(settings);
    const first = try append_frame(&storage, .headers, 0x4, 1, "a");
    _ = try connection.receive_frame(first);
    const second = try append_frame(&storage, .headers, 0x4, 3, "b");
    _ = try connection.receive_frame(second);
    try std.testing.expectEqual(@as(u16, 2), connection.streams.active_count);
}

test "http2: half closed local streams still accept peer data" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 1, "h");
    const event = try connection.receive_frame(headers);
    const index = event.headers.stream_index;
    try std.testing.expect(!try connection.close_local(index));

    const trailers = try append_frame(&storage, .headers, 0x5, 1, "t");
    const trailer_event = try connection.receive_frame(trailers);
    try std.testing.expect(trailer_event.headers.end_stream);
    try std.testing.expect(connection.streams.find(1) == null);

    const next_headers = try append_frame(&storage, .headers, 0x4, 3, "h");
    const next_event = try connection.receive_frame(next_headers);
    try std.testing.expect(!try connection.close_local(next_event.headers.stream_index));
    const data = try append_frame(&storage, .data, 0x1, 3, "body");
    const data_event = try connection.receive_frame(data);
    try std.testing.expect(data_event.data.end_stream);
    try std.testing.expect(connection.streams.find(3) == null);
}

test "http2: credit restoration is atomic and large reservations fail" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [32]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 1, "h");
    const event = try connection.receive_frame(headers);
    const index = event.headers.stream_index;
    connection.connection_receive_window = 0x7fff_ffff;
    connection.streams.receive_windows[index] = 1;
    try std.testing.expectError(
        error.FlowControlError,
        connection.restore_receive_credit(index, 1),
    );
    try std.testing.expectEqual(@as(i64, 0x7fff_ffff), connection.connection_receive_window);
    try std.testing.expectEqual(@as(i64, 1), connection.streams.receive_windows[index]);

    const connection_send = connection.connection_send_window;
    const stream_send = connection.streams.send_windows[index];
    try std.testing.expectError(
        error.SendWindowExhausted,
        connection.reserve_send_credit(index, std.math.maxInt(usize)),
    );
    try std.testing.expectEqual(connection_send, connection.connection_send_window);
    try std.testing.expectEqual(stream_send, connection.streams.send_windows[index]);
}

test "http2: peer reset retains its stream ID after slab release" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [32]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 1, "h");
    _ = try connection.receive_frame(headers);
    const reset_code = [_]u8{ 0, 0, 0, 8 };
    const reset = try append_frame(&storage, .rst_stream, 0, 1, &reset_code);
    const event = try connection.receive_frame(reset);
    try std.testing.expectEqual(@as(u32, 1), event.stream_reset.stream_id);
    try std.testing.expect(connection.streams.find(1) == null);
}

test "http2: idle closed and locally reset streams remain distinct" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x4, 5, "h");
    const event = try connection.receive_frame(headers);

    const one_byte = [_]u8{0};
    const future_data = try append_frame(&storage, .data, 0, 7, &one_byte);
    try std.testing.expectError(error.IdleStream, connection.receive_frame(future_data));
    const future_reset = try append_frame(&storage, .rst_stream, 0, 7, &.{ 0, 0, 0, 8 });
    try std.testing.expectError(error.IdleStream, connection.receive_frame(future_reset));
    const future_window = try append_frame(&storage, .window_update, 0, 7, &.{ 0, 0, 0, 1 });
    try std.testing.expectError(error.IdleStream, connection.receive_frame(future_window));

    const even_data = try append_frame(&storage, .data, 0, 2, &one_byte);
    try std.testing.expectError(error.InvalidStreamId, connection.receive_frame(even_data));
    const even_reset = try append_frame(&storage, .rst_stream, 0, 2, &.{ 0, 0, 0, 8 });
    try std.testing.expectError(error.InvalidStreamId, connection.receive_frame(even_reset));
    const even_window = try append_frame(&storage, .window_update, 0, 2, &.{ 0, 0, 0, 1 });
    try std.testing.expectError(error.InvalidStreamId, connection.receive_frame(even_window));

    const closed_data = try append_frame(&storage, .data, 0, 1, &one_byte);
    try std.testing.expectError(error.StreamClosed, connection.receive_frame(closed_data));
    const closed_data_window = connection.connection_receive_window;
    const closed_reset = try append_frame(&storage, .rst_stream, 0, 1, &.{ 0, 0, 0, 8 });
    try std.testing.expect((try connection.receive_frame(closed_reset)) == .ignored);
    const closed_window = try append_frame(&storage, .window_update, 0, 1, &.{ 0, 0, 0, 1 });
    try std.testing.expect((try connection.receive_frame(closed_window)) == .ignored);

    try std.testing.expect(connection.reset_local(event.headers.stream_index));
    const reset_data = try append_frame(&storage, .data, 0, 5, "abc");
    const discarded = try connection.receive_frame(reset_data);
    try std.testing.expectEqual(@as(u32, 3), discarded.discarded_data.flow_length);
    try std.testing.expectEqual(
        closed_data_window - 3,
        connection.connection_receive_window,
    );
    try std.testing.expectEqual(
        @as(u32, 3),
        try connection.restore_connection_receive_credit(3),
    );
    try std.testing.expectEqual(
        closed_data_window,
        connection.connection_receive_window,
    );
    const reset_reset = try append_frame(&storage, .rst_stream, 0, 5, &.{ 0, 0, 0, 8 });
    try std.testing.expect((try connection.receive_frame(reset_reset)) == .ignored);
    const reset_window = try append_frame(&storage, .window_update, 0, 5, &.{ 0, 0, 0, 1 });
    try std.testing.expect((try connection.receive_frame(reset_window)) == .ignored);
}

test "http2: closed DATA consumes connection flow-control credit" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const headers = try append_frame(&storage, .headers, 0x5, 3, "h");
    _ = try connection.receive_frame(headers);

    const padded = [_]u8{ 2, 'a', 0, 0 };
    const skipped_data = try append_frame(&storage, .data, 0x8, 1, &padded);
    try std.testing.expectError(error.StreamClosed, connection.receive_frame(skipped_data));
    try std.testing.expectEqual(
        http2.default_window_size - padded.len,
        connection.connection_receive_window,
    );

    const half_closed_data = try append_frame(&storage, .data, 0, 3, "xyz");
    try std.testing.expectError(
        error.StreamClosed,
        connection.receive_frame(half_closed_data),
    );
    try std.testing.expectEqual(
        http2.default_window_size - padded.len - 3,
        connection.connection_receive_window,
    );
}

test "http2: initial send-window settings update is atomic" {
    const Connection = http2.connection(2);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [64]u8 = undefined;
    const first = try append_frame(&storage, .headers, 0x4, 1, "a");
    _ = try connection.receive_frame(first);
    const second = try append_frame(&storage, .headers, 0x4, 3, "b");
    _ = try connection.receive_frame(second);
    connection.streams.send_windows[1] = 0x7fff_ffff;
    const original_first = connection.streams.send_windows[0];
    const update = [_]u8{ 0x00, 0x04, 0x00, 0x01, 0x00, 0x00 };
    const settings = try append_frame(&storage, .settings, 0, 0, &update);
    try std.testing.expectError(error.FlowControlError, connection.receive_frame(settings));
    try std.testing.expectEqual(original_first, connection.streams.send_windows[0]);
    try std.testing.expectEqual(@as(i64, 0x7fff_ffff), connection.streams.send_windows[1]);
}

test "http2: GOAWAY ignores the reserved last-stream bit" {
    const Connection = http2.connection(1);
    var connection = Connection{};
    _ = try connection.consume_preface(http2.client_preface);

    var storage: [32]u8 = undefined;
    const payload = [_]u8{ 0x80, 0x00, 0x00, 0x07, 0, 0, 0, 0 };
    const goaway = try append_frame(&storage, .goaway, 0, 0, &payload);
    const event = try connection.receive_frame(goaway);
    try std.testing.expectEqual(@as(u32, 7), event.goaway.last_stream_id);
}
