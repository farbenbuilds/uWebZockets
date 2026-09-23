const std = @import("std");
const AbortSignal = @import("../http/abort.zig").AbortSignal;

pub const default_max_procedures = 64;
pub const default_method_storage_capacity = 4096;
pub const default_response_capacity = 16 * 1024;
pub const max_method_length = 255;
pub const max_member_name_length = 255;
pub const scanner_scratch_capacity = 2048;
pub const typed_params_scratch_capacity = 4096;
pub const min_response_capacity = 128;

pub const StandardError = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

pub const HandlerError = error{
    Aborted,
    ApplicationError,
    InternalError,
    InvalidParams,
    OutOfMemory,
    ResultAlreadyWritten,
    ResultTooLarge,
};

pub const DispatchError = error{ Aborted, ResponseTooLarge };

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
    abort_signal: ?AbortSignal = null,
    fault: ?Fault = null,
    result_written: bool = false,

    /// Cooperatively stops work when the request, timeout, or socket is gone.
    pub fn checkpoint(self: *const Call) HandlerError!void {
        const signal = self.abort_signal orelse return;
        signal.checkpoint() catch return error.Aborted;
    }

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
    ///
    /// `value` accepts any value that `std.json.fmt` can serialize.
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

pub const StaticProcedure = struct {
    method: []const u8,
    handler: Handler,
};

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

/// Generates a collision-free O(1) RPC jump table at comptime.
///
/// Runtime dispatch hashes once and compares the 64-bit fingerprint, avoiding
/// string scans and registration-time mutation.
pub fn comptime_service(comptime procedures: []const StaticProcedure) type {
    if (procedures.len == 0) @compileError("RPC procedure list cannot be empty");
    if (procedures.len >= std.math.maxInt(u16)) @compileError("RPC procedure list is too large");
    @setEvalBranchQuota(1_000_000);

    const table_capacity = static_table_capacity(procedures.len);
    const seed = find_perfect_seed(procedures, table_capacity);
    const table = make_static_table(procedures, table_capacity, seed);
    const hashes = make_static_hashes(procedures, seed);

    return struct {
        const Self = @This();

        response_storage: [default_response_capacity]u8 = undefined,

        pub fn response_buffer(self: *Self) []u8 {
            return &self.response_storage;
        }

        pub fn dispatch(
            self: *const Self,
            input: []const u8,
            output: []u8,
        ) DispatchError!?[]const u8 {
            return dispatch_to_buffer(self, input, output, null);
        }

        pub fn dispatch_with_signal(
            self: *const Self,
            signal: AbortSignal,
            input: []const u8,
            output: []u8,
        ) DispatchError!?[]const u8 {
            return dispatch_to_buffer(self, input, output, signal);
        }

        fn find(_: *const Self, method: []const u8) ?usize {
            const fingerprint = hash_method_seeded(method, seed);
            const encoded_index = table[fingerprint % table_capacity];
            if (encoded_index == 0) return null;
            const index: usize = encoded_index - 1;
            if (hashes[index] != fingerprint) return null;
            // FNV-1a is a bijection per byte, so a crafted method can collide
            // with a registered fingerprint; confirm the stored bytes too.
            if (!std.mem.eql(u8, procedures[index].method, method)) return null;
            return index;
        }

        fn invoke(_: *const Self, index: usize, call: *Call) HandlerError!void {
            return procedures[index].handler(call);
        }
    };
}

