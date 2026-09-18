const std = @import("std");
const orchestrator = @import("builds/orchestrator.zig");

pub const version = @import("src/version.zig").semantic;

pub fn build(b: *std.Build) void {
    orchestrator.inject(b, version);
}
