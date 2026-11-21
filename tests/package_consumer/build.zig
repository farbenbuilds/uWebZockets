const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sql_enabled = b.option(bool, "sql", "Compile the optional SQL consumer") orelse false;
    const sqlite_enabled = b.option(bool, "sqlite", "Compile the optional SQLite consumer") orelse false;
    const exercise_sql = b.option(bool, "exercise-sql", "Reference SQL from the consumer") orelse true;
    const uwebzockets = b.dependency("uwebzockets", .{
        .target = target,
        .optimize = optimize,
        .sql = sql_enabled,
        .sqlite = sqlite_enabled,
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
    const options = b.addOptions();
    options.addOption(bool, "exercise_sql", exercise_sql);
    executable.root_module.addOptions("consumer_options", options);
    b.installArtifact(executable);

    const check = b.step("check", "Compile a downstream package consumer");
    check.dependOn(&executable.step);
}
