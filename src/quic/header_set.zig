//! Bounded decoded field sections and their borrowed storage lifetime.

const std = @import("std");
const c = @import("c");
const Request = @import("../http/request.zig").Request;
const validation = @import("validation.zig");
const stream_capacities = @import("stream_capacities.zig");
const Capacities = stream_capacities.Capacities;
const default_capacities = stream_capacities.default_capacities;

/// Returns a header set to the owner that lent it storage.
const HeaderReleaseFn = *const fn (*anyopaque, *HeaderSet) void;

/// Bounded lsquic header decoder state for one HTTP/3 request.
pub const HeaderSet = struct {
    owner: *anyopaque = undefined,
    release_fn: ?HeaderReleaseFn = null,
    storage: []u8 = &.{},
    /// Per-stream capacities the engine specialized the owning stream with.
    capacities: Capacities = default_capacities,
    decoded: c.struct_uz_lsxpack_header = std.mem.zeroes(c.struct_uz_lsxpack_header),
    request: Request = .{},
    method: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    content_length: ?usize = null,
    write_offset: usize = 0,
    /// Regular fields accepted from this field section so far.
    decoded_field_count: usize = 0,
    regular_headers_seen: bool = false,
    host_seen: bool = false,
    is_trailer: bool = false,
    finished: bool = false,
    claimed: bool = false,

    /// Reinitializes the header set with borrowed owner, decode storage, and
    /// engine-provided request-field capacity slices.
    ///
    /// `header_extra_names` and `header_extra_values` are equal-length
    /// caller-owned capacity slices; pass empty slices when the inline
    /// `Request` arrays must cover every accepted field.
    pub fn reset(
        self: *HeaderSet,
        owner: *anyopaque,
        release_fn: HeaderReleaseFn,
        storage: []u8,
        header_extra_names: [][]const u8,
        header_extra_values: [][]const u8,
        capacities: Capacities,
    ) void {
        self.* = .{
            .owner = owner,
            .release_fn = release_fn,
            .storage = storage,
            .capacities = capacities,
        };
        self.request.extra_header_names = header_extra_names;
        self.request.extra_header_values = header_extra_values;
        self.request.extra_header_count = 0;
    }

    /// Reinitializes the header set for a trailing field section.
    pub fn reset_trailer(
        self: *HeaderSet,
        owner: *anyopaque,
        release_fn: HeaderReleaseFn,
        storage: []u8,
        header_extra_names: [][]const u8,
        header_extra_values: [][]const u8,
        capacities: Capacities,
    ) void {
        self.reset(
            owner,
            release_fn,
            storage,
            header_extra_names,
            header_extra_values,
            capacities,
        );
        self.is_trailer = true;
    }

    /// Prepares inline storage for one lsquic-decoded field.
    pub fn prepare_decode(
        self: *HeaderSet,
        existing: ?*c.lsxpack_header,
        required: usize,
    ) ?*c.lsxpack_header {
        if (self.finished or required > self.storage.len -| self.write_offset) return null;
        if (existing) |header| {
            if (@intFromPtr(header) != @intFromPtr(&self.decoded)) return null;
            self.decoded.val_len = @intCast(self.storage.len - self.write_offset);
            return @ptrCast(&self.decoded);
        }

        self.decoded = std.mem.zeroes(c.struct_uz_lsxpack_header);
        self.decoded.buf = @ptrCast(self.storage.ptr);
        self.decoded.name_offset = @intCast(self.write_offset);
        self.decoded.val_len = @intCast(self.storage.len - self.write_offset);
        return @ptrCast(&self.decoded);
    }

    /// Validates and records a decoded field, or finalizes on null.
    pub fn process_header(self: *HeaderSet, decoded: ?*c.lsxpack_header) bool {
        const raw_header = decoded orelse return self.finish();
        if (@intFromPtr(raw_header) != @intFromPtr(&self.decoded)) return false;
        const header: *c.struct_uz_lsxpack_header = @ptrCast(@alignCast(raw_header));
        if (header.buf == null) return false;
        if (@intFromPtr(header.buf) != @intFromPtr(self.storage.ptr)) return false;
        if (header.name_offset < 0 or header.val_offset < 0) return false;

        const name_offset: usize = @intCast(header.name_offset);
        const value_offset: usize = @intCast(header.val_offset);
        const name_length: usize = @intCast(header.name_len);
        const value_length: usize = @intCast(header.val_len);
        const name_end = std.math.add(usize, name_offset, name_length) catch return false;
        const value_end = std.math.add(usize, value_offset, value_length) catch return false;
        const next_offset = @max(name_end, value_end);
        if (name_offset < self.write_offset or value_offset < self.write_offset) return false;
        if (next_offset > self.storage.len or name_length == 0) return false;

        const name = self.storage[name_offset..name_end];
        const value = self.storage[value_offset..value_end];
        if (!validation.valid_header_value(value)) return false;

        const accepted = if (name[0] == ':')
            self.process_pseudo_header(name, value)
        else
            self.process_regular_header(name, value);
        if (!accepted) return false;

        self.write_offset = next_offset;
        return true;
    }

    /// Returns this header set to its owner at most once.
    pub fn release(self: *HeaderSet) void {
        const callback = self.release_fn orelse return;
        self.release_fn = null;
        callback(self.owner, self);
    }

    fn process_pseudo_header(self: *HeaderSet, name: []const u8, value: []const u8) bool {
        if (self.is_trailer or self.regular_headers_seen) return false;

        if (std.mem.eql(u8, name, ":method")) {
            if (self.method != null or !validation.valid_method(value)) return false;
            self.method = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":scheme")) {
            if (self.scheme != null or !std.mem.eql(u8, value, "https")) return false;
            self.scheme = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":authority")) {
            if (self.authority != null or !validation.valid_authority(value)) return false;
            self.authority = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":path")) {
            if (self.path != null or !validation.valid_target(value)) return false;
            self.path = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":protocol")) {
            if (self.protocol != null or !validation.valid_method(value)) return false;
            self.protocol = value;
            return true;
        }
        return false;
    }

    fn process_regular_header(self: *HeaderSet, name: []const u8, value: []const u8) bool {
        if (!validation.valid_http3_name(name)) return false;
        if (validation.connection_specific_header(name)) return false;
        if (self.is_trailer and forbidden_trailer_field(name)) return false;
        if (std.mem.eql(u8, name, "te") and !std.ascii.eqlIgnoreCase(value, "trailers")) {
            return false;
        }

        if (std.mem.eql(u8, name, "content-length")) {
            if (self.content_length != null) return false;
            self.content_length = validation.parse_decimal(value) orelse return false;
        }
        if (std.mem.eql(u8, name, "host")) {
            if (self.host_seen or !validation.valid_authority(value)) return false;
            self.host_seen = true;
            if (self.authority) |authority| {
                if (!std.ascii.eqlIgnoreCase(authority, value)) return false;
            }
        }

        if (self.decoded_field_count >= self.capacities.decoded_header_count) return false;
        // Both inline and engine-provided slots are exhausted past capacity;
        // either way the field section fails closed on this stream.
        self.request.add_header(name, value) catch return false;
        self.decoded_field_count += 1;
        self.regular_headers_seen = true;
        return true;
    }

    fn finish(self: *HeaderSet) bool {
        if (self.finished) return false;
        if (self.is_trailer) {
            self.finished = true;
            return true;
        }
        const method = self.method orelse return false;
        const is_connect = std.mem.eql(u8, method, "CONNECT");
        // RFC 9220 defines :protocol only for extended CONNECT requests.
        if (self.protocol != null and !is_connect) return false;
        const target = if (is_connect) blk: {
            if (self.protocol != null) {
                _ = self.scheme orelse return false;
                const path = self.path orelse return false;
                // Extended CONNECT keeps the authority-form target and so
                // requires :authority (RFC 8441 section 4).
                _ = self.authority orelse return false;
                break :blk path;
            }
            if (self.scheme != null or self.path != null) return false;
            break :blk self.authority orelse return false;
        } else blk: {
            _ = self.scheme orelse return false;
            const path = self.path orelse return false;
            if (std.mem.eql(u8, path, "*") and !std.mem.eql(u8, method, "OPTIONS")) {
                return false;
            }
            break :blk path;
        };

        if (!self.host_seen) {
            const authority = self.authority orelse return false;
            self.request.add_header("host", authority) catch return false;
        }

        self.request.method = method;
        self.request.target = target;
        if (is_connect and self.protocol == null) {
            self.request.path = "";
            self.request.query = "";
            self.finished = true;
            return true;
        }
        if (std.mem.indexOfScalar(u8, target, '?')) |query_start| {
            self.request.path = target[0..query_start];
            self.request.query = target[query_start + 1 ..];
        } else {
            self.request.path = target;
            self.request.query = "";
        }
        self.finished = true;
        return true;
    }
};

fn forbidden_trailer_field(name: []const u8) bool {
    return std.mem.eql(u8, name, "content-length") or
        std.mem.eql(u8, name, "host") or
        std.mem.eql(u8, name, "te") or
        std.mem.eql(u8, name, "trailer") or
        std.mem.eql(u8, name, "transfer-encoding");
}
