const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const xev = @import("xev");
const support = @import("test_support");

const Router = support.radix.Router;
const IpAddress = std.Io.net.IpAddress;
const StopFn = *const fn (*anyopaque) void;

const Captured = struct {
    bytes: [16]u8 = undefined,
    length: usize = 0,
    peer: IpAddress = undefined,
    local: IpAddress = undefined,
};

const CaptureEngine = struct {
    packets: [16]Captured = undefined,
    count: usize = 0,
    stop_after: usize = 0,
    stop_context: *anyopaque = undefined,
    stop_fn: StopFn = undefined,
    failed: bool = false,

    pub fn init() !CaptureEngine {
        return .{};
    }

    pub fn start(_: *CaptureEngine, _: *c.SSL_CTX, _: *const Router, _: std.posix.socket_t, _: IpAddress) !void {}

    pub fn process_datagram_at(engine: *CaptureEngine, packet: []const u8, peer: IpAddress, local: IpAddress) void {
        if (engine.count == engine.packets.len or packet.len > engine.packets[0].bytes.len) {
            engine.failed = true;
            engine.stop_fn(engine.stop_context);
            return;
        }
        const captured = &engine.packets[engine.count];
        captured.* = .{ .length = packet.len, .peer = peer, .local = local };
        @memcpy(captured.bytes[0..packet.len], packet);
        engine.count += 1;
        if (engine.count == engine.stop_after) engine.stop_fn(engine.stop_context);
    }

    pub fn process(_: *CaptureEngine) void {}
    pub fn next_timeout_ms(_: *const CaptureEngine) u64 {
        return 1000;
    }
    pub fn cooldown(_: *CaptureEngine) void {}
    pub fn deinit(_: *CaptureEngine) void {}
};

const Transport = support.udp.quic_transport(CaptureEngine);

const LegacyEngine = struct {
    capture: CaptureEngine = .{},
    bound: IpAddress = undefined,

    pub fn init() !LegacyEngine {
        return .{};
    }

    pub fn start(engine: *LegacyEngine, _: *c.SSL_CTX, _: *const Router, _: std.posix.socket_t, local: IpAddress) !void {
        engine.bound = local;
    }

    pub fn process_datagram(engine: *LegacyEngine, packet: []const u8, peer: IpAddress) void {
        engine.capture.process_datagram_at(packet, peer, engine.bound);
    }

    pub fn process(_: *LegacyEngine) void {}
    pub fn next_timeout_ms(_: *const LegacyEngine) u64 {
        return 1000;
    }
    pub fn cooldown(_: *LegacyEngine) void {}
    pub fn deinit(_: *LegacyEngine) void {}
};

