const std = @import("std");
const request_module = @import("request.zig");
const fetch = @import("fetch.zig");
const query_module = @import("query.zig");
const multipart_module = @import("multipart.zig");
const schema_module = @import("schema.zig");

/// A streaming sink cannot access a complete buffered body.
pub const BodyReadError = error{BodyNotBuffered};

/// Callback-borrowed route captures; names remain case-sensitive.
pub const RouteParamsView = struct {
    names: []const []const u8,
    values: []const []const u8,
    extra_names: []const []const u8 = &.{},
    extra_values: []const []const u8 = &.{},

    pub fn get(self: RouteParamsView, name: []const u8) ?[]const u8 {
        const count = @min(self.names.len, self.values.len);
        for (self.names[0..count], self.values[0..count]) |candidate, value| {
            if (std.mem.eql(u8, candidate, name)) return value;
        }
        const extra_count = @min(self.extra_names.len, self.extra_values.len);
        for (self.extra_names[0..extra_count], self.extra_values[0..extra_count]) |candidate, value| {
            if (std.mem.eql(u8, candidate, name)) return value;
        }
        return null;
    }
};

/// Metadata-only sink view; its pointer and array views last for one callback.
/// Individual pinned byte slices may have the owner's longer response lifetime.
pub const StreamingRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    protocol: []const u8,
    query: []const u8,
    headers: fetch.HeadersView,
    params: RouteParamsView,

    /// Projects pinned metadata without copying arrays or retaining Request.
    pub fn from_request(request: *const request_module.Request) StreamingRequest {
        const count = @min(request.route_param_count, request_module.max_route_params);
        const extra_names = request.extra_param_names orelse &.{};
        const extra_values = request.extra_param_values orelse &.{};
        const extra_count = @min(request.extra_param_count, @min(extra_names.len, extra_values.len));
        return .{
            .method = request.method,
            .target = request.target,
            .path = request.path,
            .protocol = request.protocol,
            .query = request.query,
            .headers = request.headers(),
            .params = .{
                .names = request.route_param_names[0..count],
                .values = request.route_param_values[0..count],
                .extra_names = extra_names[0..extra_count],
                .extra_values = extra_values[0..extra_count],
            },
        };
    }

    pub fn text(_: *const StreamingRequest) []const u8 {
        return "";
    }

    pub fn bytes(_: *const StreamingRequest) []const u8 {
        return "";
    }

    pub fn json(_: *const StreamingRequest, comptime T: type, _: std.mem.Allocator) BodyReadError!std.json.Parsed(T) {
        return error.BodyNotBuffered;
    }

    pub fn validate_json(_: *const StreamingRequest, comptime T: type, _: std.mem.Allocator) BodyReadError!std.json.Parsed(T) {
        return error.BodyNotBuffered;
    }

    pub fn validate_json_detailed(_: *const StreamingRequest, comptime T: type, _: std.mem.Allocator, _: *schema_module.Issue) BodyReadError!std.json.Parsed(T) {
        return error.BodyNotBuffered;
    }

    pub fn form(_: *const StreamingRequest) BodyReadError!query_module.QueryParams {
        return error.BodyNotBuffered;
    }

    pub fn multipart(_: *const StreamingRequest) BodyReadError!multipart_module.Parser {
        return error.BodyNotBuffered;
    }

    pub fn query_params(self: *const StreamingRequest) !query_module.QueryParams {
        return query_module.QueryParams.parse_link(self.target);
    }

    pub fn query_params_of(self: *const StreamingRequest, comptime capacity: usize) !query_module.QueryParamsOf(capacity) {
        return query_module.QueryParamsOf(capacity).parse_link(self.target);
    }

    /// Owns metadata only; body input and transport/control pointers never copy.
    pub fn clone(self: *const StreamingRequest, allocator: std.mem.Allocator) !OwnedStreamingRequest {
        const header_count = try pair_count(self.headers.names, self.headers.values, self.headers.extra_names, self.headers.extra_values);
        const param_count = try pair_count(self.params.names, self.params.values, self.params.extra_names, self.params.extra_values);
        var byte_count: usize = 0;
        for ([_][]const u8{ self.method, self.target, self.path, self.protocol, self.query }) |slice| {
            byte_count = try add_slice_size(byte_count, slice);
        }
        var entries = self.headers.entries();
        while (entries.next()) |entry| {
            byte_count = try add_slice_size(byte_count, entry.name);
            byte_count = try add_slice_size(byte_count, entry.value);
        }
        for (0..param_count) |index| {
            const entry = capture_entry(self.params, index);
            byte_count = try add_slice_size(byte_count, entry.name);
            byte_count = try add_slice_size(byte_count, entry.value);
        }
        const storage = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(storage);
        const header_names = try allocator.alloc([]const u8, header_count);
        errdefer allocator.free(header_names);
        const header_values = try allocator.alloc([]const u8, header_count);
        errdefer allocator.free(header_values);
        const param_names = try allocator.alloc([]const u8, param_count);
        errdefer allocator.free(param_names);
        const param_values = try allocator.alloc([]const u8, param_count);
        errdefer allocator.free(param_values);

        var cursor: usize = 0;
        const method = copy_slice(storage, &cursor, self.method);
        const target = copy_slice(storage, &cursor, self.target);
        const path = copy_slice(storage, &cursor, self.path);
        const protocol = copy_slice(storage, &cursor, self.protocol);
        const query = copy_slice(storage, &cursor, self.query);
        entries = self.headers.entries();
        var header_index: usize = 0;
        while (entries.next()) |entry| : (header_index += 1) {
            header_names[header_index] = copy_slice(storage, &cursor, entry.name);
            header_values[header_index] = copy_slice(storage, &cursor, entry.value);
        }
        for (0..param_count) |index| {
            const entry = capture_entry(self.params, index);
            param_names[index] = copy_slice(storage, &cursor, entry.name);
            param_values[index] = copy_slice(storage, &cursor, entry.value);
        }
        return .{
            .allocator = allocator,
            .storage = storage,
            .header_names = header_names,
            .header_values = header_values,
            .param_names = param_names,
            .param_values = param_values,
            .method = method,
            .target = target,
            .path = path,
            .protocol = protocol,
            .query = query,
        };
    }
};

