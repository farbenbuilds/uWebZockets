const std = @import("std");
const support = @import("test_support");
const Response = support.http_response.Response;

pub const logical_sizes = [_]usize{ 1, 16 * 1024, 64 * 1024 };

/// Caller-owned producer that yields at logical boundaries and reuses 8 KiB.
pub const Producer = struct {
    bytes: [8192]u8 = undefined,
    logical_size: usize,
    target_size: usize,
    offset: usize = 0,
    calls: usize = 0,
    logical_yields: usize = 0,
    blocked: usize = 0,
    empty_writes: usize = 0,
    begin_error: ?anyerror = null,

    pub fn produce(context: *anyopaque, response: *Response) anyerror!support.http_response.StreamStatus {
        const state: *Producer = @ptrCast(@alignCast(context));
        state.calls += 1;
        try response.write_chunk("");
        state.empty_writes += 1;
        while (state.offset < state.target_size) {
            const remaining = state.logical_size - state.offset % state.logical_size;
            const count = @min(state.bytes.len, @min(remaining, state.target_size - state.offset));
            for (state.bytes[0..count], 0..) |*byte, index| byte.* = byte_at(state.offset + index);
            response.write_chunk(state.bytes[0..count]) catch |err| {
                if (err != error.WouldBlock) return err;
                state.blocked += 1;
                return .pending;
            };
            // Accepted chunks must outlive reuse of the caller's source bytes.
            @memset(state.bytes[0..count], 0xcc);
            state.offset += count;
            if (state.offset % state.logical_size == 0) {
                state.logical_yields += 1;
                return .pending;
            }
        }
        response.end_chunks() catch |err| {
            if (err != error.WouldBlock) return err;
            state.blocked += 1;
            return .pending;
        };
        return .done;
    }

    pub fn handle(context: *anyopaque, _: *support.http_request.Request, response: *Response) void {
        const state: *Producer = @ptrCast(@alignCast(context));
        response.begin_stream("200 OK", "", state, produce) catch |err| {
            state.begin_error = err;
        };
    }
};

/// Exact payload validation without retaining previously accepted bytes.
pub const Capture = struct {
    expected_size: usize,
    offset: usize = 0,

    pub fn consume(state: *Capture, bytes: []const u8) bool {
        if (bytes.len > state.expected_size - state.offset) return false;
        for (bytes, 0..) |byte, index| {
            if (byte != byte_at(state.offset + index)) return false;
        }
        state.offset += bytes.len;
        return true;
    }
};

/// Validates complete chunk frames from one bounded HTTP/1 output drain.
pub const ChunkedCapture = struct {
    body: Capture,
    head_seen: bool = false,
    ended: bool = false,

    pub fn consume(state: *ChunkedCapture, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (state.ended) return error.OutputAfterTerminalChunk;
        var offset: usize = 0;
        if (!state.head_seen) {
            const expected_head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
            if (!std.mem.startsWith(u8, bytes, expected_head)) return error.InvalidStreamingHead;
            offset = expected_head.len;
            state.head_seen = true;
        }
        while (offset < bytes.len) {
            const line_length = std.mem.indexOf(u8, bytes[offset..], "\r\n") orelse return error.IncompleteChunkSize;
            const length = try std.fmt.parseInt(usize, bytes[offset .. offset + line_length], 16);
            offset += line_length + 2;
            if (length == 0) {
                if (!std.mem.eql(u8, bytes[offset..], "\r\n")) return error.InvalidTerminalChunk;
                state.ended = true;
                return;
            }
            if (length > bytes.len - offset) return error.IncompleteChunk;
            if (!state.body.consume(bytes[offset .. offset + length])) return error.InvalidPattern;
            offset += length;
            if (bytes.len - offset < 2 or !std.mem.eql(u8, bytes[offset..][0..2], "\r\n")) {
                return error.InvalidChunkTerminator;
            }
            offset += 2;
        }
    }
};

/// Mixes high offset bits so dropped or reordered 8 KiB chunks are detectable.
fn byte_at(offset: usize) u8 {
    return @truncate(offset ^ (offset >> 8) ^ (offset >> 16) ^ 0x5a);
}