const Fixture = struct {
    transport: Transport,
    loop: support.loop.Loop,
    watchdog: xev.Timer,
    watchdog_completion: xev.Completion = .{},
    watchdog_cancel: xev.Completion = .{},
    watchdog_active: bool = false,
    watchdog_cancel_active: bool = false,
    timed_out: bool = false,

    fn init(router: *const Router, address: []const u8) !Fixture {
        const requested = try select_backend();
        // A forced-backend process bypasses the production detector's first
        // available preference. UDP polling needs no file-operation thread pool.
        var loop = if (requested != null)
            support.loop.Loop{ .xev_loop = try xev.Loop.init(.{ .entries = 256 }) }
        else
            try support.loop.init();
        errdefer support.loop.deinit(&loop);
        if (requested) |backend| try std.testing.expectEqual(backend, xev.backend());
        const ssl: *c.SSL_CTX = @ptrFromInt(1);
        var transport = try Transport.init(ssl, router, address, 0);
        errdefer transport.deinit();
        try transport.require_gro();
        const watchdog = try xev.Timer.init();
        return .{ .transport = transport, .loop = loop, .watchdog = watchdog };
    }

    fn start(fixture: *Fixture, stop_after: usize) !void {
        fixture.transport.engine.stop_after = stop_after;
        fixture.transport.engine.stop_context = fixture;
        fixture.transport.engine.stop_fn = stop;
        try fixture.transport.start(fixture.loop.get_xev_loop());
        fixture.watchdog_active = true;
        fixture.watchdog.run(fixture.loop.get_xev_loop(), &fixture.watchdog_completion, 1000, Fixture, fixture, on_timeout);
    }

    fn stop(context: *anyopaque) void {
        const fixture: *Fixture = @ptrCast(@alignCast(context));
        fixture.transport.shutdown();
        if (!fixture.watchdog_active or fixture.watchdog_cancel_active) return;
        fixture.watchdog_cancel_active = true;
        fixture.watchdog.cancel(fixture.loop.get_xev_loop(), &fixture.watchdog_completion, &fixture.watchdog_cancel, Fixture, fixture, on_cancel);
    }

    fn on_timeout(context: ?*Fixture, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
        const fixture = context.?;
        fixture.watchdog_active = false;
        result catch |err| {
            if (err != error.Canceled) fixture.timed_out = true;
            return .disarm;
        };
        fixture.timed_out = true;
        fixture.transport.shutdown();
        return .disarm;
    }

    fn on_cancel(context: ?*Fixture, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        const fixture = context.?;
        result catch |err| {
            if (err != error.NotFound) fixture.timed_out = true;
        };
        fixture.watchdog_active = false;
        fixture.watchdog_cancel_active = false;
        return .disarm;
    }

    fn run(fixture: *Fixture) !void {
        try fixture.loop.xev_loop.run(.until_done);
        try std.testing.expect(!fixture.timed_out);
        try std.testing.expect(!fixture.transport.engine.failed);
        try std.testing.expect(fixture.transport.is_drained());
        try std.testing.expect(!fixture.transport.read_active);
        try std.testing.expect(!fixture.transport.read_cancel_active);
    }

    fn deinit(fixture: *Fixture) void {
        stop(fixture);
        fixture.loop.xev_loop.run(.until_done) catch @panic("UDP GRO fixture did not drain");
        std.debug.assert(!fixture.watchdog_active and !fixture.watchdog_cancel_active);
        fixture.watchdog.deinit();
        fixture.transport.deinit();
        support.loop.deinit(&fixture.loop);
    }
};

fn select_backend() !?xev.Backend {
    const requested = std.testing.environ.getAlloc(std.testing.allocator, "UWZ_GRO_BACKEND") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer std.testing.allocator.free(requested);
    if (comptime !xev.dynamic) return error.DynamicBackendRequired;
    if (std.mem.eql(u8, requested, "io_uring")) {
        if (!xev.prefer(.io_uring)) return error.RequestedBackendUnavailable;
        return .io_uring;
    }
    if (std.mem.eql(u8, requested, "epoll")) {
        if (!xev.prefer(.epoll)) return error.RequestedBackendUnavailable;
        return .epoll;
    }
    return error.InvalidRequestedBackend;
}

