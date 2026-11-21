const std = @import("std");
const support = @import("test_support");
const endpoints = support.webtransport_endpoints;
const streams = support.webtransport_stream;
const wt = support.webtransport;
const testing = std.testing;

const Observation = struct {
    datagrams: usize = 0,
    opens: usize = 0,
    last_stream_id: u64 = 0,
    last_session_generation: u64 = 0,
    last_payload: [16]u8 = @splat(0),
    last_length: usize = 0,
};

fn on_datagram(context: *anyopaque, session_id: u64, payload: []const u8) void {
    const observed: *Observation = @ptrCast(@alignCast(context));
    observed.datagrams += 1;
    observed.last_stream_id = session_id;
    std.debug.assert(payload.len <= observed.last_payload.len);
    @memcpy(observed.last_payload[0..payload.len], payload);
    observed.last_length = payload.len;
}

fn on_open(context: *anyopaque, info: streams.Info) bool {
    const observed: *Observation = @ptrCast(@alignCast(context));
    observed.opens += 1;
    observed.last_stream_id = info.stream_id;
    observed.last_session_generation = info.session.generation;
    return true;
}

const callbacks = streams.Callbacks{ .open = on_open };

fn stream_info() streams.Info {
    return .{
        .handle = .{ .owner = 9, .index = 7, .generation = std.math.maxInt(u64) },
        .session = .{ .owner = 9, .connection_index = 3, .connection_generation = std.math.maxInt(u64) - 1, .index = 0, .generation = std.math.maxInt(u64) - 2 },
        .session_id = ((@as(u64, 1) << 62) - 1) & ~@as(u64, 3),
        .stream_id = (@as(u64, 1) << 62) - 1,
        .direction = .uni,
        .initiator = .peer,
    };
}

test "WebTransport endpoints merge datagram then streams with independent borrowed contexts" {
    var registry: endpoints.Registry = .{};
    var datagrams: Observation = .{};
    var children: Observation = .{};
    var first_path = [_]u8{ '/', 'w', 't' };
    const first = try registry.register_datagram(&first_path, on_datagram, &datagrams);
    const second = try registry.register_streams("/wt", callbacks, &children);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u8, 1), registry.route_count);
    const endpoint = registry.get(first).?;
    try testing.expectEqual(@as([*]const u8, first_path[0..].ptr), endpoint.path.ptr);
    try testing.expectEqual(@as(*anyopaque, &datagrams), endpoint.datagram.?.context);
    try testing.expectEqual(@as(*anyopaque, &children), endpoint.streams.?.context);
    try testing.expectEqual(@as(usize, 0), children.opens);
    endpoint.datagram.?.handler(endpoint.datagram.?.context, 4, "borrowed");
    try testing.expect(endpoint.streams.?.callbacks.open(endpoint.streams.?.context, stream_info()));
    try testing.expectEqual(@as(usize, 1), datagrams.datagrams);
    try testing.expectEqualStrings("borrowed", datagrams.last_payload[0..datagrams.last_length]);
    try testing.expectEqual(stream_info().stream_id, children.last_stream_id);
    try testing.expectEqual(stream_info().session.generation, children.last_session_generation);
    try testing.expectEqual(@as(usize, 0), datagrams.opens);
    try testing.expectEqual(@as(usize, 0), children.datagrams);
}

test "WebTransport endpoints merge streams then datagram without changing identity" {
    var registry: endpoints.Registry = .{};
    var first_context: Observation = .{};
    var second_context: Observation = .{};
    const first = try registry.register_streams("/wt", callbacks, &first_context);
    const before = registry.get(first).?.streams.?;
    const second = try registry.register_datagram("/wt", on_datagram, &second_context);
    try testing.expectEqual(first, second);
    try testing.expectEqualDeep(before, registry.get(first).?.streams.?);
    try testing.expectEqual(@as(u8, 1), registry.route_count);
}

test "WebTransport endpoint duplicate capabilities preserve the whole registry" {
    var registry: endpoints.Registry = .{};
    var first: Observation = .{};
    var replacement: Observation = .{};
    _ = try registry.register_datagram("/wt", on_datagram, &first);
    _ = try registry.register_streams("/wt", callbacks, &first);
    const before = registry;
    try testing.expectError(error.RouteAlreadyRegistered, registry.register_datagram("/wt", on_datagram, &replacement));
    try testing.expectEqualDeep(before, registry);
    try testing.expectError(error.RouteAlreadyRegistered, registry.register_streams("/wt", callbacks, &replacement));
    try testing.expectEqualDeep(before, registry);
}

