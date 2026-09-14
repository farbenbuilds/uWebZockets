const std = @import("std");

pub const Steps = struct {
    freestanding: *std.Build.Step,
    wasi: *std.Build.Step,
};

pub fn inject_named(
    b: *std.Build,
    version: std.SemanticVersion,
    optimize: std.builtin.OptimizeMode,
) Steps {
    const freestanding_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });
    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const freestanding = add_wasm(
        b,
        "uWebZockets-freestanding",
        freestanding_target,
        optimize,
        version,
        true,
    );
    const wasi = add_wasm(
        b,
        "uWebZockets-wasi",
        wasi_target,
        optimize,
        version,
        false,
    );
    const install_freestanding = b.addInstallArtifact(freestanding, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
        .dest_sub_path = "uWebZockets-freestanding.wasm",
    });
    const install_wasi = b.addInstallArtifact(wasi, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
        .dest_sub_path = "uWebZockets-wasi.wasm",
    });
    const freestanding_step = b.step("wasm-freestanding", "Build the V8 isolate WebAssembly target");
    freestanding_step.dependOn(&install_freestanding.step);
    const wasi_step = b.step("wasm-wasi", "Build the WASI WebAssembly target");
    wasi_step.dependOn(&install_wasi.step);
    const all = b.step("wasm", "Build freestanding and WASI WebAssembly targets");
    all.dependOn(freestanding_step);
    all.dependOn(wasi_step);
    return .{ .freestanding = freestanding_step, .wasi = wasi_step };
}

pub fn inject_selected(
    b: *std.Build,
    version: std.SemanticVersion,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const shared_memory = target.result.os.tag == .freestanding;
    const artifact = add_wasm(b, "uWebZockets", target, optimize, version, shared_memory);
    b.installArtifact(artifact);
}

fn add_wasm(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    shared_memory: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/edge_wasm.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = !shared_memory,
    });
    const artifact = b.addExecutable(.{
        .name = name,
        .root_module = module,
        .version = version,
    });
    artifact.entry = .disabled;
    artifact.export_memory = true;
    artifact.rdynamic = true;
    artifact.initial_memory = 32 * 1024 * 1024;
    artifact.max_memory = 64 * 1024 * 1024;
    artifact.shared_memory = shared_memory;
    return artifact;
}
