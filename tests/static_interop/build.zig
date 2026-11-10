const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("uwebzockets", .{
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "static_interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("uWebZockets", dependency.module("uWebZockets"));
    b.installArtifact(executable);

    const check = b.step("check", "Compile the public static-route consumer");
    check.dependOn(&executable.step);
}