test "WebTransport endpoint capacity allows streams on existing datagram paths" {
    var registry: endpoints.Registry = .{};
    var context: Observation = .{};
    var paths: [endpoints.max_routes][16]u8 = undefined;
    for (&paths, 0..) |*storage, index| {
        const path = try std.fmt.bufPrint(storage, "/wt/{d}", .{index});
        const id = try registry.register_datagram(path, on_datagram, &context);
        try testing.expectEqual(index, @as(usize, @intFromEnum(id)));
    }
    const before = registry;
    try testing.expectEqual(@as(u8, 16), registry.route_count);
    try testing.expectError(error.RouteCapacityReached, registry.register_streams("/new", callbacks, &context));
    try testing.expectEqualDeep(before, registry);
    try testing.expectError(error.RouteAlreadyRegistered, registry.register_datagram("/wt/15", on_datagram, &context));
    try testing.expectEqualDeep(before, registry);
    const id = try registry.register_streams("/wt/15", callbacks, &context);
    try testing.expectEqual(@as(u8, 15), @intFromEnum(id));
    try testing.expectEqual(@as(u8, 16), registry.route_count);
    try testing.expect(registry.get(id).?.datagram != null);
    try testing.expect(registry.get(id).?.streams != null);
}

test "WebTransport endpoint capacity allows datagrams on existing stream paths" {
    var registry: endpoints.Registry = .{};
    var context: Observation = .{};
    var paths: [endpoints.max_routes][16]u8 = undefined;
    for (&paths, 0..) |*storage, index| {
        const path = try std.fmt.bufPrint(storage, "/stream/{d}", .{index});
        _ = try registry.register_streams(path, callbacks, &context);
    }
    const before = registry;
    try testing.expectError(error.RouteCapacityReached, registry.register_datagram("/new", on_datagram, &context));
    try testing.expectEqualDeep(before, registry);
    const id = try registry.register_datagram("/stream/0", on_datagram, &context);
    try testing.expectEqual(@as(u8, 0), @intFromEnum(id));
    try testing.expectEqual(@as(u8, 16), registry.route_count);
    try testing.expect(registry.get(id).?.datagram != null);
    try testing.expect(registry.get(id).?.streams != null);
}

test "WebTransport endpoint path validation matches datagram registration" {
    var registry: endpoints.Registry = .{};
    var context: Observation = .{};
    const before = registry;
    for ([_][]const u8{ "", "wt", "https://localhost/wt" }) |path| {
        try testing.expectError(error.InvalidPath, registry.register_datagram(path, on_datagram, &context));
        try testing.expectEqualDeep(before, registry);
        try testing.expectError(error.InvalidPath, registry.register_streams(path, callbacks, &context));
        try testing.expectEqualDeep(before, registry);
    }
    _ = try registry.register_streams("/", callbacks, &context);
    _ = try registry.register_datagram("/wt?draft=16", on_datagram, &context);
    try testing.expectEqual(@as(u8, 2), registry.route_count);
}

test "WebTransport endpoint lookup rejects missing paths and out of range IDs" {
    var registry: endpoints.Registry = .{};
    var context: Observation = .{};
    try testing.expect(registry.get(@enumFromInt(0)) == null);
    const id = try registry.register_streams("/wt", callbacks, &context);
    try testing.expectEqual(id, registry.find_id("/wt").?);
    try testing.expectEqualStrings("/wt", registry.find("/wt").?.path);
    try testing.expect(registry.find("/missing") == null);
    try testing.expect(registry.find_id("/missing") == null);
    try testing.expect(registry.get(@enumFromInt(1)) == null);
    try testing.expect(registry.get(@enumFromInt(255)) == null);
}

test "WebTransport public stream callbacks leave notifications independently optional" {
    try testing.expect(callbacks.data == null and callbacks.eof == null and callbacks.reset == null);
    try testing.expect(callbacks.stop == null and callbacks.closed == null);
    try testing.expect(callbacks.session_open == null and callbacks.session_closed == null);
    const info = stream_info();
    const event = streams.SessionClosedEvent{ .handle = info.session, .session_id = info.session_id, .reason = .completed };
    try testing.expect(event.code == null);
    try testing.expectEqual(info.session.connection_generation, event.handle.connection_generation);
    try testing.expectEqual(info.session.generation, event.handle.generation);
}

test "WebTransport public errors map every application boundary without narrowing" {
    for ([_]u32{ 0, 1, 29, 30, 31, std.math.maxInt(u32) }) |application| {
        const native = try streams.to_native_code(.{ .application = application });
        try testing.expectEqual(wt.application_error_to_http3(application), native);
        try testing.expectEqualDeep(streams.ErrorCode{ .application = application }, try streams.from_native_code(native));
    }
}

test "WebTransport public errors preserve HTTP3 values and reserved application holes" {
    for ([_]u64{ 0, 0x10e, wt.wt_session_gone, wt.wt_application_error_first + 30, wt.max_quic_varint }) |native| {
        try testing.expectEqual(native, try streams.to_native_code(.{ .http3 = native }));
        try testing.expectEqualDeep(streams.ErrorCode{ .http3 = native }, try streams.from_native_code(native));
    }
    try testing.expectError(error.InvalidErrorCode, streams.to_native_code(.{ .http3 = wt.max_quic_varint + 1 }));
    try testing.expectError(error.InvalidErrorCode, streams.from_native_code(wt.max_quic_varint + 1));
}
