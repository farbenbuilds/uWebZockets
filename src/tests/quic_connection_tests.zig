const std = @import("std");
const c = @import("c");
const support = @import("test_support");
const runtime = support.webtransport_runtime;

const Connections = runtime.connection_table(2);

const Fixture = struct {
    slots: [2]runtime.Connection = undefined,
    indices: [2]usize = undefined,
    owner: u8 = 0,
    native_identity: [3]u8 = .{ 0, 0, 0 },

    fn native(fixture: *Fixture, index: usize) *c.lsquic_conn {
        // These opaque identities are never dereferenced or passed to C.
        return @ptrCast(&fixture.native_identity[index]);
    }
};

test "quic connection ownership keeps distinct connections and stream leases" {
    var fixture = Fixture{};
    var connections = try Connections.from_slices(&fixture.slots, &fixture.indices);
    defer connections.deinit();
    const first = connections.acquire(&fixture.owner, fixture.native(0)).?;
    const second = connections.acquire(&fixture.owner, fixture.native(1)).?;
    const first_handle = first.handle;
    const second_handle = second.handle;
    try std.testing.expect(first_handle.index != second_handle.index);
    try std.testing.expect(first_handle.generation != 0);
    try std.testing.expect(second_handle.generation != 0);
    try std.testing.expect(connections.acquire(&fixture.owner, fixture.native(2)) == null);

    var first_lease = runtime.StreamLease{};
    var second_lease = runtime.StreamLease{};
    try std.testing.expect(connections.retain(first_handle, &first_lease));
    try std.testing.expect(connections.retain(second_handle, &second_lease));
    try std.testing.expect(!connections.retain(second_handle, &first_lease));
    try std.testing.expectEqual(@as(usize, 1), first.stream_count);
    try std.testing.expectEqual(@as(usize, 1), second.stream_count);
    try std.testing.expect(connections.release(&first_lease));
    try std.testing.expect(connections.close(first_handle));
    try std.testing.expect(connections.close(second_handle));
    try std.testing.expect(connections.release(&second_lease));
    try std.testing.expectEqual(@as(usize, 0), connections.pool.count_active());
}

test "quic connection ownership retains closed slots until final stream release" {
    var fixture = Fixture{};
    var connections = try Connections.from_slices(&fixture.slots, &fixture.indices);
    defer connections.deinit();
    const first = connections.acquire(&fixture.owner, fixture.native(0)).?;
    const handle = first.handle;
    const second = connections.acquire(&fixture.owner, fixture.native(1)).?;
    const second_handle = second.handle;
    var leases = [_]runtime.StreamLease{ .{}, .{} };
    for (&leases) |*lease| try std.testing.expect(connections.retain(handle, lease));
    try std.testing.expect(connections.close(handle));
    try std.testing.expect(first.native == null);
    try std.testing.expect(!connections.close(handle));
    var rejected = runtime.StreamLease{};
    try std.testing.expect(!connections.retain(handle, &rejected));
    try std.testing.expect(!rejected.active);
    try std.testing.expect(connections.acquire(&fixture.owner, fixture.native(2)) == null);
    try std.testing.expect(connections.release(&leases[0]));
    try std.testing.expect(!connections.release(&leases[0]));
    try std.testing.expect(connections.acquire(&fixture.owner, fixture.native(2)) == null);
    try std.testing.expect(connections.release(&leases[1]));

    const reused = connections.acquire(&fixture.owner, fixture.native(2)).?;
    try std.testing.expectEqual(handle.index, reused.handle.index);
    try std.testing.expect(handle.generation != reused.handle.generation);
    try std.testing.expect(connections.find(handle) == null);
    try std.testing.expect(!connections.close(handle));
    try std.testing.expect(!connections.retain(handle, &rejected));
    try std.testing.expectEqual(@as(usize, 0), reused.stream_count);
    try std.testing.expect(connections.close(reused.handle));
    try std.testing.expect(connections.close(second_handle));
    try std.testing.expectEqual(@as(usize, 0), connections.pool.count_active());
}

