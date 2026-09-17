const std = @import("std");
const support = @import("test_support");

const app_module = support.app;
const builder_module = support.builder;
const config_module = support.config;
const rejection = support.rejection;
const ServerConfig = config_module.ServerConfig;
const Preset = ServerConfig.Preset;

/// Wraps a parent allocator and counts application-level allocations.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = deallocate,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address) orelse
            return null;
        self.allocations += 1;
        self.live_bytes += len;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, return_address)) {
            return false;
        }
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const mapped = self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return mapped;
    }

    fn deallocate(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.live_bytes -= memory.len;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

test "config: presets validate and plan contiguous slabs" {
    inline for (.{ Preset.microservice, Preset.websocket_chat, Preset.file_server }) |preset| {
        try preset.validate();
        const bytes = try preset.slab_bytes();
        try std.testing.expect(bytes > preset.max_connections * preset.write_queue_size);
        try std.testing.expect(bytes > preset.max_connections * preset.max_body_size);
    }

    try std.testing.expectError(error.InvalidConnectionCapacity, (ServerConfig{
        .max_connections = 0,
    }).validate());
    try std.testing.expectError(error.InvalidWebSocketMessageCapacity, (ServerConfig{
        .max_ws_message_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidWriteQueueCapacity, (ServerConfig{
        .write_queue_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidBodyCapacity, (ServerConfig{
        .max_body_size = 0,
    }).validate());
    try std.testing.expectError(error.InvalidIdleTimeout, (ServerConfig{
        .idle_timeout_ms = std.math.maxInt(i64) + 1,
    }).validate());
}

test "config: request stride covers the configured body" {
    const config = ServerConfig{
        .max_connections = 2,
        .max_body_size = 50 * 1024 * 1024,
    };
    const stride = try config.request_buffer_stride();
    try std.testing.expect(stride >= config.max_body_size);
    try std.testing.expectEqual(
        @as(usize, 0),
        stride % config_module.request_buffer_alignment,
    );

    const headroom = stride - config.max_body_size;
    try std.testing.expect(headroom >= support.http_parser.max_header_size);
    try std.testing.expect(headroom >= support.http_parser.max_request_line_size);
}

test "config: with derives a modified copy" {
    const derived = Preset.microservice.with(.{
        .max_connections = 3,
        .compression = true,
    });
    try std.testing.expectEqual(@as(usize, 3), derived.max_connections);
    try std.testing.expect(derived.compression);
    try std.testing.expectEqual(
        Preset.microservice.max_body_size,
        derived.max_body_size,
    );
}

test "config: carve partitions one slab into disjoint aligned regions" {
    const config = ServerConfig{
        .max_connections = 4,
        .max_ws_message_size = 1024,
        .write_queue_size = 2048,
        .max_body_size = 4096,
        .compression = true,
    };
    const total = try config_module.required_bytes(config);
    const slab = try std.testing.allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(config_module.slab_alignment),
        total,
    );
    defer std.testing.allocator.free(slab);

    const layout = try config_module.carve(slab, config);
    try std.testing.expectEqual(total, layout.total_bytes);
    try std.testing.expectEqual(@as(usize, 4), layout.pool_storage.len);
    try std.testing.expectEqual(@as(usize, 4), layout.freelist.len);
    try std.testing.expectEqual(
        @as(usize, 4 * layout.request_buffer_stride),
        layout.request_buffers.len,
    );
    try std.testing.expectEqual(@as(usize, 4 * 2048), layout.write_queues.len);
    try std.testing.expectEqual(@as(usize, 4 * 1024), layout.ws_messages.len);
    try std.testing.expectEqual(
        @as(usize, 4 * layout.compression_stride),
        layout.compression_scratch.len,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(layout.pool_storage.ptr) % @alignOf(support.tcp.TcpConnection),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(layout.write_queues.ptr) % config_module.write_queue_alignment,
    );

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.SlabTooSmall, config_module.carve(&small, config));
}

test "config: builder builds one slab and reports its size" {
    const allocator = std.testing.allocator;
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0);
    try std.testing.expectEqual(@as(u64, 0), builder.configuration().idle_timeout_ms);

    var server = try builder.build(allocator);
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 8192), server.max_body_size);
    try std.testing.expectEqual(
        @as(usize, 2),
        server.request_buffers.len / server.request_buffer_stride,
    );
    try std.testing.expectEqual(builder.slab_bytes() catch 0, server.slab.len);
}

