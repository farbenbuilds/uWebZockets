const std = @import("std");
const c = @import("c");
const backend = @import("test_support").webtransport_backend;

test "WebTransport native backend preserves peer output on unavailable handles" {
    var peer: backend.Peer = .{
        .initial_max_data = 93,
        .initial_max_streams_bidi = 71,
        .initial_max_streams_uni = 37,
        .wt_enabled = true,
        .extended_connect = true,
        .http_datagram = true,
        .quic_datagram = true,
        .reliable_reset = true,
    };
    const original = peer;
    const expected: backend.QueryResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, backend.read_peer(null, &peer));
    try std.testing.expectEqualDeep(original, peer);
}

test "WebTransport native backend preserves stream output on unavailable handles" {
    var info: backend.StreamInfo = .{
        .session_id = @as(u64, 1) << 40,
        .send_prefix_size = 11,
        .receive_prefix_size = 13,
        .association = .child,
        .direction = .uni,
        .initiator = .local,
    };
    const original = info;
    const expected: backend.QueryResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, backend.read_stream(null, &info));
    try std.testing.expectEqualDeep(original, info);
}

test "WebTransport native backend preserves receive output on unavailable handles" {
    var state: backend.ReceiveSnapshot = .{
        .final_size = 19,
        .reliable_size = 7,
        .reset_error = 37,
        .reset_visible = true,
        .stop_error = 41,
        .fin_received = true,
        .read_cancelled = true,
    };
    const original = state;
    const expected: backend.QueryResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, backend.read_receive(null, &state));
    try std.testing.expectEqualDeep(original, state);
}

test "WebTransport native backend rejects operations without a connection" {
    const expected: backend.CreateResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, backend.accept_connect(null));
    try std.testing.expectEqual(expected, backend.create_child(null, 0, .bidi));
    try std.testing.expectEqual(expected, backend.create_child(null, 0, .uni));
}

test "WebTransport native backend rejects receive cancellation without a stream" {
    const expected: backend.StopResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, backend.stop_receiving(null, 0x3994bd84));
}

test "WebTransport native backend configures bounded opt-in atomically" {
    var settings = std.mem.zeroes(c.lsquic_engine_settings);
    const original = settings;
    const invalid = backend.configure(&settings, .{ .initial_max_data = @as(u64, 1) << 62 });
    const expected: backend.ConfigureResult = if (backend.available) .invalid else .unsupported;
    try std.testing.expectEqual(expected, invalid);
    try std.testing.expectEqualDeep(original, settings);

    const result = backend.configure(&settings, .{});
    if (comptime backend.available) {
        try std.testing.expectEqual(backend.ConfigureResult.ok, result);
        try std.testing.expectEqual(@as(c_int, 1), settings.es_datagrams);
        try std.testing.expectEqual(@as(c_int, 1), settings.es_reset_stream_at);
        try std.testing.expectEqual(@as(c_uint, 1), settings.es_webtransport.enabled);
        try std.testing.expectEqual(@as(u64, 0), settings.es_webtransport.initial_max_data);
        try std.testing.expectEqual(@as(u64, 0), settings.es_webtransport.initial_max_streams_bidi);
        try std.testing.expectEqual(@as(u64, 0), settings.es_webtransport.initial_max_streams_uni);
    } else {
        try std.testing.expectEqual(backend.ConfigureResult.unsupported, result);
        try std.testing.expectEqualDeep(original, settings);
    }
}

fn settings_callback(_: ?*c.lsquic_conn) callconv(.c) void {}

fn child_callback(_: ?*c.lsquic_stream, _: ?*c.lsquic_stream_ctx) callconv(.c) void {}

fn closed_callback(_: ?*c.lsquic_conn) callconv(.c) void {}

test "WebTransport native backend installs callbacks only with the full contract" {
    var callbacks = std.mem.zeroes(c.lsquic_stream_if);
    callbacks.on_conn_closed = closed_callback;
    const original = callbacks;
    const installed = backend.install_callbacks(&callbacks, .{
        .settings = settings_callback,
        .child = child_callback,
    });
    try std.testing.expectEqual(backend.available, installed);
    try std.testing.expect(callbacks.on_conn_closed.? == closed_callback);
    if (comptime backend.available) {
        try std.testing.expect(callbacks.on_h3_settings.? == settings_callback);
        try std.testing.expect(callbacks.on_webtransport_stream.? == child_callback);
    } else {
        try std.testing.expectEqualDeep(original, callbacks);
    }
}

test "WebTransport native backend distinguishes the endpoint prerequisite sets" {
    var peer: backend.Peer = .{
        .wt_enabled = true,
        .http_datagram = true,
        .quic_datagram = true,
        .reliable_reset = true,
    };
    try std.testing.expect(backend.peer_requirements_met(peer, .server));
    try std.testing.expect(!backend.peer_requirements_met(peer, .client));
    peer.extended_connect = true;
    try std.testing.expect(backend.peer_requirements_met(peer, .client));
    peer.reliable_reset = false;
    try std.testing.expect(!backend.peer_requirements_met(peer, .server));
    try std.testing.expect(!backend.peer_requirements_met(peer, .client));
}
