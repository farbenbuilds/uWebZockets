const std = @import("std");
const orchestrator = @import("builds/orchestrator.zig");

pub const version = std.SemanticVersion{ .major = 1, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) void {
    orchestrator.inject(b, version);
}
