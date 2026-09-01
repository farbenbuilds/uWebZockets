const std = @import("std");
const c = @import("c");
const support = @import("test_support");
const api = support.quic_api;
const engine = support.quic_engine;
const packet = support.quic_packet;
const stream = support.quic_stream;
const validation = support.quic_validation;
const HeaderSet = stream.HeaderSet;

test "quic: packet inspector parses v1 and v2 long headers" {
    const v1_initial =
        "\xc0\x00\x00\x00\x01" ++
        "\x08destinat" ++
        "\x00" ++
        "\x00" ++
        "\x01\xaa";
    const initial = try packet.inspect_packet(v1_initial);
    try std.testing.expectEqual(packet.PacketKind.initial, initial.kind);
    try std.testing.expectEqualStrings("destinat", initial.destination_id);
    try std.testing.expectEqual(@as(usize, v1_initial.len), initial.packet_length);
    try std.testing.expectEqualSlices(u8, "\xaa", initial.payload);

    const v2_initial =
        "\xd0\x6b\x33\x43\xcf" ++
        "\x00\x00" ++
        "\x00" ++
        "\x01\xbb";
    const initial_v2 = try packet.inspect_packet(v2_initial);
    try std.testing.expectEqual(packet.PacketKind.initial, initial_v2.kind);
    try std.testing.expectEqual(@as(u32, 0x6b3343cf), initial_v2.version);
}

test "quic: packet inspector bounds connection ids, varints, and versions" {
    const negotiation =
        "\x80\x00\x00\x00\x00" ++
        "\x00\x00" ++
        "\x00\x00\x00\x01";
    const header = try packet.inspect_packet(negotiation);
    try std.testing.expectEqual(packet.PacketKind.version_negotiation, header.kind);

    try std.testing.expectError(
        error.InvalidConnectionIdLength,
        packet.inspect_packet("\xc0\x00\x00\x00\x01\x15x"),
    );
    try std.testing.expectError(
        error.TruncatedPacket,
        packet.inspect_packet("\xc0\x00\x00\x00\x01\x00\x00\x40"),
    );
    try std.testing.expectError(
        error.InvalidVersionNegotiation,
        packet.inspect_packet("\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
    );
}

test "quic: sockaddr conversion preserves address family and port" {
    const input = try std.Io.net.IpAddress.parse("127.0.0.1", 8443);
    const address = api.Sockaddr.init(input);
    const sockaddr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&address.storage));

    try std.testing.expectEqual(std.posix.AF.INET, sockaddr.family);
    try std.testing.expectEqual(@as(u16, 8443), std.mem.bigToNative(u16, sockaddr.port));
    try std.testing.expectEqual(@as(c.socklen_t, @sizeOf(std.posix.sockaddr.in)), address.length);
}

test "quic: each live stream reserves independent request and trailer header slots" {
    const TestEngine = engine.quic_engine(2, 64);
    var quic_engine = try TestEngine.init();
    defer quic_engine.deinit();

    try std.testing.expectEqual(@as(usize, 4), quic_engine.header_pool.free_count);
    try std.testing.expectEqual(
        @as(usize, 4 * stream.header_capacity),
        quic_engine.header_storage.len,
    );
}

test "quic: bounded header set validates pseudo headers and framing" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage);

    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/hello?name=zig"));
    try std.testing.expect(add_test_header(&header_set, "content-length", "4"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("/hello", header_set.request.path);
    try std.testing.expectEqualStrings("name=zig", header_set.request.query);
    try std.testing.expectEqual(@as(?usize, 4), header_set.content_length);
    try std.testing.expectEqualStrings("localhost", header_set.request.get_header("host").?);
}

test "quic: HTTP/3 QUERY exposes invalid media type before dispatch" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage);

    try std.testing.expect(add_test_header(&header_set, ":method", "QUERY"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/query"));
    try std.testing.expect(add_test_header(
        &header_set,
        "content-type",
        "text/plain; charset=",
    ));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expect(!header_set.request.valid_query_content_type());
}

test "quic: header set rejects forbidden connection metadata" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage);

    try std.testing.expect(!add_test_header(&header_set, "connection", "close"));
    try std.testing.expect(!validation.valid_target("/path#fragment"));
    try std.testing.expect(validation.parse_decimal("184467440737095516160") == null);

    header_set.reset(&owner, Owner.release, &storage);
    try std.testing.expect(add_test_header(&header_set, ":method", "GET"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "*"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage);
    try std.testing.expect(add_test_header(&header_set, ":method", "OPTIONS"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&header_set, ":path", "*"));
    try std.testing.expect(header_set.process_header(null));
}

