const std = @import("std");
const sanitizers = @import("sanitizers.zig");
const vendor = @import("vendor.zig");

const Example = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
};

const examples = [_]Example{
    .{ .name = "hello_world", .source = "examples/hello_world.zig", .description = "Run the hello_world example" },
    .{ .name = "chat_server", .source = "examples/chat_server.zig", .description = "Run the chat_server example" },
    .{ .name = "http3_server", .source = "examples/http3_server.zig", .description = "Run the HTTP/3 example server" },
    .{ .name = "rpc_server", .source = "examples/rpc_server.zig", .description = "Run the JSON-RPC example server" },
    .{ .name = "basic_microservice", .source = "examples/basic_microservice.zig", .description = "Run the microservice preset example" },
    .{ .name = "custom_builder", .source = "examples/custom_builder.zig", .description = "Run the custom builder example" },
    .{ .name = "shared_nothing_cluster", .source = "examples/shared_nothing_cluster.zig", .description = "Run the shared-nothing worker group example" },
};

pub fn inject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    dependencies: vendor.Artifacts,
    sanitizer: sanitizers.Config,
) void {
    for (examples) |example| {
        const executable = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
            }),
        });
        executable.root_module.addImport("uWebZockets", module);
        dependencies.add_build_dependencies(executable);
        b.installArtifact(executable);

        const run = sanitizers.add_run_artifact(b, executable, sanitizer.run);
        const step = b.step(example.name, example.description);
        step.dependOn(&run.step);
    }
}
