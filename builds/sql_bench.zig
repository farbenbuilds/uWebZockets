const std = @import("std");
const sanitizers = @import("sanitizers.zig");

/// Opt-in SQL timing probe; never part of the default build or test graph.
pub fn inject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    xev: *std.Build.Module,
    sanitizer: sanitizers.Config,
    enabled: bool,
) void {
    if (!enabled) return;
    const root = b.createModule(.{
        .root_source_file = b.path("benchmarks/sql_query_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("uWebZockets", module);
    root.addImport("xev", xev);
    const executable = b.addExecutable(.{ .name = "sql_query_probe", .root_module = root });
    const install = b.addInstallArtifact(executable, .{});
    b.step("sql-probe", "Compile the bounded SQL query and pool-wait timing probe").dependOn(&install.step);
    const compile = b.step("sql-bench", "Build the SQL route server and direct query probe");
    compile.dependOn(&install.step);
    const world = b.createModule(.{
        .root_source_file = b.path("examples/sql_postgres.zig"),
        .target = target,
        .optimize = optimize,
    });
    world.addImport("uWebZockets", module);
    const cluster_root = b.createModule(.{
        .root_source_file = b.path("benchmarks/sql_cluster_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    cluster_root.addImport("uWebZockets", module);
    cluster_root.addImport("sql_world", world);
    const cluster = b.addExecutable(.{ .name = "sql_cluster_server", .root_module = cluster_root });
    const install_cluster = b.addInstallArtifact(cluster, .{});
    compile.dependOn(&install_cluster.step);
    const run = sanitizers.add_run_artifact(b, executable, sanitizer.run);
    b.step("run-sql-probe", "Measure bounded PostgreSQL query and pool-wait latency").dependOn(&run.step);
}
