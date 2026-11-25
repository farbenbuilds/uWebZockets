const std = @import("std");
const child = @import("test_support").webtransport_child_runtime;
const io = @import("test_support").webtransport_child_io;
const c = @import("c");

const NativeFault = struct { copied: [16]u8 = @splat(0), copied_bytes: usize = 0, flushes: usize = 0 };

fn copy_prefix(raw: ?*c.lsquic_stream, reader: [*c]c.struct_lsquic_reader) callconv(.c) isize {
    const fault: *NativeFault = @ptrCast(@alignCast(raw orelse return -1));
    const count = @min(@as(usize, 5), reader.*.lsqr_size.?(reader.*.lsqr_ctx));
    fault.copied_bytes = reader.*.lsqr_read.?(reader.*.lsqr_ctx, &fault.copied, count);
    return @intCast(fault.copied_bytes);
}

fn copy_then_fail(raw: ?*c.lsquic_stream, reader: [*c]c.struct_lsquic_reader) callconv(.c) isize {
    _ = copy_prefix(raw, reader);
    return -1;
}

fn fail_without_errno(_: ?*c.lsquic_stream, _: [*c]c.struct_lsquic_reader) callconv(.c) isize {
    return -1;
}

fn fail_flush(raw: ?*c.lsquic_stream) callconv(.c) c_int {
    const fault: *NativeFault = @ptrCast(@alignCast(raw orelse return -1));
    fault.flushes += 1;
    return -1;
}

test "WebTransport native writer distinguishes zero-consumption failure from stale errno" {
    for ([_]std.c.E{ .AGAIN, .BADF, .CONNRESET }) |stale| {
        var fault = NativeFault{};
        std.c._errno().* = @intFromEnum(stale);
        const result = io.write(.{ .write = fail_without_errno, .flush = fail_flush }, @ptrCast(&fault), "payload");
        try std.testing.expectError(error.WriteFailed, result.result);
        try std.testing.expect(result.failed);
        try std.testing.expectEqual(@as(usize, 0), fault.copied_bytes);
        try std.testing.expectEqual(@as(usize, 0), fault.flushes);
    }
}

test "WebTransport native reader preserves copied prefix when write fails afterward" {
    var fault = NativeFault{};
    var input = "abcdefgh".*;
    const result = io.write(.{ .write = copy_then_fail, .flush = fail_flush }, @ptrCast(&fault), &input);
    @memset(&input, 'x');
    try std.testing.expectEqual(@as(usize, 5), try result.result);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("abcde", fault.copied[0..fault.copied_bytes]);
    try std.testing.expectEqual(@as(usize, 0), fault.flushes);
}

test "WebTransport native writer preserves copied prefix when flushing fails" {
    var fault = NativeFault{};
    const result = io.write(.{ .write = copy_prefix, .flush = fail_flush }, @ptrCast(&fault), "abcdefgh");
    try std.testing.expectEqual(@as(usize, 5), try result.result);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("abcde", fault.copied[0..fault.copied_bytes]);
    try std.testing.expectEqual(@as(usize, 1), fault.flushes);
}

test "WebTransport transmit ownership survives failure after native reader consumption" {
    for ([_]child.WriteStatus{ .closed, .failed }) |status| {
        const attempt = child.complete_write(3072, status);
        try std.testing.expectEqual(@as(usize, 3072), try attempt.result);
        try std.testing.expect(attempt.failed);
    }
}

test "WebTransport transmit partial and blocked progress retain their accepted prefix" {
    for ([_]child.WriteStatus{ .progress, .blocked }) |status| {
        const attempt = child.complete_write(17, status);
        try std.testing.expectEqual(@as(usize, 17), try attempt.result);
        try std.testing.expect(!attempt.failed);
    }
}

test "WebTransport transmit zero acceptance reports backpressure or terminal failure" {
    const blocked = child.complete_write(0, .blocked);
    try std.testing.expectError(error.WouldBlock, blocked.result);
    try std.testing.expect(!blocked.failed);
    const no_progress = child.complete_write(0, .progress);
    try std.testing.expectError(error.WouldBlock, no_progress.result);
    const closed = child.complete_write(0, .closed);
    try std.testing.expectError(error.WriteClosed, closed.result);
    try std.testing.expect(!closed.failed);
    const failed = child.complete_write(0, .failed);
    try std.testing.expectError(error.WriteFailed, failed.result);
    try std.testing.expect(failed.failed);
}