test "quic connection ownership caches one completed peer snapshot per generation" {
    var fixture = Fixture{};
    var connections = try Connections.from_slices(&fixture.slots, &fixture.indices);
    defer connections.deinit();
    const connection = connections.acquire(&fixture.owner, fixture.native(0)).?;
    const handle = connection.handle;
    const peer = support.webtransport_backend.Peer{
        .initial_max_data = (@as(u64, 1) << 40) + 17,
        .initial_max_streams_bidi = 2,
        .initial_max_streams_uni = 3,
        .wt_enabled = true,
    };
    try std.testing.expect(connection.peer == null);
    try std.testing.expect(connections.cache_peer(handle, peer));
    try std.testing.expect(!connections.cache_peer(handle, .{}));
    try std.testing.expectEqualDeep(peer, connection.peer.?);
    var lease = runtime.StreamLease{};
    try std.testing.expect(connections.retain(handle, &lease));
    try std.testing.expect(connections.close(handle));
    try std.testing.expect(!connections.cache_peer(handle, .{}));
    try std.testing.expectEqualDeep(peer, connection.peer.?);
    try std.testing.expect(connections.release(&lease));
    const reused = connections.acquire(&fixture.owner, fixture.native(1)).?;
    try std.testing.expect(reused.peer == null);
    try std.testing.expect(!connections.cache_peer(handle, peer));
    try std.testing.expect(connections.close(reused.handle));
}

test "quic connection ownership rejects foreign and zero generation handles" {
    var fixture = Fixture{};
    var connections = try Connections.from_slices(&fixture.slots, &fixture.indices);
    defer connections.deinit();
    var lease = runtime.StreamLease{};
    const handles = [_]runtime.ConnectionHandle{
        .{ .index = 2, .generation = 1 },
        .{ .index = 0, .generation = 0 },
        .{ .index = std.math.maxInt(usize), .generation = 7 },
    };
    for (handles) |handle| {
        try std.testing.expect(connections.find(handle) == null);
        try std.testing.expect(!connections.retain(handle, &lease));
        try std.testing.expect(!connections.close(handle));
        try std.testing.expect(!connections.cache_peer(handle, .{}));
    }
    try std.testing.expect(!connections.release(&lease));
    try std.testing.expectEqual(@as(usize, 0), connections.pool.count_active());
}

test "quic connection ownership allocates linear engine connection and context slabs" {
    const Engine = support.quic_engine.quic_engine(2, 64, 0, support.quic_stream.default_capacities);
    var engine = try Engine.init();
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 2), engine.connections.pool.free_count);
    try std.testing.expectEqual(@as(usize, 2), engine.stream_contexts.len);
    try std.testing.expectEqual(@as(usize, 2), engine.stream_pool.free_count);
}

test "quic connection ownership classifies HTTP and children without cross-role changes" {
    var http = runtime.StreamState{};
    try std.testing.expectEqual(runtime.StreamRole.unresolved, http.role);
    try std.testing.expect(http.mark_http());
    const child = support.webtransport_backend.StreamInfo{
        .session_id = @as(u64, 1) << 40,
        .association = .child,
        .direction = .uni,
        .initiator = .peer,
        .receive_prefix_size = 9,
    };
    try std.testing.expect(!http.classify(child));
    try std.testing.expectEqual(runtime.StreamRole.http, http.role);
    try std.testing.expect(http.info == null);

    var state = runtime.StreamState{};
    try std.testing.expect(state.classify(child));
    try std.testing.expectEqual(runtime.StreamRole.child, state.role);
    try std.testing.expectEqualDeep(child, state.info.?);
    try std.testing.expect(!state.mark_http());
    try std.testing.expect(!state.classify(.{ .session_id = 0 }));
    try std.testing.expect(state.classify(child));
    var different = child;
    different.session_id = 0;
    try std.testing.expect(!state.classify(different));
    try std.testing.expectEqualDeep(child, state.info.?);

    const connect = support.webtransport_backend.StreamInfo{ .session_id = 0 };
    try std.testing.expect(http.classify(connect));
    try std.testing.expectEqual(runtime.StreamRole.connect, http.role);
    try std.testing.expect(!http.mark_http());
    try std.testing.expect(!http.classify(child));
}

test "quic connection ownership refuses exhausted generations without consuming slots" {
    var fixture = Fixture{};
    var connections = try Connections.from_slices(&fixture.slots, &fixture.indices);
    defer connections.deinit();
    const first = connections.acquire(&fixture.owner, fixture.native(0)).?;
    const stale = first.handle;
    try std.testing.expect(connections.close(stale));
    connections.generation = std.math.maxInt(u64) - 1;
    const last = connections.acquire(&fixture.owner, fixture.native(1)).?;
    try std.testing.expectEqual(std.math.maxInt(u64), last.handle.generation);
    try std.testing.expect(connections.close(last.handle));
    try std.testing.expect(connections.acquire(&fixture.owner, fixture.native(2)) == null);
    try std.testing.expect(connections.find(stale) == null);
    try std.testing.expectEqual(@as(usize, 2), connections.pool.free_count);
}