fn sender(family: c_int) !std.posix.socket_t {
    const fd = c.socket(family, c.SOCK_DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    return fd;
}

fn send(fd: std.posix.socket_t, destination: IpAddress, data: []const u8, segment_size: ?u16) !void {
    var address = support.quic_api.Sockaddr.init(destination);
    var iov = c.struct_iovec{ .iov_base = @constCast(data.ptr), .iov_len = data.len };
    const header_bytes = comptime std.mem.alignForward(usize, @sizeOf(c.struct_cmsghdr), @alignOf(usize));
    var control: [header_bytes + @sizeOf(u16)]u8 align(@alignOf(usize)) = undefined;
    var message = c.struct_msghdr{
        .msg_name = &address.storage,
        .msg_namelen = address.length,
        .msg_iov = &iov,
        .msg_iovlen = 1,
    };
    if (segment_size) |size| {
        const header: *c.struct_cmsghdr = @ptrCast(&control);
        header.* = .{ .cmsg_len = control.len, .cmsg_level = c.IPPROTO_UDP, .cmsg_type = 103 };
        std.mem.writeInt(u16, control[header_bytes..][0..2], size, builtin.cpu.arch.endian());
        message.msg_control = &control;
        message.msg_controllen = control.len;
    }
    const result = c.sendmsg(fd, &message, 0);
    try std.testing.expectEqual(@as(isize, @intCast(data.len)), result);
}

fn ipv4_destination(fixture: *const Fixture, last_octet: u8) IpAddress {
    return .{ .ip4 = .{ .bytes = .{ 127, 0, 0, last_octet }, .port = fixture.transport.local_address.ip4.port } };
}

test "udp GRO: IPv4 aggregates preserve segments and wildcard destination" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "0.0.0.0");
    defer fixture.deinit();
    try fixture.start(3);
    const fd = try sender(c.AF_INET);
    defer _ = std.posix.system.close(fd);
    try send(fd, ipv4_destination(&fixture, 2), "aaaabbbbcc", 4);
    try fixture.run();
    try std.testing.expectEqual(@as(u64, 1), fixture.transport.gro_batches);
    try std.testing.expectEqual(@as(usize, 3), fixture.transport.engine.count);
    const expected = [_][]const u8{ "aaaa", "bbbb", "cc" };
    for (fixture.transport.engine.packets[0..3], expected) |packet, value| {
        try std.testing.expectEqualStrings(value, packet.bytes[0..packet.length]);
        try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 2 }, &packet.local.ip4.bytes);
        try std.testing.expectEqual(fixture.transport.local_address.ip4.port, packet.local.ip4.port);
    }
}

test "udp GRO: IPv6 aggregates retain destination interface and peer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "::");
    defer fixture.deinit();
    try fixture.start(3);
    const fd = try sender(c.AF_INET6);
    defer _ = std.posix.system.close(fd);
    const destination: IpAddress = .{ .ip6 = .loopback(fixture.transport.local_address.ip6.port) };
    try send(fd, destination, "aaaabbbbcc", 4);
    try fixture.run();
    try std.testing.expectEqual(@as(u64, 1), fixture.transport.gro_batches);
    try std.testing.expectEqual(@as(usize, 3), fixture.transport.engine.count);
    for (fixture.transport.engine.packets[0..3]) |packet| {
        try std.testing.expectEqualSlices(u8, &destination.ip6.bytes, &packet.local.ip6.bytes);
        try std.testing.expect(packet.local.ip6.interface.index != 0);
        try std.testing.expectEqualSlices(u8, &destination.ip6.bytes, &packet.peer.ip6.bytes);
    }
}

test "udp GRO: shutdown during the first segment prevents siblings and rearming" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "127.0.0.1");
    defer fixture.deinit();
    try fixture.start(1);
    const fd = try sender(c.AF_INET);
    defer _ = std.posix.system.close(fd);
    try send(fd, fixture.transport.local_address, "aaaabbbbcc", 4);
    try fixture.run();
    try std.testing.expectEqual(@as(u64, 1), fixture.transport.gro_batches);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.count);
    fixture.transport.shutdown();
    try fixture.loop.xev_loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.count);
}

test "udp GRO: shutdown while waiting drains exactly once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "127.0.0.1");
    defer fixture.deinit();
    try fixture.start(1);
    Fixture.stop(&fixture);
    fixture.transport.shutdown();
    try fixture.run();
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.engine.count);
}

test "udp GRO: peers destinations and absent metadata do not inherit prior receive state" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "0.0.0.0");
    defer fixture.deinit();
    try fixture.start(4);
    const first = try sender(c.AF_INET);
    defer _ = std.posix.system.close(first);
    const second = try sender(c.AF_INET);
    defer _ = std.posix.system.close(second);
    try send(first, ipv4_destination(&fixture, 1), "aaaabbbbcc", 4);
    try send(second, ipv4_destination(&fixture, 2), "ordinary", null);
    try fixture.run();
    try std.testing.expectEqual(@as(u64, 1), fixture.transport.gro_batches);
    try std.testing.expectEqual(@as(usize, 4), fixture.transport.engine.count);
    const last = fixture.transport.engine.packets[3];
    try std.testing.expectEqualStrings("ordinary", last.bytes[0..last.length]);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 2 }, &last.local.ip4.bytes);
    try std.testing.expect(last.peer.ip4.port != fixture.transport.engine.packets[0].peer.ip4.port);
}

