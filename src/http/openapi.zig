const std = @import("std");

pub const Route = struct {
    method: []const u8,
    path: []const u8,
    websocket: bool = false,
};

pub const Options = struct {
    title: []const u8 = "uWebZockets API",
    version: []const u8 = "1.0.3",
};

/// Generates a bounded OpenAPI 3.1 document from registered route metadata.
pub fn generate(
    buffer: []u8,
    routes: []const Route,
    options: Options,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    try write_json_string(&writer, options.title);
    try writer.writeAll(",\"version\":");
    try write_json_string(&writer, options.version);
    try writer.writeAll("},\"paths\":{");

    var emitted_path = false;
    for (routes, 0..) |route, index| {
        if (seen_path(routes[0..index], route.path)) continue;
        if (emitted_path) try writer.writeByte(',');
        emitted_path = true;
        try write_openapi_path(&writer, route.path);
        try writer.writeAll(":{");

        var emitted_method = false;
        for (routes, 0..) |candidate, candidate_index| {
            if (!std.mem.eql(u8, candidate.path, route.path)) continue;
            if (seen_method_for_path(routes[0..candidate_index], candidate)) continue;
            if (emitted_method) try writer.writeByte(',');
            emitted_method = true;
            try write_json_string(&writer, candidate.method);
            try writer.writeAll(":{\"responses\":{\"200\":{\"description\":\"Success\"}}");
            if (has_websocket(routes, candidate.path, candidate.method)) {
                try writer.writeAll(",\"x-websocket\":true");
            }
            try writer.writeByte('}');
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("}}");
    return writer.buffered();
}

fn seen_path(previous: []const Route, path: []const u8) bool {
    for (previous) |route| {
        if (std.mem.eql(u8, route.path, path)) return true;
    }
    return false;
}

fn seen_method_for_path(previous: []const Route, candidate: Route) bool {
    for (previous) |route| {
        if (!std.mem.eql(u8, route.path, candidate.path)) continue;
        if (std.mem.eql(u8, route.method, candidate.method)) return true;
    }
    return false;
}

fn has_websocket(routes: []const Route, path: []const u8, method: []const u8) bool {
    for (routes) |route| {
        if (!route.websocket) continue;
        if (!std.mem.eql(u8, route.path, path)) continue;
        if (std.mem.eql(u8, route.method, method)) return true;
    }
    return false;
}

fn write_openapi_path(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < path.len) {
        const byte = path[index];
        if (byte != ':' and byte != '*') {
            try write_json_byte(writer, byte);
            index += 1;
            continue;
        }

        try writer.writeByte('{');
        index += 1;
        while (index < path.len and path[index] != '/') : (index += 1) {
            try write_json_byte(writer, path[index]);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('"');
}

fn write_json_string(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| try write_json_byte(writer, byte);
    try writer.writeByte('"');
}

fn write_json_byte(writer: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    }
}
