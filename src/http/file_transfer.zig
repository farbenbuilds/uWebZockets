const std = @import("std");
const response = @import("response.zig");

/// One transport-owned descriptor and borrowed worker-local read window.
pub const FileTransfer = struct {
    io: std.Io = undefined,
    buffer: []u8 = &.{},
    offset: u64 = 0,
    remaining: u64 = 0,
    chunk_limit: usize = 0,
    file: ?std.Io.File = null,
};

/// Clears ownership before closing so repeated teardown cannot close a reused fd.
pub fn close(transfer: *FileTransfer) void {
    const file = transfer.file orelse return;
    const io = transfer.io;
    transfer.* = .{};
    file.close(io);
}

/// Reads at most one bounded window; transport output always copies the slice.
pub fn produce(context: *anyopaque, output: *response.Response) anyerror!response.StreamStatus {
    const transfer: *FileTransfer = @ptrCast(@alignCast(context));
    if (transfer.remaining == 0) return finish(output);
    if (transfer.chunk_limit == 0) return .pending;
    const file = transfer.file orelse return error.FileTransferClosed;
    const count: usize = @intCast(@min(transfer.remaining, @min(transfer.buffer.len, transfer.chunk_limit)));
    const read = try file.readPositionalAll(transfer.io, transfer.buffer[0..count], transfer.offset);
    if (read != count) return error.UnexpectedEndOfFile;
    output.write_chunk(transfer.buffer[0..count]) catch |err| {
        if (err == error.WouldBlock) return .pending;
        return err;
    };
    transfer.offset += count;
    transfer.remaining -= count;
    if (transfer.remaining == 0) return finish(output);
    return .pending;
}

/// Terminal framing can clear the transfer synchronously; no owner access follows.
fn finish(output: *response.Response) !response.StreamStatus {
    output.end_chunks() catch |err| {
        if (err == error.WouldBlock) return .pending;
        return err;
    };
    return .done;
}