test "udp GRO: oversized individual datagrams are dropped before a healthy sibling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    var fixture = try Fixture.init(&router, "127.0.0.1");
    defer fixture.deinit();
    try fixture.start(1);
    const fd = try sender(c.AF_INET);
    defer _ = std.posix.system.close(fd);
    var oversized: [support.udp.receive.max_datagram_bytes + 1]u8 = @splat(1);
    try send(fd, fixture.transport.local_address, &oversized, null);
    try send(fd, fixture.transport.local_address, "healthy", null);
    try fixture.run();
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.engine.count);
    const packet = fixture.transport.engine.packets[0];
    try std.testing.expectEqualStrings("healthy", packet.bytes[0..packet.length]);
}

test "udp GRO: native IPv6 addresses preserve scope and flow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var address: IpAddress = .{ .ip6 = .loopback(8443) };
    address.ip6.interface.index = 7;
    address.ip6.flow = 1234;
    const native = support.quic_api.Sockaddr.init(address);
    const value: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&native.storage));
    try std.testing.expectEqual(@as(u32, 7), value.scope_id);
    try std.testing.expectEqual(@as(u32, 1234), value.flowinfo);
}

fn bind_socket(fd: std.posix.socket_t, address: IpAddress) !support.quic_api.Sockaddr {
    var native = support.quic_api.Sockaddr.init(address);
    if (c.bind(fd, native.ptr(), native.length) != 0) return error.BindFailed;
    if (c.getsockname(fd, @ptrCast(&native.storage), &native.length) != 0) return error.SocketAddressFailed;
    return native;
}

test "udp GRO: wildcard replies honor source addresses and GSO source grouping" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const transmit = try sender(c.AF_INET);
    defer _ = std.posix.system.close(transmit);
    const bound = try bind_socket(transmit, .{ .ip4 = .unspecified(0) });
    const bound_ip: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&bound.storage));
    const port = std.mem.bigToNative(u16, bound_ip.port);
    const receiver = try sender(c.AF_INET);
    defer _ = std.posix.system.close(receiver);
    const destination = try bind_socket(receiver, .{ .ip4 = .loopback(0) });
    var timeout = std.posix.timeval{ .sec = 1, .usec = 0 };
    try std.posix.setsockopt(receiver, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    var first_data: [4]u8 = "aaaa".*;
    var second_data: [4]u8 = "bbbb".*;
    var first_iov = [_]c.struct_iovec{.{ .iov_base = &first_data, .iov_len = first_data.len }};
    var second_iov = [_]c.struct_iovec{.{ .iov_base = &second_data, .iov_len = second_data.len }};
    for ([_][2]u8{ .{ 2, 2 }, .{ 2, 3 } }) |last_octets| {
        const first_source = support.quic_api.Sockaddr.init(.{ .ip4 = .{ .bytes = .{ 127, 0, 0, last_octets[0] }, .port = port } });
        const second_source = support.quic_api.Sockaddr.init(.{ .ip4 = .{ .bytes = .{ 127, 0, 0, last_octets[1] }, .port = port } });
        const specs = [_]c.lsquic_out_spec{
            .{ .iov = &first_iov, .iovlen = 1, .dest_sa = destination.ptr(), .local_sa = first_source.ptr() },
            .{ .iov = &second_iov, .iovlen = 1, .dest_sa = destination.ptr(), .local_sa = second_source.ptr() },
        };
        try std.testing.expectEqual(@as(c_int, 2), support.quic_api.send_packets(transmit, &specs, specs.len));
        for (last_octets) |last_octet| {
            var received: [8]u8 = undefined;
            var peer: std.posix.sockaddr.in = undefined;
            var length: c.socklen_t = @sizeOf(std.posix.sockaddr.in);
            const bytes = c.recvfrom(receiver, &received, received.len, 0, @ptrCast(&peer), &length);
            try std.testing.expectEqual(@as(isize, 4), bytes);
            try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, last_octet }, std.mem.asBytes(&peer.addr));
        }
    }
}

