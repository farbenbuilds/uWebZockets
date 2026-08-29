const std = @import("std");
const uz = @import("uWebZockets");

pub fn main(init: std.process.Init) !void {
    _ = init;
    if (!uz.http3_available) return error.Http3NotImplemented;
    return error.Http3NotImplemented;
}
