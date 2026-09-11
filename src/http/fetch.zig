//! Fetch-inspired helper primitives.
//!
//! Provides header and status utilities tailored for
//! zero-allocation, high-throughput network applications.

const std = @import("std");

/// One header key-value entry.
pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Iterator over parallel borrowed HTTP header slices.
pub const HeaderIterator = struct {
    names: []const []const u8,
    values: []const []const u8,
    extra_names: []const []const u8 = &.{},
    extra_values: []const []const u8 = &.{},
    index: usize = 0,

    pub fn next(self: *HeaderIterator) ?HeaderEntry {
        const primary_count = @min(self.names.len, self.values.len);
        if (self.index < primary_count) {
            const entry = HeaderEntry{
                .name = self.names[self.index],
                .value = self.values[self.index],
            };
            self.index += 1;
            return entry;
        }
        const extra_index = self.index - primary_count;
        const extra_count = @min(self.extra_names.len, self.extra_values.len);
        if (extra_index >= extra_count) return null;
        const entry = HeaderEntry{
            .name = self.extra_names[extra_index],
            .value = self.extra_values[extra_index],
        };
        self.index += 1;
        return entry;
    }

    pub fn reset(self: *HeaderIterator) void {
        self.index = 0;
    }
};

/// Read-only view over borrowed contiguous header slices.
pub const HeadersView = struct {
    names: []const []const u8,
    values: []const []const u8,
    extra_names: []const []const u8 = &.{},
    extra_values: []const []const u8 = &.{},

    pub fn init(names: []const []const u8, values: []const []const u8) HeadersView {
        const count = @min(names.len, values.len);
        return .{ .names = names[0..count], .values = values[0..count] };
    }

    pub fn init_with_extra(
        names: []const []const u8,
        values: []const []const u8,
        extra_names: []const []const u8,
        extra_values: []const []const u8,
    ) HeadersView {
        const count = @min(names.len, values.len);
        const extra_count = @min(extra_names.len, extra_values.len);
        return .{
            .names = names[0..count],
            .values = values[0..count],
            .extra_names = extra_names[0..extra_count],
            .extra_values = extra_values[0..extra_count],
        };
    }

    /// Returns the first value matching `name` case-insensitively.
    pub fn get(self: HeadersView, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |h_name, h_val| {
            if (std.ascii.eqlIgnoreCase(h_name, name)) return h_val;
        }
        for (self.extra_names, self.extra_values) |h_name, h_val| {
            if (std.ascii.eqlIgnoreCase(h_name, name)) return h_val;
        }
        return null;
    }

    /// Reports whether a header matching `name` exists case-insensitively.
    pub fn has(self: HeadersView, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Returns an iterator over all [name, value] entries.
    pub fn entries(self: HeadersView) HeaderIterator {
        return .{
            .names = self.names,
            .values = self.values,
            .extra_names = self.extra_names,
            .extra_values = self.extra_values,
        };
    }
};

/// Reports whether an HTTP status code represents a successful response (200..299).
pub fn is_ok(code: u16) bool {
    return code >= 200 and code < 300;
}

/// Reports whether an HTTP status code represents a redirect (300..399).
pub fn is_redirect(code: u16) bool {
    return code >= 300 and code < 400;
}

/// Reports whether an HTTP status code represents a client error (400..499).
pub fn is_client_error(code: u16) bool {
    return code >= 400 and code < 500;
}

/// Reports whether an HTTP status code represents a server error (500..599).
pub fn is_server_error(code: u16) bool {
    return code >= 500 and code < 600;
}
