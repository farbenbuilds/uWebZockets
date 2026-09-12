const std = @import("std");

pub const default_max_procedures = 64;
pub const default_method_storage_capacity = 4096;
pub const default_response_capacity = 16 * 1024;
pub const max_method_length = 255;
pub const max_member_name_length = 255;
pub const scanner_scratch_capacity = 2048;
pub const typed_params_scratch_capacity = 4096;
pub const min_response_capacity = 128;

pub const standard_error = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

pub const HandlerError = error{
    ApplicationError,
    InternalError,
    InvalidParams,
    OutOfMemory,
    ResultAlreadyWritten,
    ResultTooLarge,
};

pub const DispatchError = error{ResponseTooLarge};

pub const RegistrationError = error{
    DuplicateProcedure,
    InvalidMethodName,
    MethodStorageCapacityReached,
    ProcedureCapacityReached,
    RegistryLocked,
};

pub const Fault = struct {
    code: i32,
    message: []const u8,
};

/// Borrowed inputs and bounded result writer for one procedure invocation.
pub const Call = struct {
    params: ?[]const u8,
    writer: ?*std.Io.Writer,
    fault: ?Fault = null,
    result_written: bool = false,

    /// Parses positional or named parameters with an explicit allocator.
    pub fn parse_params(
        self: *const Call,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) HandlerError!std.json.Parsed(T) {
        const raw = self.params orelse return error.InvalidParams;
        return std.json.parseFromSlice(T, allocator, raw, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidParams,
        };
    }

    /// Writes one typed result directly into the caller-owned response buffer.
    pub fn result(self: *Call, value: anytype) HandlerError!void {
        if (self.result_written) return error.ResultAlreadyWritten;
        if (self.writer) |writer| {
            writer.print("{f}", .{std.json.fmt(value, .{})}) catch {
                return error.ResultTooLarge;
            };
        }
        self.result_written = true;
    }

    /// Returns a JSON-RPC application error from a procedure.
    pub fn fail(self: *Call, code: i32, message: []const u8) HandlerError {
        self.fault = .{ .code = code, .message = message };
        return error.ApplicationError;
    }
};

pub const Handler = *const fn (*Call) HandlerError!void;
pub const ContextHandler = *const fn (*anyopaque, *Call) HandlerError!void;

const HandlerKind = enum(u8) {
    direct,
    contextual,
};

const ParsedRequest = struct {
    method: []const u8 = "",
    params: ?[]const u8 = null,
    id: ?[]const u8 = null,
    valid: bool = true,
    has_version: bool = false,
    has_method: bool = false,
    has_params: bool = false,
    has_id: bool = false,

    fn wants_response(self: ParsedRequest) bool {
        return !self.valid or self.has_id;
    }
};

/// Default fixed-capacity JSON-RPC 2.0 service type.
pub const Service = configured_service(
    default_max_procedures,
    default_method_storage_capacity,
    default_response_capacity,
);

