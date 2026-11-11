const std = @import("std");
const sanitizers = @import("sanitizers.zig");
const sql = @import("sql.zig");

/// One runnable example exposed as its own build step.
const Example = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
};

const examples = [_]Example{
    .{ .name = "hello_world", .source = "examples/hello_world.zig", .description = "Run the hello_world example" },
    .{ .name = "https_server", .source = "examples/https_server.zig", .description = "Run the ephemeral HTTPS example server" },
    .{ .name = "chat_server", .source = "examples/chat_server.zig", .description = "Run the chat_server example" },
    .{ .name = "http3_server", .source = "examples/http3_server.zig", .description = "Run the HTTP/3 example server" },
    .{ .name = "rpc_server", .source = "examples/rpc_server.zig", .description = "Run the JSON-RPC example server" },
    .{ .name = "basic_microservice", .source = "examples/basic_microservice.zig", .description = "Run the microservice preset example" },
    .{ .name = "custom_builder", .source = "examples/custom_builder.zig", .description = "Run the custom builder example" },
    .{ .name = "shared_nothing_cluster", .source = "examples/shared_nothing_cluster.zig", .description = "Run the shared-nothing worker group example" },
    .{ .name = "tls_cluster", .source = "examples/tls_cluster.zig", .description = "Run the TLS-enabled worker group example" },
    .{ .name = "delay_server", .source = "examples/delay_server.zig", .description = "Run the async /delay timing-wheel example" },
};

const sql_examples = [_]Example{
    .{ .name = "sql_httparena", .source = "examples/sql_httparena.zig", .description = "Run the current HttpArena async-db and delay routes" },
    .{ .name = "sql_postgres", .source = "examples/sql_postgres.zig", .description = "Run the bounded PostgreSQL World routes" },
    .{ .name = "sql_transactions", .source = "examples/sql_transactions.zig", .description = "Run the transaction and outbox example" },
};

pub fn inject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    sanitizer: sanitizers.Config,
    sql_config: sql.Config,
) void {
    for (examples) |example| {
        _ = add_example(b, target, optimize, module, sanitizer, example);
    }
    const sql_compile = b.step("sql-examples", "Compile enabled SQL examples without starting their servers");
    if (!sql_config.enabled) return;
    for (sql_examples) |example| {
        const executable = add_example(b, target, optimize, module, sanitizer, example);
        sql_compile.dependOn(&executable.step);
    }
    if (!sql_config.sqlite_enabled) return;
    const sqlite_example = add_example(b, target, optimize, module, sanitizer, .{
        .name = "sql_sqlite",
        .source = "examples/sql_sqlite.zig",
        .description = "Run the startup-prepared SQLite local CRUD example",
    });
    sql_compile.dependOn(&sqlite_example.step);
}

fn add_example(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    sanitizer: sanitizers.Config,
    example: Example,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = example.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(example.source),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("uWebZockets", module);
    b.installArtifact(executable);

    const run = sanitizers.add_run_artifact(b, executable, sanitizer.run);
    const step = b.step(example.name, example.description);
    step.dependOn(&run.step);
    return executable;
}