test "quic: HTTP/3 regular CONNECT requires authority and omits scheme and path" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset(&owner, Owner.release, &storage);

    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(header_set.process_header(null));
    try std.testing.expectEqualStrings("localhost:443", header_set.request.target);
    try std.testing.expectEqualStrings("", header_set.request.path);
    try std.testing.expectEqualStrings("localhost:443", header_set.request.get_header("host").?);

    header_set.reset(&owner, Owner.release, &storage);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(add_test_header(&header_set, ":scheme", "https"));
    try std.testing.expect(add_test_header(&header_set, ":authority", "localhost:443"));
    try std.testing.expect(add_test_header(&header_set, ":path", "/tunnel"));
    try std.testing.expect(!header_set.process_header(null));

    header_set.reset(&owner, Owner.release, &storage);
    try std.testing.expect(add_test_header(&header_set, ":method", "CONNECT"));
    try std.testing.expect(!add_test_header(&header_set, ":protocol", "websocket"));
}

test "quic: HTTP/3 trailers reject pseudo and framing fields" {
    var storage: [stream.header_capacity]u8 = undefined;
    var header_set = HeaderSet{};
    const Owner = struct {
        fn release(_: *anyopaque, _: *HeaderSet) void {}
    };
    var owner: u8 = 0;
    header_set.reset_trailer(&owner, Owner.release, &storage);

    try std.testing.expect(add_test_header(&header_set, "x-checksum", "complete"));
    try std.testing.expect(header_set.process_header(null));

    header_set.reset_trailer(&owner, Owner.release, &storage);
    try std.testing.expect(!add_test_header(&header_set, ":path", "/late"));

    header_set.reset_trailer(&owner, Owner.release, &storage);
    try std.testing.expect(!add_test_header(&header_set, "content-length", "0"));

    header_set.reset_trailer(&owner, Owner.release, &storage);
    try std.testing.expect(!add_test_header(&header_set, "host", "example.com"));
}

test "quic: HTTP/3 trailer sets are released after one phase transition" {
    const Release = struct {
        var count: usize = 0;

        fn header(_: *anyopaque, _: *HeaderSet) void {
            count += 1;
        }
    };
    var owner: u8 = 0;
    var request_storage: [stream.header_capacity]u8 = undefined;
    var request_headers = HeaderSet{};
    request_headers.reset(&owner, Release.header, &request_storage);
    try std.testing.expect(add_test_header(&request_headers, ":method", "POST"));
    try std.testing.expect(add_test_header(&request_headers, ":scheme", "https"));
    try std.testing.expect(add_test_header(&request_headers, ":authority", "localhost"));
    try std.testing.expect(add_test_header(&request_headers, ":path", "/upload"));
    try std.testing.expect(request_headers.process_header(null));

    var quic_stream = stream.QuicStream{ .stream = undefined };
    quic_stream.attach_headers(&request_headers);

    var trailer_storage: [stream.header_capacity]u8 = undefined;
    var trailers = HeaderSet{};
    trailers.reset_trailer(&owner, Release.header, &trailer_storage);
    try std.testing.expect(add_test_header(&trailers, "x-checksum", "complete"));
    try std.testing.expect(trailers.process_header(null));

    Release.count = 0;
    quic_stream.attach_headers(&trailers);
    try std.testing.expectEqual(@as(usize, 1), Release.count);
    try std.testing.expect(quic_stream.header_set == &request_headers);
    try std.testing.expect(trailers.release_fn == null);

    request_headers.release();
    try std.testing.expectEqual(@as(usize, 2), Release.count);
}

test "quic: pure header validation rejects malformed metadata" {
    try std.testing.expect(validation.valid_method("PATCH"));
    try std.testing.expect(!validation.valid_method("BAD METHOD"));
    try std.testing.expect(validation.valid_target("/path?value=1"));
    try std.testing.expect(!validation.valid_target("/path#fragment"));
    try std.testing.expect(!validation.valid_target("/bad path"));
    try std.testing.expect(!validation.valid_target("/bad%2"));
    try std.testing.expect(validation.valid_target("*"));
    try std.testing.expect(validation.valid_authority("example.com:443"));
    try std.testing.expect(validation.valid_authority("[::1]:443"));
    try std.testing.expect(!validation.valid_authority("user@example.com"));
    try std.testing.expect(!validation.valid_authority("example.com/path"));
    try std.testing.expect(validation.valid_http3_name("content-type"));
    try std.testing.expect(!validation.valid_http3_name("Content-Type"));
    try std.testing.expect(!validation.valid_header_value("value\r\ninjected"));
    try std.testing.expect(validation.connection_specific_header("Connection"));
    try std.testing.expectEqual(@as(?usize, 4096), validation.parse_decimal("4096"));
    try std.testing.expect(validation.parse_decimal("184467440737095516160") == null);
}

fn add_test_header(header_set: *HeaderSet, name: []const u8, value: []const u8) bool {
    const start = header_set.write_offset;
    if (name.len + value.len > header_set.storage.len - start) return false;
    @memcpy(header_set.storage[start .. start + name.len], name);
    @memcpy(header_set.storage[start + name.len .. start + name.len + value.len], value);

    var header = std.mem.zeroes(c.struct_uz_lsxpack_header);
    header.buf = @ptrCast(header_set.storage.ptr);
    header.name_offset = @intCast(start);
    header.name_len = @intCast(name.len);
    header.val_offset = @intCast(start + name.len);
    header.val_len = @intCast(value.len);
    header_set.decoded = header;
    return header_set.process_header(@ptrCast(&header_set.decoded));
}