/// Returns a JSON-RPC 2.0 service with explicit fixed capacities.
pub fn configured_service(
    comptime max_procedures: usize,
    comptime method_storage_capacity: usize,
    comptime response_capacity: usize,
) type {
    if (max_procedures == 0) @compileError("RPC procedure capacity must be greater than zero");
    if (max_procedures >= std.math.maxInt(u16)) @compileError("RPC procedure capacity exceeds index storage");
    if (method_storage_capacity == 0) @compileError("RPC method storage must be greater than zero");
    if (method_storage_capacity > std.math.maxInt(u32)) @compileError("RPC method storage exceeds offset storage");
    if (response_capacity < min_response_capacity) @compileError("RPC response capacity is too small");

    const table_capacity = max_procedures * 2 + 1;

    return struct {
        const Self = @This();

        method_storage: [method_storage_capacity]u8 = undefined,
        method_offsets: [max_procedures]u32 = undefined,
        method_lengths: [max_procedures]u16 = undefined,
        handler_kinds: [max_procedures]HandlerKind = undefined,
        handlers: [max_procedures]Handler = undefined,
        context_handlers: [max_procedures]ContextHandler = undefined,
        contexts: [max_procedures]?*anyopaque = undefined,
        lookup_slots: [table_capacity]u16 = .{0} ** table_capacity,
        response_storage: [response_capacity]u8 = undefined,
        method_storage_length: usize = 0,
        procedure_count: usize = 0,
        sealed: bool = false,

        /// Registers one context-free procedure and copies its method name.
        pub fn register(
            self: *Self,
            method: []const u8,
            handler: Handler,
        ) RegistrationError!void {
            try self.register_impl(method, .direct, handler, undefined, null);
        }

        /// Registers a typed procedure with automatic bounded parameter decoding.
        pub fn register_typed(
            self: *Self,
            method: []const u8,
            comptime Params: type,
            comptime Result: type,
            comptime handler: *const fn (Params) HandlerError!Result,
        ) RegistrationError!void {
            const Adapter = struct {
                fn invoke(call: *Call) HandlerError!void {
                    var scratch_buffer: [typed_params_scratch_capacity]u8 = undefined;
                    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);
                    const params = try call.parse_params(Params, scratch.allocator());
                    defer params.deinit();

                    const value = try handler(params.value);
                    try call.result(value);
                }
            };
            try self.register(method, Adapter.invoke);
        }

        /// Registers one procedure with a caller-owned context pointer.
        pub fn register_context(
            self: *Self,
            method: []const u8,
            context: *anyopaque,
            handler: ContextHandler,
        ) RegistrationError!void {
            try self.register_impl(method, .contextual, undefined, handler, context);
        }

        /// Registers a typed context procedure with bounded parameter decoding.
        pub fn register_typed_context(
            self: *Self,
            method: []const u8,
            context: anytype,
            comptime Params: type,
            comptime Result: type,
            comptime handler: *const fn (@TypeOf(context), Params) HandlerError!Result,
        ) RegistrationError!void {
            const Pointer = @TypeOf(context);
            const pointer = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => @compileError("typed RPC context must be passed by mutable pointer"),
            };
            if (pointer.size != .one or pointer.is_const) {
                @compileError("typed RPC context must be passed by mutable single-item pointer");
            }

            const Adapter = struct {
                fn invoke(raw_context: *anyopaque, call: *Call) HandlerError!void {
                    const typed_context: Pointer = @ptrCast(@alignCast(raw_context));
                    var scratch_buffer: [typed_params_scratch_capacity]u8 = undefined;
                    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);
                    const params = try call.parse_params(Params, scratch.allocator());
                    defer params.deinit();

                    const value = try handler(typed_context, params.value);
                    try call.result(value);
                }
            };
            try self.register_context(method, context, Adapter.invoke);
        }

        fn register_impl(
            self: *Self,
            method: []const u8,
            kind: HandlerKind,
            handler: Handler,
            context_handler: ContextHandler,
            context: ?*anyopaque,
        ) RegistrationError!void {
            if (self.sealed) return error.RegistryLocked;
            if (!valid_method_name(method)) return error.InvalidMethodName;
            if (self.find(method) != null) return error.DuplicateProcedure;
            if (self.procedure_count == max_procedures) return error.ProcedureCapacityReached;

            const storage_end = std.math.add(
                usize,
                self.method_storage_length,
                method.len,
            ) catch return error.MethodStorageCapacityReached;
            if (storage_end > method_storage_capacity) return error.MethodStorageCapacityReached;

            const index = self.procedure_count;
            @memcpy(self.method_storage[self.method_storage_length..storage_end], method);
            self.method_offsets[index] = @intCast(self.method_storage_length);
            self.method_lengths[index] = @intCast(method.len);
            self.handler_kinds[index] = kind;
            self.contexts[index] = context;
            switch (kind) {
                .direct => self.handlers[index] = handler,
                .contextual => self.context_handlers[index] = context_handler,
            }

            self.insert_lookup(method, index);
            self.method_storage_length = storage_end;
            self.procedure_count += 1;
        }

        /// Prevents procedure mutation before the service is mounted.
        pub fn seal(self: *Self) void {
            self.sealed = true;
        }

        /// Returns the service-owned scratch used by synchronous adapters.
        pub fn response_buffer(self: *Self) []u8 {
            return &self.response_storage;
        }

        /// Dispatches one JSON-RPC document into caller-owned storage.
        pub fn dispatch(
            self: *const Self,
            input: []const u8,
            output: []u8,
        ) DispatchError!?[]const u8 {
            var writer: std.Io.Writer = .fixed(output);
            dispatch_document(self, input, &writer) catch |err| switch (err) {
                error.WriteFailed => return error.ResponseTooLarge,
                else => {
                    writer.end = 0;
                    write_error(&writer, standard_error.parse_error, "Parse error", null) catch {
                        return error.ResponseTooLarge;
                    };
                },
            };
            if (writer.end == 0) return null;
            return writer.buffered();
        }

        fn method_at(self: *const Self, index: usize) []const u8 {
            const start: usize = self.method_offsets[index];
            return self.method_storage[start .. start + self.method_lengths[index]];
        }

        fn find(self: *const Self, method: []const u8) ?usize {
            var slot = hash_method(method) % table_capacity;
            for (0..table_capacity) |_| {
                const encoded_index = self.lookup_slots[slot];
                if (encoded_index == 0) return null;

                const index: usize = encoded_index - 1;
                if (std.mem.eql(u8, self.method_at(index), method)) return index;
                slot = (slot + 1) % table_capacity;
            }
            return null;
        }

        fn insert_lookup(self: *Self, method: []const u8, index: usize) void {
            var slot = hash_method(method) % table_capacity;
            while (self.lookup_slots[slot] != 0) slot = (slot + 1) % table_capacity;
            self.lookup_slots[slot] = @intCast(index + 1);
        }

        fn invoke(self: *const Self, index: usize, call: *Call) HandlerError!void {
            return switch (self.handler_kinds[index]) {
                .direct => self.handlers[index](call),
                .contextual => self.context_handlers[index](self.contexts[index].?, call),
            };
        }
    };
}