/// Flat owned metadata; view derives array borrows after the owner has moved.
pub const OwnedStreamingRequest = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    header_names: [][]const u8,
    header_values: [][]const u8,
    param_names: [][]const u8,
    param_values: [][]const u8,
    method: []const u8,
    target: []const u8,
    path: []const u8,
    protocol: []const u8,
    query: []const u8,

    pub fn view(self: *const OwnedStreamingRequest) StreamingRequest {
        return .{
            .method = self.method,
            .target = self.target,
            .path = self.path,
            .protocol = self.protocol,
            .query = self.query,
            .headers = fetch.HeadersView.init(self.header_names, self.header_values),
            .params = .{ .names = self.param_names, .values = self.param_values },
        };
    }

    pub fn deinit(self: *OwnedStreamingRequest) void {
        self.allocator.free(self.param_values);
        self.allocator.free(self.param_names);
        self.allocator.free(self.header_values);
        self.allocator.free(self.header_names);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

fn pair_count(names: []const []const u8, values: []const []const u8, extra_names: []const []const u8, extra_values: []const []const u8) !usize {
    return std.math.add(usize, @min(names.len, values.len), @min(extra_names.len, extra_values.len)) catch error.StreamingRequestSnapshotTooLarge;
}

/// Keeps each bounded capture name paired with its corresponding value.
const CaptureEntry = struct { name: []const u8, value: []const u8 };

fn capture_entry(params: RouteParamsView, index: usize) CaptureEntry {
    const primary_count = @min(params.names.len, params.values.len);
    if (index < primary_count) return .{ .name = params.names[index], .value = params.values[index] };
    const extra_index = index - primary_count;
    return .{ .name = params.extra_names[extra_index], .value = params.extra_values[extra_index] };
}

fn add_slice_size(total: usize, value: []const u8) !usize {
    return std.math.add(usize, total, value.len) catch error.StreamingRequestSnapshotTooLarge;
}

fn copy_slice(storage: []u8, cursor: *usize, input: []const u8) []const u8 {
    const output = storage[cursor.*..][0..input.len];
    @memcpy(output, input);
    cursor.* += input.len;
    return output;
}
