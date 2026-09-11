//! WHATWG Fetch Standard (https://fetch.spec.whatwg.org/) helper primitives.
//!
//! Provides Web-Standard Headers, Body, and Response utilities tailored for
//! zero-allocation, high-throughput network applications.

const std = @import("std");

/// One header key-value entry.
pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Iterator over a slice of HTTP headers adhering to Web Standard Headers entries.
pub const HeaderIterator = struct {
    names: []const []const u8,
    values: []const []const u8,
    index: usize = 0,

    pub fn next(self: *HeaderIterator) ?HeaderEntry {
        if (self.index >= self.names.len) return null;
        const entry = HeaderEntry{
            .name = self.names[self.index],
            .value = self.values[self.index],
        };
        self.index += 1;
        return entry;
    }

    pub fn reset(self: *HeaderIterator) void {
        self.index = 0;
    }
};

/// Web-Standard Headers view over borrowed contiguous header slices.
pub const HeadersView = struct {
    names: []const []const u8,
    values: []const []const u8,

    pub fn init(names: []const []const u8, values: []const []const u8) HeadersView {
        std.debug.assert(names.len == values.len);
        return .{ .names = names, .values = values };
    }

    /// Returns the first value matching `name` case-insensitively.
    pub fn get(self: HeadersView, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |h_name, h_val| {
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
        return .{ .names = self.names, .values = self.values };
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
