const std = @import("std");

/// Maximum number of allocation-free route parameters on one request.
pub const max_route_params = 16;

/// Incoming HTTP request with fixed-capacity headers and route parameters.
pub const Request = struct {
    /// Uppercase request method token.
    method: []const u8 = "",
    /// Original request target, including a query when present.
    target: []const u8 = "",
    /// Request path without its query.
    path: []const u8 = "",
    /// Query bytes without the leading question mark.
    query: []const u8 = "",
    /// Complete bounded request body.
    body: []const u8 = "",

    header_names: [64][]const u8 = undefined,
    header_values: [64][]const u8 = undefined,
    header_count: usize = 0,

    route_param_names: [max_route_params][]const u8 = undefined,
    route_param_values: [max_route_params][]const u8 = undefined,
    route_param_count: usize = 0,

    /// Returns the first field value matching `name` case-insensitively.
    pub fn get_header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.header_names[0..self.header_count], 0..) |h_name, i| {
            if (std.ascii.eqlIgnoreCase(h_name, name)) return self.header_values[i];
        }
        return null;
    }

    /// Returns a field only when it occurs exactly once.
    pub fn get_unique_header(self: *const Request, name: []const u8) ?[]const u8 {
        var value: ?[]const u8 = null;

        for (self.header_names[0..self.header_count], self.header_values[0..self.header_count]) |header_name, header_value| {
            if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
            if (value != null) return null;
            value = header_value;
        }
        return value;
    }

    /// Counts fields matching `name` case-insensitively.
    pub fn count_headers(self: *const Request, name: []const u8) usize {
        var count: usize = 0;
        for (self.header_names[0..self.header_count]) |header_name| {
            if (std.ascii.eqlIgnoreCase(header_name, name)) count += 1;
        }
        return count;
    }

    /// Reports whether a comma-delimited field contains `token`.
    pub fn header_has_token(self: *const Request, name: []const u8, token: []const u8) bool {
        for (self.header_names[0..self.header_count], self.header_values[0..self.header_count]) |header_name, value| {
            if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;

            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |candidate| {
                const trimmed = std.mem.trim(u8, candidate, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
            }
        }
        return false;
    }

    /// Validates the mandatory RFC 10008 media type for a QUERY request.
    pub fn valid_query_content_type(self: *const Request) bool {
        if (!std.mem.eql(u8, self.method, "QUERY")) return true;
        const value = self.get_unique_header("content-type") orelse return false;
        return valid_media_type(value);
    }

    /// Returns a captured `:name` or terminal `*name` route parameter.
    pub fn get_param(self: *const Request, name: []const u8) ?[]const u8 {
        for (
            self.route_param_names[0..self.route_param_count],
            self.route_param_values[0..self.route_param_count],
        ) |param_name, value| {
            if (std.mem.eql(u8, param_name, name)) return value;
        }
        return null;
    }

    /// Clears route captures before a new router lookup.
    pub fn clear_params(self: *Request) void {
        self.route_param_count = 0;
    }

    /// Appends one borrowed route capture when fixed capacity remains.
    pub fn add_param(self: *Request, name: []const u8, value: []const u8) !void {
        if (self.route_param_count == max_route_params) return error.RouteParameterCapacityReached;
        self.route_param_names[self.route_param_count] = name;
        self.route_param_values[self.route_param_count] = value;
        self.route_param_count += 1;
    }
};

fn valid_media_type(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    var index: usize = 0;
    if (!consume_token(trimmed, &index)) return false;
    if (index == trimmed.len or trimmed[index] != '/') return false;

    index += 1;
    if (!consume_token(trimmed, &index)) return false;
    skip_optional_whitespace(trimmed, &index);

    while (index < trimmed.len) {
        if (trimmed[index] != ';') return false;
        index += 1;
        skip_optional_whitespace(trimmed, &index);
        if (!consume_token(trimmed, &index)) return false;
        skip_optional_whitespace(trimmed, &index);
        if (index == trimmed.len or trimmed[index] != '=') return false;

        index += 1;
        skip_optional_whitespace(trimmed, &index);
        if (!consume_parameter_value(trimmed, &index)) return false;
        skip_optional_whitespace(trimmed, &index);
    }
    return true;
}

fn consume_token(value: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < value.len) : (index.* += 1) {
        const byte = value[index.*];
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => break,
        }
    }
    return index.* != start;
}

fn consume_parameter_value(value: []const u8, index: *usize) bool {
    if (index.* == value.len) return false;
    if (value[index.*] != '"') return consume_token(value, index);

    index.* += 1;
    while (index.* < value.len) {
        const byte = value[index.*];
        index.* += 1;
        if (byte == '"') return true;
        if (byte == '\\') {
            if (index.* == value.len or !valid_quoted_pair(value[index.*])) return false;
            index.* += 1;
            continue;
        }
        if (!valid_quoted_text(byte)) return false;
    }
    return false;
}

fn skip_optional_whitespace(value: []const u8, index: *usize) void {
    while (index.* < value.len and (value[index.*] == ' ' or value[index.*] == '\t')) {
        index.* += 1;
    }
}

fn valid_quoted_text(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or byte >= 0x80;
}

fn valid_quoted_pair(byte: u8) bool {
    return byte == '\t' or (byte >= ' ' and byte <= '~') or byte >= 0x80;
}