fn dispatch_document(service: anytype, input: []const u8, writer: *std.Io.Writer) !void {
    var scanner_scratch: [scanner_scratch_capacity]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scanner_scratch);
    var scanner = std.json.Scanner.initCompleteInput(scratch.allocator(), input);
    defer scanner.deinit();

    const document_type = try scanner.peekNextTokenType();
    switch (document_type) {
        .object_begin => {
            _ = try scanner.next();
            const request = try parse_request(&scanner, scratch.allocator(), input);
            try expect_document_end(&scanner);
            _ = try dispatch_request(service, request, writer);
        },
        .array_begin => {
            // Validate the complete document before application callbacks can run.
            try scanner.skipValue();
            try expect_document_end(&scanner);
            scanner.deinit();
            scratch.reset();
            scanner = std.json.Scanner.initCompleteInput(scratch.allocator(), input);
            try dispatch_batch(service, &scanner, scratch.allocator(), input, writer);
        },
        else => {
            try scanner.skipValue();
            try expect_document_end(&scanner);
            try write_error(writer, standard_error.invalid_request, "Invalid Request", null);
        },
    }
}

fn dispatch_batch(
    service: anytype,
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    input: []const u8,
    writer: *std.Io.Writer,
) !void {
    _ = try scanner.next();
    if (try scanner.peekNextTokenType() == .array_end) {
        _ = try scanner.next();
        try expect_document_end(scanner);
        return write_error(writer, standard_error.invalid_request, "Invalid Request", null);
    }

    const response_start = writer.end;
    try writer.writeByte('[');
    var response_count: usize = 0;

    while (try scanner.peekNextTokenType() != .array_end) {
        if (try scanner.peekNextTokenType() != .object_begin) {
            try scanner.skipValue();
            if (response_count != 0) try writer.writeByte(',');
            try write_error(writer, standard_error.invalid_request, "Invalid Request", null);
            response_count += 1;
            continue;
        }

        _ = try scanner.next();
        const request = try parse_request(scanner, allocator, input);
        if (!request.wants_response()) {
            _ = try dispatch_request(service, request, writer);
            continue;
        }

        if (response_count != 0) try writer.writeByte(',');
        _ = try dispatch_request(service, request, writer);
        response_count += 1;
    }
    _ = try scanner.next();
    try expect_document_end(scanner);

    if (response_count == 0) {
        writer.end = response_start;
        return;
    }
    try writer.writeByte(']');
}

