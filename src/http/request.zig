const std = @import("std");

// incoming HTTP/1.1 request, zero-allocation.
pub const Request = struct {
    method: []const u8 = "",
    path: []const u8 = "",

    header_names: [64][]const u8 = undefined,
    header_values: [64][]const u8 = undefined,
    header_count: usize = 0,

    // retrieves a header value by name.
    pub fn get_header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.header_names[0..self.header_count], 0..) |h_name, i| {
            if (std.ascii.eqlIgnoreCase(h_name, name)) return self.header_values[i];
        }
        return null;
    }
};
