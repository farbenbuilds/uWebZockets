const std = @import("std");

/// Parses a validated `NNN` or `NNN reason` status in the supported range.
pub fn status_code(status: []const u8) ?u16 {
    if (status.len < 3) return null;
    for (status[0..3]) |c| {
        if (c < '0' or c > '9') return null;
    }
    if (status.len > 3 and status[3] != ' ') return null;

    if (status.len > 4) {
        for (status[4..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return null;
        }
    }

    const code = std.fmt.parseInt(u16, status[0..3], 10) catch return null;
    if (code < 200 or code > 599) return null;
    return code;
}

/// Reports whether a final response status forbids payload bytes.
pub fn status_forbids_body(code: u16) bool {
    return code == 204 or code == 205 or code == 304;
}

/// Validates raw HTTP/1-style response fields without allocating.
pub fn valid_headers(headers: []const u8) bool {
    if (headers.len == 0) return true;
    if (!std.mem.endsWith(u8, headers, "\r\n")) return false;

    var lines = std.mem.splitSequence(u8, headers[0 .. headers.len - 2], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return false;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const name = line[0..colon];
        if (name.len == 0) return false;

        for (name) |c| {
            if (!is_tchar(c)) return false;
        }
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) return false;
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return false;

        for (line[colon + 1 ..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
        }
    }
    return true;
}

/// Recognizes one RFC 9110 field-name token byte.
pub fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