test "pool: from_slices adopts caller storage without owning it" {
    var storage: [4]u32 = undefined;
    var freelist: [4]usize = undefined;
    var pool = try support.pool.freelist_pool(u32, 4).from_slices(&storage, &freelist);

    const slot = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());
    try std.testing.expect(pool.release(slot));
    pool.deinit();

    var short: [2]usize = undefined;
    try std.testing.expectError(
        error.StorageCapacityMismatch,
        support.pool.freelist_pool(u32, 4).from_slices(&storage, &short),
    );
}

test "parser: per-connection body policy overrides the default" {
    const wire = "POST / HTTP/1.1\r\nHost: example\r\nContent-Length: 9\r\n\r\nhello wor";
    var buffer: [wire.len]u8 = undefined;
    @memcpy(&buffer, wire);

    var default_request = support.http_request.Request{};
    var default_parser = support.http_parser.HttpParser{};
    _ = support.http_parser.consume(&default_parser, &default_request, &buffer);
    try std.testing.expectEqual(support.http_parser.ParserState.done, default_parser.state);

    var limited_request = support.http_request.Request{};
    var limited_parser = support.http_parser.HttpParser{ .max_body_size = 8 };
    _ = support.http_parser.consume(&limited_parser, &limited_request, &buffer);
    try std.testing.expectEqual(
        support.http_parser.ParserState.error_too_large,
        limited_parser.state,
    );
}

test "rejection: documents name the configured limits" {
    var buffer: [rejection.max_document_bytes]u8 = undefined;

    const policy = rejection.RejectionPolicy{
        .max_body_size = 16 * 1024,
        .max_header_size = 16 * 1024,
    };
    const body = policy.payload_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, body, "16KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "'max_body_size'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"payload_too_large\"") != null);

    const headers = policy.headers_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, headers, "16KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "\"headers_too_large\"") != null);

    const fifty = rejection.RejectionPolicy{ .max_body_size = 50 * 1024 * 1024 };
    const large = fifty.payload_too_large(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, large, "50MB") != null);
}

test "rejection: format_bytes renders compact binary units" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0B", rejection.format_bytes(0, &buffer));
    try std.testing.expectEqualStrings("512B", rejection.format_bytes(512, &buffer));
    try std.testing.expectEqualStrings("1KB", rejection.format_bytes(1024, &buffer));
    try std.testing.expectEqualStrings("1.5KB", rejection.format_bytes(1536, &buffer));
    try std.testing.expectEqualStrings("16MB", rejection.format_bytes(16 * 1024 * 1024, &buffer));
}

test "deflate: planner bound covers negotiated compression scratch" {
    var context = try support.ws_deflate.Context.init(6);
    defer context.deinit();

    for ([_]usize{ 1, 64, 1024, 16 * 1024, 64 * 1024, 1024 * 1024 }) |input_len| {
        const negotiated = try context.scratch_bound(input_len);
        const planned = try support.ws_deflate.worst_case_scratch_bound(input_len);
        try std.testing.expect(planned >= negotiated);
    }
}

test "config: app init carves request buffers out of the slab" {
    const TestApp = app_module.configured_app_with_timeout(2, 1024, 4096, 0);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();

    const expected_config = ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
    };
    const stride = try expected_config.request_buffer_stride();

    try std.testing.expectEqual(
        @as(usize, support.http_parser.default_max_body_size),
        server.max_body_size,
    );
    try std.testing.expectEqual(@as(usize, 2 * stride), server.request_buffers.len);
}

test "config: oversized capacities fail without panicking" {
    const huge = ServerConfig{ .max_connections = std.math.maxInt(usize) };
    try std.testing.expectError(error.SlabSizeOverflow, huge.slab_bytes());

    const wide_digits = ServerConfig{
        .max_connections = std.math.maxInt(usize) / 2,
        .max_body_size = std.math.maxInt(usize) / 2,
    };
    try std.testing.expectError(error.SlabSizeOverflow, wide_digits.slab_bytes());
}

fn dummy_handler(_: *support.http_request.Request, _: *support.http_response.Response) void {}

test "config: build allocates exactly one slab and routing never allocates" {
    var counting = CountingAllocator{ .parent = std.testing.allocator };
    const builder = builder_module.Server.builder(std.testing.io)
        .with_max_clients(2)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(4096)
        .with_max_body_size(8192)
        .with_idle_timeout_ms(0);

    var server = try builder.build(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);

    _ = try server.get("/health", dummy_handler);
    _ = try server.post("/echo", dummy_handler);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);

    server.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.frees);
    try std.testing.expectEqual(@as(usize, 0), counting.live_bytes);
}