/// Returns `P` when it is a mutable single-item pointer, else fails compilation.
fn mutable_context_pointer(comptime P: type) type {
    const pointer = switch (@typeInfo(P)) {
        .pointer => |info| info,
        else => @compileError("typed RPC context must be passed by mutable pointer"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("typed RPC context must be passed by mutable single-item pointer");
    }
    return P;
}

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
        ///
        /// `context` accepts any mutable single-item pointer to caller-owned
        /// state that outlives the service.
        pub fn register_typed_context(
            self: *Self,
            method: []const u8,
            context: anytype,
            comptime Params: type,
            comptime Result: type,
            comptime handler: *const fn (@TypeOf(context), Params) HandlerError!Result,
        ) RegistrationError!void {
            const Pointer = mutable_context_pointer(@TypeOf(context));

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
            return dispatch_to_buffer(self, input, output, null);
        }

        pub fn dispatch_with_signal(
            self: *const Self,
            signal: AbortSignal,
            input: []const u8,
            output: []u8,
        ) DispatchError!?[]const u8 {
            return dispatch_to_buffer(self, input, output, signal);
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

/// Dispatches one document; `service` accepts any generated service type.
fn dispatch_to_buffer(
    service: anytype,
    input: []const u8,
    output: []u8,
    signal: ?AbortSignal,
) DispatchError!?[]const u8 {
    if (signal) |value| value.checkpoint() catch return error.Aborted;
    var writer: std.Io.Writer = .fixed(output);
    dispatch_document(service, input, &writer, signal) catch |err| switch (err) {
        error.Aborted => return error.Aborted,
        error.WriteFailed => return error.ResponseTooLarge,
        else => {
            writer.end = 0;
            write_error(&writer, StandardError.parse_error, "Parse error", null) catch {
                return error.ResponseTooLarge;
            };
        },
    };
    if (writer.end == 0) return null;
    return writer.buffered();
}

fn static_table_capacity(procedure_count: usize) usize {
    var capacity: usize = 2;
    while (capacity < procedure_count * 2) capacity *= 2;
    return capacity;
}

fn find_perfect_seed(
    comptime procedures: []const StaticProcedure,
    comptime table_capacity: usize,
) u64 {
    for (procedures, 0..) |procedure, index| {
        if (!valid_method_name(procedure.method)) @compileError("invalid static RPC method name");
        for (procedures[0..index]) |previous| {
            if (std.mem.eql(u8, previous.method, procedure.method)) {
                @compileError("duplicate static RPC method name");
            }
        }
    }

    var seed: u64 = 0;
    while (seed < 100_000) : (seed += 1) {
        var occupied = [_]bool{false} ** table_capacity;
        var collision = false;
        for (procedures) |procedure| {
            const slot = hash_method_seeded(procedure.method, seed) % table_capacity;
            if (occupied[slot]) {
                collision = true;
                break;
            }
            occupied[slot] = true;
        }
        if (!collision) return seed;
    }
    @compileError("unable to generate a perfect RPC hash table");
}

fn make_static_table(
    comptime procedures: []const StaticProcedure,
    comptime table_capacity: usize,
    comptime seed: u64,
) [table_capacity]u16 {
    var table = [_]u16{0} ** table_capacity;
    for (procedures, 0..) |procedure, index| {
        const slot = hash_method_seeded(procedure.method, seed) % table_capacity;
        table[slot] = @intCast(index + 1);
    }
    return table;
}

fn make_static_hashes(
    comptime procedures: []const StaticProcedure,
    comptime seed: u64,
) [procedures.len]u64 {
    var hashes: [procedures.len]u64 = undefined;
    for (procedures, 0..) |procedure, index| {
        hashes[index] = hash_method_seeded(procedure.method, seed);
    }
    return hashes;
}

/// Classifies and dispatches one document; `service` accepts any generated service type.
fn dispatch_document(
    service: anytype,
    input: []const u8,
    writer: *std.Io.Writer,
    signal: ?AbortSignal,
) !void {
    if (signal) |value| try value.checkpoint();
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
            _ = try dispatch_request(service, request, writer, signal);
        },
        .array_begin => {
            // Validate the complete document before application callbacks can run.
            try scanner.skipValue();
            try expect_document_end(&scanner);
            scanner.deinit();
            scratch.reset();
            scanner = std.json.Scanner.initCompleteInput(scratch.allocator(), input);
            try dispatch_batch(service, &scanner, scratch.allocator(), input, writer, signal);
        },
        else => {
            try scanner.skipValue();
            try expect_document_end(&scanner);
            try write_error(writer, StandardError.invalid_request, "Invalid Request", null);
        },
    }
}

/// Dispatches a pre-validated batch; `service` accepts any generated service type.
fn dispatch_batch(
    service: anytype,
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    input: []const u8,
    writer: *std.Io.Writer,
    signal: ?AbortSignal,
) !void {
    _ = try scanner.next();
    if (try scanner.peekNextTokenType() == .array_end) {
        _ = try scanner.next();
        try expect_document_end(scanner);
        return write_error(writer, StandardError.invalid_request, "Invalid Request", null);
    }

    const response_start = writer.end;
    try writer.writeByte('[');
    var response_count: usize = 0;

    while (try scanner.peekNextTokenType() != .array_end) {
        if (signal) |value| try value.checkpoint();
        if (try scanner.peekNextTokenType() != .object_begin) {
            try scanner.skipValue();
            if (response_count != 0) try writer.writeByte(',');
            try write_error(writer, StandardError.invalid_request, "Invalid Request", null);
            response_count += 1;
            continue;
        }

        _ = try scanner.next();
        const request = try parse_request(scanner, allocator, input);
        if (!request.wants_response()) {
            _ = try dispatch_request(service, request, writer, signal);
            continue;
        }

        if (response_count != 0) try writer.writeByte(',');
        _ = try dispatch_request(service, request, writer, signal);
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

/// Dispatches one request; `service` accepts any generated service type.
fn dispatch_request(
    service: anytype,
    request: ParsedRequest,
    writer: *std.Io.Writer,
    signal: ?AbortSignal,
) !bool {
    if (signal) |value| try value.checkpoint();
    if (!request.valid) {
        try write_error(writer, StandardError.invalid_request, "Invalid Request", null);
        return true;
    }

    const procedure_index = service.find(request.method) orelse {
        if (!request.wants_response()) return false;
        try write_error(writer, StandardError.method_not_found, "Method not found", request.id);
        return true;
    };

    const response_start = writer.end;
    if (request.wants_response()) {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"result\":");
    }
    var call = Call{
        .params = request.params,
        .writer = if (request.wants_response()) writer else null,
        .abort_signal = signal,
    };
    service.invoke(procedure_index, &call) catch |err| {
        if (err == error.Aborted) return error.Aborted;
        if (!request.wants_response()) return false;
        writer.end = response_start;
        switch (err) {
            error.InvalidParams => try write_error(
                writer,
                StandardError.invalid_params,
                "Invalid params",
                request.id,
            ),
            error.ApplicationError => {
                const fault = call.fault orelse {
                    try write_error(
                        writer,
                        StandardError.internal_error,
                        "Internal error",
                        request.id,
                    );
                    return true;
                };
                try write_error(writer, fault.code, fault.message, request.id);
            },
            else => try write_error(
                writer,
                StandardError.internal_error,
                "Internal error",
                request.id,
            ),
        }
        return true;
    };

    if (!request.wants_response()) return false;
    if (!call.result_written) {
        writer.end = response_start;
        try write_error(writer, StandardError.internal_error, "Internal error", request.id);
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
    return @truncate(hash_method_seeded(method, 0));
}

fn hash_method_seeded(method: []const u8, seed: u64) u64 {
    var hash: u64 = 0xcbf29ce484222325 ^ seed;
    hash ^= method.len;
    hash *%= 0x100000001b3;
    for (method) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}
