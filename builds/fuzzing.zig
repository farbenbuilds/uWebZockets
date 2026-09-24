const std = @import("std");
const sanitizers = @import("sanitizers.zig");
const vendor = @import("vendor/root.zig");

pub fn inject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependencies: vendor.Artifacts,
    sanitizer: sanitizers.Config,
    zslay: *std.Build.Module,
    xev: *std.Build.Module,
) void {
    const test_support = b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("c", dependencies.c_module);
    test_support.addImport("xev", xev);
    test_support.addImport("zslay", zslay);

    const legacy_module = b.createModule(.{
        .root_source_file = b.path("src/tests/fuzz_main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    legacy_module.addImport("test_support", test_support);
    legacy_module.addImport("zslay", zslay);
    const legacy_tests = b.addTest(.{ .root_module = legacy_module });
    const run_legacy = sanitizers.add_run_artifact(b, legacy_tests, sanitizer.run);

    const fuzz_support = b.createModule(.{
        .root_source_file = b.path("src/fuzz_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_support.addImport("zslay", zslay);

    const http_object = add_fuzz_object(b, "http_framing", "fuzz/http_framing.zig", target, optimize, fuzz_support);
    const ws_object = add_fuzz_object(b, "ws_masking", "fuzz/ws_masking.zig", target, optimize, fuzz_support);
    const quic_object = add_fuzz_object(b, "quic_packets", "fuzz/quic_packets.zig", target, optimize, fuzz_support);
    const query_object = add_fuzz_object(b, "query_parse", "fuzz/query_parse.zig", target, optimize, fuzz_support);
    const install_http = b.addInstallArtifact(http_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "http_framing.o",
    });
    const install_ws = b.addInstallArtifact(ws_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "ws_masking.o",
    });
    const install_quic = b.addInstallArtifact(quic_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "quic_packets.o",
    });
    const install_query = b.addInstallArtifact(query_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "query_parse.o",
    });
    const object_step = b.step("oss-fuzz-objects", "Build libFuzzer ABI objects with sanitizer coverage");
    object_step.dependOn(&install_http.step);
    object_step.dependOn(&install_ws.step);
    object_step.dependOn(&install_quic.step);
    object_step.dependOn(&install_query.step);

    const http_smoke = add_smoke(b, "http_framing_smoke", "fuzz/smoke_http.zig", target, optimize, fuzz_support);
    const ws_smoke = add_smoke(b, "ws_masking_smoke", "fuzz/smoke_ws.zig", target, optimize, fuzz_support);
    const quic_smoke = add_smoke(b, "quic_packets_smoke", "fuzz/smoke_quic.zig", target, optimize, fuzz_support);
    const query_smoke = add_smoke(b, "query_parse_smoke", "fuzz/smoke_query.zig", target, optimize, fuzz_support);
    const run_http = sanitizers.add_run_artifact(b, http_smoke, sanitizer.run);
    const run_ws = sanitizers.add_run_artifact(b, ws_smoke, sanitizer.run);
    const run_quic = sanitizers.add_run_artifact(b, quic_smoke, sanitizer.run);
    const run_query = sanitizers.add_run_artifact(b, query_smoke, sanitizer.run);
    const smoke_step = b.step("oss-fuzz-smoke", "Run deterministic protocol-boundary fuzz smoke inputs");
    smoke_step.dependOn(&run_http.step);
    smoke_step.dependOn(&run_ws.step);
    smoke_step.dependOn(&run_quic.step);
    smoke_step.dependOn(&run_query.step);

    const oss_fuzz = b.step("oss-fuzz", "Build OSS-Fuzz objects and run deterministic smoke inputs");
    oss_fuzz.dependOn(object_step);
    oss_fuzz.dependOn(smoke_step);
    const fuzz = b.step("fuzz", "Run deterministic parser fuzz smoke inputs");
    fuzz.dependOn(&run_legacy.step);
    fuzz.dependOn(smoke_step);
}

fn add_fuzz_object(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fuzz_support: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .stack_check = false,
    });
    module.addImport("fuzz_support", fuzz_support);
    return b.addObject(.{ .name = name, .root_module = module });
}

fn add_smoke(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fuzz_support: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("fuzz_support", fuzz_support);
    return b.addExecutable(.{ .name = name, .root_module = module });
}
