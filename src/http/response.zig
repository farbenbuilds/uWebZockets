const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;

/// HTTP/3 stream callbacks used by the transport-neutral response writer.
pub const Http3Target = struct {
    context: *anyopaque,
    end_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    begin_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,
};

/// HTTP/2 stream callbacks backed by a connection-owned bounded session.
pub const Http2Target = struct {
    context: *anyopaque,
    router: *const anyopaque,
    stream_id: u32,
    end_fn: *const fn (*anyopaque, u32, []const u8, []const u8, []const u8) anyerror!void,
    begin_fn: *const fn (*anyopaque, u32, []const u8, []const u8) anyerror!void,
    write_fn: *const fn (*anyopaque, u32, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque, u32) anyerror!void,
};

/// Active transport receiving response bytes.
pub const ConnectionTarget = union(enum) {
    tcp: *TcpConnection,
    http2: Http2Target,
    http3: Http3Target,
};

/// Synchronous response lifecycle enforced across every transport.
pub const ResponseState = enum(u8) {
    idle,
    streaming,
    ended,
};

/// Transport callbacks retained by a connection-owned async response state.
pub const AsyncTarget = struct {
    context: *anyopaque,
    complete_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    wake_fn: *const fn (*anyopaque) void,
};

/// Lifecycle of one connection-owned async response slot.
pub const AsyncState = enum(u8) {
    idle,
    pending,
    completing,
    completed,
    cancelled,
};

/// Stable state embedded in an HTTP/1 connection, HTTP/2 stream, or HTTP/3 stream.
///
/// Re-arming increments a generation so tokens retained past transport reuse
/// fail closed. Methods are event-loop confined; cross-thread completion must
/// first be marshalled onto the owning loop.
pub const AsyncResponseState = struct {
    target: ?AsyncTarget = null,
    generation: u64 = 0,
    state: AsyncState = .idle,

    /// Arms the slot and returns a copyable one-shot token.
    pub fn arm(self: *AsyncResponseState, target: AsyncTarget) AsyncResponse {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = target;
        self.state = .pending;
        return .{ .owner = self, .generation = self.generation };
    }

    /// Invalidates every outstanding token without touching the transport.
    pub fn cancel(self: *AsyncResponseState) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = null;
        self.state = .cancelled;
    }

    /// Reports whether the current generation still awaits completion.
    pub fn is_pending(self: *const AsyncResponseState) bool {
        return self.state == .pending;
    }
};

/// Copyable generation-checked token for exactly one deferred response.
///
/// The token borrows transport-owned state that remains stable until the
/// connection or stream closes. Completion must run on that transport's event
/// loop. A second completion or a completion after reuse returns an error.
pub const AsyncResponse = struct {
    owner: *AsyncResponseState,
    generation: u64,

    /// Completes with no additional response fields.
    pub fn complete(
        self: AsyncResponse,
        status: []const u8,
        body: []const u8,
    ) !void {
        return self.complete_with_headers(status, "", body);
    }

    /// Completes once and wakes the suspended transport dispatch.
    pub fn complete_with_headers(
        self: AsyncResponse,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.generation != self.owner.generation) return error.AsyncResponseExpired;
        if (self.owner.state != .pending) return error.AsyncResponseAlreadyCompleted;
        const target = self.owner.target orelse return error.AsyncResponseExpired;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        self.owner.state = .completing;
        target.complete_fn(target.context, status, headers, body) catch |err| {
            self.owner.state = .completed;
            self.owner.target = null;
            target.wake_fn(target.context);
            return err;
        };
        self.owner.state = .completed;
        self.owner.target = null;
        target.wake_fn(target.context);
    }

    /// Reports whether this exact generation can still complete.
    pub fn is_pending(self: AsyncResponse) bool {
        return self.generation == self.owner.generation and self.owner.state == .pending;
    }
};

/// Transport-neutral synchronous response writer.
pub const Response = struct {
    target: ConnectionTarget,
    state: ResponseState = .idle,
    close_after_end: bool = false,

    /// Sends a complete response with no additional fields.
    pub fn end(self: *Response, status: []const u8, body: []const u8) !void {
        return self.end_with_headers(status, "", body);
    }

    /// Sends a complete response with validated raw response fields.
    pub fn end_with_headers(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                const close_requested = headers_have_token(headers, "Connection", "close");
                var header_buffer: [1024]u8 = undefined;
                const formatted_headers = if (status_forbids_body(code))
                    std.fmt.bufPrint(
                        &header_buffer,
                        "HTTP/1.1 {s}\r\n{s}\r\n",
                        .{ status, headers },
                    ) catch return error.BufferOverflow
                else
                    std.fmt.bufPrint(
                        &header_buffer,
                        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n",
                        .{ status, body.len, headers },
                    ) catch return error.BufferOverflow;

                if (conn.suppress_response_body or status_forbids_body(code)) {
                    try conn.write_data(formatted_headers);
                } else {
                    try conn.write_data_parts(&.{ formatted_headers, body });
                }
                if (close_requested) tcp.close_after_flush(conn);
            },
            .http3 => |target| {
                try target.end_fn(target.context, status, headers, body);
            },
            .http2 => |target| {
                try target.end_fn(target.context, target.stream_id, status, headers, body);
            },
        }
        self.state = .ended;
    }

    /// Starts a bounded streaming response.
    pub fn begin_chunked(
        self: *Response,
        status: []const u8,
        headers: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code)) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                self.close_after_end = headers_have_token(headers, "Connection", "close");
                if (conn.suppress_response_body) return error.BodyNotAllowed;

                var header_buffer: [1024]u8 = undefined;
                const formatted_headers = std.fmt.bufPrint(
                    &header_buffer,
                    "HTTP/1.1 {s}\r\nTransfer-Encoding: chunked\r\n{s}\r\n",
                    .{ status, headers },
                ) catch return error.BufferOverflow;
                try conn.write_data(formatted_headers);
            },
            .http3 => |target| {
                try target.begin_fn(target.context, status, headers);
            },
            .http2 => |target| {
                try target.begin_fn(target.context, target.stream_id, status, headers);
            },
        }
        self.state = .streaming;
    }

    /// Appends one chunk to a streaming response.
    pub fn write_chunk(self: *Response, chunk: []const u8) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| try @import("chunked.zig").send_chunk(conn, chunk),
            .http3 => |target| try target.write_fn(target.context, chunk),
            .http2 => |target| try target.write_fn(target.context, target.stream_id, chunk),
        }
    }

    /// Finishes a streaming response.
    pub fn end_chunks(self: *Response) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| {
                try @import("chunked.zig").end(conn);
                if (self.close_after_end) tcp.close_after_flush(conn);
            },
            .http3 => |target| try target.finish_fn(target.context),
            .http2 => |target| try target.finish_fn(target.context, target.stream_id),
        }
        self.state = .ended;
    }

    /// Reports whether the response ended successfully.
    pub fn is_complete(self: *const Response) bool {
        return self.state == .ended;
    }

    /// Reports whether any response bytes were started.
    pub fn is_started(self: *const Response) bool {
        return self.state != .idle;
    }
};

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

/// Finds a case-insensitive token in comma-delimited raw response fields.
pub fn headers_have_token(headers: []const u8, name: []const u8, token: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var values = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (values.next()) |value| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token)) return true;
        }
    }
    return false;
}

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