fn dispatch_request(service: anytype, request: ParsedRequest, writer: *std.Io.Writer) !bool {
    if (!request.valid) {
        try write_error(writer, standard_error.invalid_request, "Invalid Request", null);
        return true;
    }

    const procedure_index = service.find(request.method) orelse {
        if (!request.wants_response()) return false;
        try write_error(writer, standard_error.method_not_found, "Method not found", request.id);
        return true;
    };

    const response_start = writer.end;
    if (request.wants_response()) {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"result\":");
    }
    var call = Call{
        .params = request.params,
        .writer = if (request.wants_response()) writer else null,
    };
    service.invoke(procedure_index, &call) catch |err| {
        if (!request.wants_response()) return false;
        writer.end = response_start;
        switch (err) {
            error.InvalidParams => try write_error(
                writer,
                standard_error.invalid_params,
                "Invalid params",
                request.id,
            ),
            error.ApplicationError => {
                const fault = call.fault orelse {
                    try write_error(
                        writer,
                        standard_error.internal_error,
                        "Internal error",
                        request.id,
                    );
                    return true;
                };
                try write_error(writer, fault.code, fault.message, request.id);
            },
            else => try write_error(
                writer,
                standard_error.internal_error,
                "Internal error",
                request.id,
            ),
        }
        return true;
    };

    if (!request.wants_response()) return false;
    if (!call.result_written) {
        writer.end = response_start;
        try write_error(writer, standard_error.internal_error, "Internal error", request.id);
        return true;
    }
    try writer.writeAll(",\"id\":");
    try writer.writeAll(request.id.?);
    try writer.writeByte('}');
    return true;
}

fn parse_request(
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    input: []const u8,
) !ParsedRequest {
    var request = ParsedRequest{};

    while (try scanner.peekNextTokenType() != .object_end) {
        if (try scanner.peekNextTokenType() != .string) return error.InvalidRequest;
        const member = try next_string(scanner, allocator, max_member_name_length);
        const value_type = try scanner.peekNextTokenType();
        const value_start = scanner.cursor;

        if (std.mem.eql(u8, member, "jsonrpc")) {
            if (request.has_version) request.valid = false;
            request.has_version = true;
            if (value_type != .string) {
                request.valid = false;
                try scanner.skipValue();
                continue;
            }
            const version = try next_string(scanner, allocator, 3);
            if (!std.mem.eql(u8, version, "2.0")) request.valid = false;
            continue;
        }

        if (std.mem.eql(u8, member, "method")) {
            if (request.has_method) request.valid = false;
            request.has_method = true;
            if (value_type != .string) {
                request.valid = false;
                try scanner.skipValue();
                continue;
            }
            request.method = try next_string(scanner, allocator, max_method_length);
            if (!valid_method_name(request.method)) request.valid = false;
            continue;
        }

        if (std.mem.eql(u8, member, "params")) {
            if (request.has_params) request.valid = false;
            request.has_params = true;
            if (value_type != .object_begin and value_type != .array_begin) {
                request.valid = false;
                try scanner.skipValue();
                continue;
            }
            try scanner.skipValue();
            request.params = input[value_start..scanner.cursor];
            continue;
        }

        if (std.mem.eql(u8, member, "id")) {
            if (request.has_id) request.valid = false;
            request.has_id = true;
            switch (value_type) {
                .string, .number, .null => {
                    try scanner.skipValue();
                    request.id = input[value_start..scanner.cursor];
                },
                else => {
                    request.valid = false;
                    try scanner.skipValue();
                },
            }
            continue;
        }

        try scanner.skipValue();
    }
    _ = try scanner.next();
    if (!request.has_version or !request.has_method) request.valid = false;
    return request;
}

fn next_string(
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    max_length: usize,
) ![]const u8 {
    return switch (try scanner.nextAllocMax(allocator, .alloc_if_needed, max_length)) {
        .string, .allocated_string => |value| value,
        else => error.InvalidRequest,
    };
}

fn expect_document_end(scanner: *std.json.Scanner) !void {
    switch (try scanner.next()) {
        .end_of_document => {},
        else => return error.InvalidRequest,
    }
}

fn write_error(
    writer: *std.Io.Writer,
    code: i32,
    message: []const u8,
    id: ?[]const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
    try writer.print("{d}", .{code});
    try writer.writeAll(",\"message\":");
    try writer.print("{f}", .{std.json.fmt(message, .{})});
    try writer.writeAll("},\"id\":");
    try writer.writeAll(id orelse "null");
    try writer.writeByte('}');
}

fn valid_method_name(method: []const u8) bool {
    if (method.len == 0 or method.len > max_method_length) return false;
    if (!std.unicode.utf8ValidateSlice(method)) return false;
    return !std.mem.startsWith(u8, method, "rpc.");
}

fn hash_method(method: []const u8) usize {
    var hash: u64 = 0xcbf29ce484222325;
    for (method) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return @truncate(hash);
}
