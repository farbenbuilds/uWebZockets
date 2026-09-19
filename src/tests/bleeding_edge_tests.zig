const builtin = @import("builtin");
const std = @import("std");
const support = @import("test_support");

test "bleeding edge: abort signals publish the first reason" {
    var controller = support.abort.AbortController{};
    const signal = controller.signal();
    try std.testing.expect(!signal.aborted());
    try std.testing.expect(support.abort.abort_if_expired(&controller, 100, 100));
    try std.testing.expectEqual(support.abort.AbortReason.timeout, signal.reason());
    try std.testing.expect(!controller.abort(.caller));
    try std.testing.expectError(error.Aborted, signal.checkpoint());

    controller.reset();
    const next_signal = controller.signal();
    try std.testing.expect(signal.aborted());
    try std.testing.expectEqual(support.abort.AbortReason.connection_closed, signal.reason());
    try std.testing.expect(!next_signal.aborted());
}

test "bleeding edge: backpressure transitions are pure and hysteretic" {
    const initial = try support.ws_backpressure.State.init(8, 3);
    const paused = try support.ws_backpressure.transition(initial, .{ .enqueue = 8 });
    try std.testing.expectEqual(support.ws_backpressure.Action.pause_producer, paused.next_action);
    try std.testing.expectEqual(support.ws_backpressure.Phase.backpressured, paused.new_state.phase);
    try std.testing.expectEqual(@as(usize, 0), initial.queued_bytes);

    const still_paused = try support.ws_backpressure.transition(paused.new_state, .{ .flushed = 4 });
    try std.testing.expectEqual(support.ws_backpressure.Action.none, still_paused.next_action);
    const resumed = try support.ws_backpressure.transition(still_paused.new_state, .{ .flushed = 1 });
    try std.testing.expectEqual(support.ws_backpressure.Action.resume_producer, resumed.next_action);
}

test "bleeding edge: WebSocketStream bridges event input to BYOB pulls" {
    const FakeAdapter = struct {
        sent: [32]u8 = undefined,
        sent_length: usize = 0,
        closed: bool = false,
        terminated: bool = false,

        pub fn send(context: *anyopaque, message: []const u8, _: support.ws_stream.MessageKind) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (message.len > self.sent.len) return error.Full;
            @memcpy(self.sent[0..message.len], message);
            self.sent_length = message.len;
        }

        pub fn close(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }

        pub fn terminate(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.terminated = true;
        }
    };
    const TestStream = support.ws_stream.web_socket_stream(FakeAdapter);

    var adapter = FakeAdapter{};
    var incoming: [16]u8 = undefined;
    var socket_stream = try TestStream.init(&adapter, &incoming, 5, 2, null);
    try socket_stream.push_incoming("event");
    var destination: [8]u8 = undefined;
    const read_length = try socket_stream.read(&destination);
    try std.testing.expectEqualStrings("event", destination[0..read_length]);

    try std.testing.expectEqual(
        support.ws_backpressure.Action.pause_producer,
        try socket_stream.send("hello", .text),
    );
    try std.testing.expectEqualStrings("hello", adapter.sent[0..adapter.sent_length]);
    _ = try socket_stream.close();
    try std.testing.expectEqual(
        support.ws_backpressure.Action.close_transport,
        try socket_stream.flushed(5),
    );
    try std.testing.expect(adapter.closed);
}

test "bleeding edge: CompressionStream round trips gzip chunks" {
    var plain_storage: [128]u8 = undefined;
    var compressor = try support.compression_stream.CompressionStream.init(
        .gzip,
        6,
        &plain_storage,
    );
    defer compressor.deinit();
    try compressor.write("zero-copy ");
    try compressor.write("compression stream");

    var compressed_storage: [256]u8 = undefined;
    const compressed = try compressor.finish(&compressed_storage);

    var encoded_storage: [256]u8 = undefined;
    var decompressor = try support.compression_stream.DecompressionStream.init(
        .gzip,
        &encoded_storage,
    );
    defer decompressor.deinit();
    try decompressor.write(compressed);
    var output: [128]u8 = undefined;
    const decoded = try decompressor.finish(&output);
    try std.testing.expectEqualStrings("zero-copy compression stream", decoded);
}

test "bleeding edge: BoringSSL Web Crypto SHA HMAC and AES-GCM" {
    const digest = support.crypto_subtle.digest_sha256("abc");
    const expected_digest = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected_digest, &digest);

    const hmac = support.crypto_subtle.sign_hmac_sha256(
        "key",
        "The quick brown fox jumps over the lazy dog",
    );
    try std.testing.expect(support.crypto_subtle.verify_hmac_sha256(
        "key",
        "The quick brown fox jumps over the lazy dog",
        &hmac,
    ));

    const key = [_]u8{0x11} ** 16;
    const nonce = [_]u8{0x22} ** support.crypto_subtle.aes_gcm_nonce_length;
    var encrypted_storage: [64]u8 = undefined;
    const encrypted = try support.crypto_subtle.encrypt_aes_gcm(
        &key,
        &nonce,
        "secret payload",
        "rpc-method",
        &encrypted_storage,
    );
    var plaintext_storage: [64]u8 = undefined;
    const plaintext = try support.crypto_subtle.decrypt_aes_gcm(
        &key,
        &nonce,
        encrypted,
        "rpc-method",
        &plaintext_storage,
    );
    try std.testing.expectEqualStrings("secret payload", plaintext);

    encrypted[encrypted.len - 1] ^= 1;
    try std.testing.expectError(
        error.AuthenticationFailed,
        support.crypto_subtle.decrypt_aes_gcm(
            &key,
            &nonce,
            encrypted,
            "rpc-method",
            &plaintext_storage,
        ),
    );
}

