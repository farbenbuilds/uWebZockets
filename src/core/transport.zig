const std = @import("std");
const http_parser = @import("../http/parser.zig");
const Request = @import("../http/request.zig").Request;

/// Receives one parsed request borrowed from the protocol core's storage.
pub const RequestHandler = *const fn (*anyopaque, *const Request) void;

/// Protocol-only HTTP core. It owns bounded parsing state but no socket state.
pub fn protocol_core(comptime capacity: usize) type {
    if (capacity < http_parser.max_request_line_size + 4) {
        @compileError("protocol core capacity cannot hold the maximum request line");
    }

    return struct {
        const Self = @This();

        parser: http_parser.HttpParser = .{},
        request: Request = .{},
        storage: [capacity]u8 = undefined,
        length: usize = 0,

        /// Feeds borrowed network bytes into the transport-independent parser.
        pub fn ingest(
            self: *Self,
            input: []const u8,
            context: *anyopaque,
            handler: RequestHandler,
        ) !usize {
            if (input.len > self.storage.len - self.length) return error.InputBufferFull;
            @memcpy(self.storage[self.length .. self.length + input.len], input);
            self.length += input.len;

            var dispatched: usize = 0;
            while (self.length != 0) {
                const consumed = http_parser.consume(
                    &self.parser,
                    &self.request,
                    self.storage[0..self.length],
                );
                switch (self.parser.state) {
                    .error_invalid => return error.InvalidRequest,
                    .error_headers_too_large => return error.HeadersTooLarge,
                    .error_too_large => return error.BodyTooLarge,
                    .done => {},
                    else => break,
                }

                handler(context, &self.request);
                dispatched += 1;
                const remaining = self.length - consumed;
                std.mem.copyForwards(
                    u8,
                    self.storage[0..remaining],
                    self.storage[consumed..self.length],
                );
                self.length = remaining;
                self.request = .{};
                http_parser.reset(&self.parser);
            }
            return dispatched;
        }
    };
}

/// Compile-time transport driver used by native sockets and WASM host imports.
pub fn driver(comptime Adapter: type) type {
    comptime {
        for (&.{ "read", "write", "set_read_enabled", "close" }) |name| {
            if (!@hasDecl(Adapter, name)) {
                @compileError("transport adapter is missing " ++ name);
            }
        }
    }

    return struct {
        context: *anyopaque,

        pub fn read(self: @This(), destination: []u8) !usize {
            return Adapter.read(self.context, destination);
        }

        pub fn write(self: @This(), parts: []const []const u8) !usize {
            return Adapter.write(self.context, parts);
        }

        pub fn set_read_enabled(self: @This(), enabled: bool) void {
            Adapter.set_read_enabled(self.context, enabled);
        }

        pub fn close(self: @This()) void {
            Adapter.close(self.context);
        }
    };
}
