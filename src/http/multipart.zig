const std = @import("std");
const simd = @import("../core/simd.zig");

pub const max_boundary_length = 70;

pub const Part = struct {
    headers: []const u8,
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,

    /// Returns fixed-size borrowed chunks without copying the part payload.
    pub fn chunks(self: Part, chunk_size: usize) ChunkIterator {
        return .{ .data = self.data, .chunk_size = chunk_size };
    }
};

pub const ChunkIterator = struct {
    data: []const u8,
    chunk_size: usize,
    offset: usize = 0,

    pub fn next(self: *ChunkIterator) ?[]const u8 {
        if (self.offset == self.data.len or self.chunk_size == 0) return null;
        const end = @min(self.data.len, self.offset +| self.chunk_size);
        const chunk = self.data[self.offset..end];
        self.offset = end;
        return chunk;
    }
};

pub const Parser = struct {
    body: []const u8,
    boundary: []const u8,
    cursor: usize = 0,
    finished: bool = false,

    pub fn init(body: []const u8, boundary: []const u8) !Parser {
        if (!valid_boundary(boundary)) return error.InvalidMultipartBoundary;
        return .{ .body = body, .boundary = boundary };
    }

    /// Parses the next RFC 7578 part while borrowing all returned slices.
    pub fn next_part(self: *Parser) !?Part {
        if (self.finished) return null;
        try self.consume_boundary();
        if (self.finished) return null;

        const header_end_relative = simd.index_of(self.body[self.cursor..], "\r\n\r\n") orelse {
            return error.InvalidMultipartHeaders;
        };
        const header_end = self.cursor + header_end_relative;
        const headers = self.body[self.cursor..header_end];
        self.cursor = header_end + 4;

        const boundary_start = find_next_boundary(self.body[self.cursor..], self.boundary) orelse {
            return error.IncompleteMultipartBody;
        };
        const data = self.body[self.cursor .. self.cursor + boundary_start];
        self.cursor += boundary_start + 2;

        const disposition = find_header(headers, "content-disposition") orelse {
            return error.MissingContentDisposition;
        };
        const disposition_type = first_parameter(disposition);
        if (!std.ascii.eqlIgnoreCase(disposition_type, "form-data")) {
            return error.InvalidContentDisposition;
        }
        const name = find_parameter(disposition, "name") orelse {
            return error.MissingPartName;
        };

        return .{
            .headers = headers,
            .name = name,
            .filename = find_parameter(disposition, "filename"),
            .content_type = find_header(headers, "content-type"),
            .data = data,
        };
    }

    fn consume_boundary(self: *Parser) !void {
        if (self.cursor != 0) {
            if (!std.mem.startsWith(u8, self.body[self.cursor..], "--")) {
                return error.InvalidMultipartBoundary;
            }
            self.cursor += 2;
        } else {
            if (!std.mem.startsWith(u8, self.body, "--")) {
                return error.InvalidMultipartBoundary;
            }
            self.cursor = 2;
        }

        if (!std.mem.startsWith(u8, self.body[self.cursor..], self.boundary)) {
            return error.InvalidMultipartBoundary;
        }
        self.cursor += self.boundary.len;
        if (std.mem.startsWith(u8, self.body[self.cursor..], "--")) {
            self.cursor += 2;
            if (self.cursor < self.body.len and
                !std.mem.eql(u8, self.body[self.cursor..], "\r\n"))
            {
                return error.InvalidMultipartEpilogue;
            }
            self.finished = true;
            return;
        }
        if (!std.mem.startsWith(u8, self.body[self.cursor..], "\r\n")) {
            return error.InvalidMultipartBoundary;
        }
        self.cursor += 2;
    }
};

/// Extracts and validates a multipart boundary from Content-Type.
pub fn boundary_from_content_type(value: []const u8) ![]const u8 {
    const media_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..media_end], " \t");
    if (!std.ascii.eqlIgnoreCase(media_type, "multipart/form-data")) {
        return error.NotMultipartFormData;
    }
    const boundary = find_parameter(value, "boundary") orelse {
        return error.MissingMultipartBoundary;
    };
    if (!valid_boundary(boundary)) return error.InvalidMultipartBoundary;
    return boundary;
}

fn find_next_boundary(input: []const u8, boundary: []const u8) ?usize {
    var offset: usize = 0;
    while (simd.index_of(input[offset..], "\r\n--")) |relative| {
        const candidate = offset + relative;
        const value_start = candidate + 4;
        if (std.mem.startsWith(u8, input[value_start..], boundary)) {
            const suffix_start = value_start + boundary.len;
            if (suffix_start + 2 <= input.len) {
                const suffix = input[suffix_start .. suffix_start + 2];
                if (std.mem.eql(u8, suffix, "\r\n") or std.mem.eql(u8, suffix, "--")) {
                    return candidate;
                }
            }
        }
        offset = candidate + 2;
        if (offset >= input.len) return null;
    }
    return null;
}

fn find_header(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..separator], " \t"), name)) continue;
        return std.mem.trim(u8, line[separator + 1 ..], " \t");
    }
    return null;
}

fn first_parameter(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.mem.trim(u8, value[0..end], " \t");
}

fn find_parameter(value: []const u8, name: []const u8) ?[]const u8 {
    var parameters = std.mem.splitScalar(u8, value, ';');
    _ = parameters.next();
    while (parameters.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const separator = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const parameter_name = std.mem.trim(u8, parameter[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(parameter_name, name)) continue;

        const raw_value = std.mem.trim(u8, parameter[separator + 1 ..], " \t");
        if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') {
            const quoted = raw_value[1 .. raw_value.len - 1];
            if (std.mem.indexOfScalar(u8, quoted, '\\') != null) return null;
            return quoted;
        }
        return raw_value;
    }
    return null;
}

fn valid_boundary(boundary: []const u8) bool {
    if (boundary.len == 0 or boundary.len > max_boundary_length) return false;
    if (boundary[boundary.len - 1] == ' ') return false;
    for (boundary) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '\'', '(', ')', '+', '_', ',', '-', '.', '/', ':', '=', '?', ' ' => {},
            else => return false,
        }
    }
    return true;
}