test "udp GRO: IPv6 replies honor source packet info" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const transmit = try sender(c.AF_INET6);
    defer _ = std.posix.system.close(transmit);
    const bound = try bind_socket(transmit, .{ .ip6 = .unspecified(0) });
    const bound_ip: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&bound.storage));
    const port = std.mem.bigToNative(u16, bound_ip.port);
    const receiver = try sender(c.AF_INET6);
    defer _ = std.posix.system.close(receiver);
    const destination = try bind_socket(receiver, .{ .ip6 = .loopback(0) });
    var timeout = std.posix.timeval{ .sec = 1, .usec = 0 };
    try std.posix.setsockopt(receiver, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    const source = support.quic_api.Sockaddr.init(.{ .ip6 = .loopback(port) });
    var data: [4]u8 = "aaaa".*;
    var iov = [_]c.struct_iovec{.{ .iov_base = &data, .iov_len = data.len }};
    const specs = [_]c.lsquic_out_spec{
        .{ .iov = &iov, .iovlen = 1, .dest_sa = destination.ptr(), .local_sa = source.ptr() },
        .{ .iov = &iov, .iovlen = 1, .dest_sa = destination.ptr(), .local_sa = source.ptr() },
    };
    try std.testing.expectEqual(@as(c_int, 2), support.quic_api.send_packets(transmit, &specs, specs.len));
    for (0..2) |_| {
        var received: [8]u8 = undefined;
        var peer: std.posix.sockaddr.in6 = undefined;
        var length: c.socklen_t = @sizeOf(std.posix.sockaddr.in6);
        const bytes = c.recvfrom(receiver, &received, received.len, 0, @ptrCast(&peer), &length);
        try std.testing.expectEqual(@as(isize, 4), bytes);
        try std.testing.expectEqualSlices(u8, &std.Io.net.Ip6Address.loopback(0).bytes, &peer.addr);
        try std.testing.expectEqual(port, std.mem.bigToNative(u16, peer.port));
    }
}

test "udp GRO: legacy custom engines retain their datagram callback contract" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const requested = try select_backend();
    var loop = if (requested != null)
        support.loop.Loop{ .xev_loop = try xev.Loop.init(.{ .entries = 256 }) }
    else
        try support.loop.init();
    defer support.loop.deinit(&loop);
    if (requested) |backend| try std.testing.expectEqual(backend, xev.backend());
    var bundle = support.radix.DefaultBundle{};
    var router = try Router.init(bundle.storage());
    const LegacyTransport = support.udp.quic_transport(LegacyEngine);
    var transport = try LegacyTransport.init(@ptrFromInt(1), &router, "127.0.0.1", 0);
    defer transport.deinit();
    try transport.start(loop.get_xev_loop());
    defer {
        transport.shutdown();
        loop.xev_loop.run(.until_done) catch @panic("legacy UDP fixture did not drain");
    }
    const fd = try sender(c.AF_INET);
    defer _ = std.posix.system.close(fd);
    try send(fd, transport.local_address, "legacy", null);
    var attempts: usize = 0;
    while (transport.engine.capture.count == 0 and attempts < 4) : (attempts += 1) try loop.xev_loop.run(.once);
    try std.testing.expectEqual(@as(usize, 1), transport.engine.capture.count);
    const packet = transport.engine.capture.packets[0];
    try std.testing.expectEqualStrings("legacy", packet.bytes[0..packet.length]);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &packet.local.ip4.bytes);
}