test "bleeding edge: shared memory rejects stale handles and validates Cap'n Proto" {
    const Region = support.shared_memory.region(64, 2);
    var region: Region = .{};
    const first = try region.acquire(16);
    const bytes = try region.bytes(first);
    @memset(bytes, 0xa5);
    try region.release(first);
    try std.testing.expectError(error.InvalidHandle, region.bytes(first));

    const second = try region.acquire(16);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), try region.bytes(second));
    try region.release(second);

    const words = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var message_storage: [16]u8 = undefined;
    const message = try support.shared_memory.write_capnp_message(&words, &message_storage);
    const decoded = try support.shared_memory.read_capnp_message(message, 1);
    try std.testing.expectEqualSlices(u8, &words, decoded);
}

test "bleeding edge: protocol core parses without transport state" {
    const Core = support.transport.protocol_core(24 * 1024);
    const Capture = struct {
        calls: usize = 0,
        path: [16]u8 = undefined,
        path_length: usize = 0,

        fn handle(context: *anyopaque, request: *const support.http_request.Request) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            @memcpy(self.path[0..request.path.len], request.path);
            self.path_length = request.path.len;
        }
    };

    var core: Core = .{};
    var capture = Capture{};
    const request = "GET /edge HTTP/1.1\r\nHost: example.test\r\n\r\n";
    const dispatch_count = try core.ingest(request, &capture, Capture.handle);
    try std.testing.expectEqual(@as(usize, 1), dispatch_count);
    try std.testing.expectEqualStrings("/edge", capture.path[0..capture.path_length]);
}

fn static_ping(call: *support.json_rpc.Call) support.json_rpc.HandlerError!void {
    try call.result("pong");
}

fn static_status(call: *support.json_rpc.Call) support.json_rpc.HandlerError!void {
    try call.result(.{ .ok = true });
}

test "bleeding edge: comptime RPC service uses a perfect jump table" {
    const StaticService = support.json_rpc.comptime_service(&.{
        .{ .method = "ping", .handler = static_ping },
        .{ .method = "system.status", .handler = static_status },
    });
    var service = StaticService{};
    var output: [256]u8 = undefined;
    const response = (try service.dispatch(
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":1}",
        &output,
    )).?;
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":\"pong\",\"id\":1}",
        response,
    );

    var controller = support.abort.AbortController{};
    const signal = controller.signal();
    _ = controller.abort(.caller);
    try std.testing.expectError(
        error.Aborted,
        service.dispatch_with_signal(
            signal,
            "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":2}",
            &output,
        ),
    );
}

test "bleeding edge: AF_XDP address rings preserve bounded ownership" {
    var producer: u32 = 0;
    var consumer: u32 = 0;
    var addresses = [_]u64{0} ** 2;
    var page: [std.heap.page_size_min]u8 align(std.heap.page_size_min) = undefined;
    var ring = support.xdp.AddressRing{
        .mapping = &page,
        .producer = &producer,
        .consumer = &consumer,
        .addresses = &addresses,
        .mask = 1,
        .cached_producer = 0,
        .cached_consumer = 0,
    };
    try ring.submit(0);
    try ring.submit(4096);
    try std.testing.expectError(error.RingFull, ring.submit(8192));
    try std.testing.expectEqual(@as(u64, 0), try ring.consume());
    try std.testing.expectEqual(@as(u64, 4096), try ring.consume());
    try std.testing.expectError(error.RingEmpty, ring.consume());
}

test "bleeding edge: SIMD scans HTTP delimiters and rejects controls" {
    try std.testing.expectEqual(@as(?usize, 5), support.simd.index_of_crlf("hello\r\nworld"));
    try std.testing.expectEqual(@as(?usize, 3), support.simd.index_of_header_end("one\r\n\r\ntwo"));
    try std.testing.expect(support.simd.valid_http_field_value("cache-control: no-store"));
    try std.testing.expect(!support.simd.valid_http_field_value("bad\x00value"));
}

test "bleeding edge: Linux ABI structures and invalid setup fail safely" {
    // The XDP socket entry point is comptime-gated to Linux; keep the call inside
    // a comptime branch so non-Linux targets never analyze it.
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(support.xdp.Descriptor));
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(support.ktls.AesGcm128));
        var empty: [0]u8 = .{};
        try std.testing.expectError(error.InvalidArgument, support.xdp.XskSocket.init(&empty, 4096, 0));
    }
}

test "bleeding edge: GPA and request arena release all lifecycle memory" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, gpa.deinit()) catch @panic("GPA leak");
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const copy = try arena.allocator().dupe(u8, "connection state");
    try std.testing.expectEqualStrings("connection state", copy);
}
