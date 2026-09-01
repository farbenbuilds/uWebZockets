const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const uwebzockets = b.dependency("uwebzockets", .{
        .target = target,
        .optimize = optimize,
    });
    const uwebzockets_module = uwebzockets.module("uWebZockets");

    const executable = b.addExecutable(.{
        .name = "package_consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport(
        "uWebZockets",
        uwebzockets_module,
    );

    const check = b.step("check", "Compile a downstream package consumer");
    check.dependOn(&executable.step);
}
