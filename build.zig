const std = @import("std");
const orchestrator = @import("builds/orchestrator.zig");

pub const version = std.SemanticVersion{ .major = 1, .minor = 0, .patch = 5 };

pub fn build(b: *std.Build) void {
    orchestrator.inject(b, version);
}
