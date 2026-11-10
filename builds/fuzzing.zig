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

    const targets = [_]Target{
        .{ .name = "http_framing", .source = "fuzz/http_framing.zig", .smoke = "fuzz/smoke_http.zig" },
        .{ .name = "ws_masking", .source = "fuzz/ws_masking.zig", .smoke = "fuzz/smoke_ws.zig" },
        .{ .name = "quic_packets", .source = "fuzz/quic_packets.zig", .smoke = "fuzz/smoke_quic.zig" },
        .{ .name = "query_parse", .source = "fuzz/query_parse.zig", .smoke = "fuzz/smoke_query.zig" },
        .{ .name = "cookie_parse", .source = "fuzz/cookie_parse.zig", .smoke = "fuzz/smoke_cookie.zig" },
        .{ .name = "multipart_streaming", .source = "fuzz/multipart_streaming.zig", .smoke = "fuzz/smoke_multipart.zig" },
    };

    const object_step = b.step("oss-fuzz-objects", "Build libFuzzer ABI objects with sanitizer coverage");
    const smoke_step = b.step("oss-fuzz-smoke", "Run deterministic protocol-boundary fuzz smoke inputs");
    var coverage_check = b.addSystemCommand(&.{"sh"});
    coverage_check.addFileArg(b.path("fuzz/check_fuzzer_coverage.sh"));
    for (targets) |entry| {
        const object = add_fuzz_object(b, entry.name, entry.source, target, optimize, fuzz_support);
        const install = b.addInstallArtifact(object, .{
            .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
            .dest_sub_path = b.fmt("{s}.o", .{entry.name}),
        });
        object_step.dependOn(&install.step);
        coverage_check.addFileArg(object.getEmittedBin());

        const smoke = add_smoke(b, b.fmt("{s}_smoke", .{entry.name}), entry.smoke, target, optimize, fuzz_support);
        smoke_step.dependOn(&sanitizers.add_run_artifact(b, smoke, sanitizer.run).step);
    }
    object_step.dependOn(&coverage_check.step);

    const oss_fuzz = b.step("oss-fuzz", "Build OSS-Fuzz objects and run deterministic smoke inputs");
    oss_fuzz.dependOn(object_step);
    oss_fuzz.dependOn(smoke_step);
    const fuzz = b.step("fuzz", "Run deterministic parser fuzz smoke inputs");
    fuzz.dependOn(&run_legacy.step);
    fuzz.dependOn(smoke_step);
}

const Target = struct {
    name: []const u8,
    source: []const u8,
    smoke: []const u8,
};

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
        // OSS-Fuzz links the bare object with $CXX; Zig's stack-check runtime
        // is not part of that link, so keep the check out of the object.
        .stack_check = false,
        // `-ffuzz` emits inline-8bit-counter sections without registration
        // calls; `oss-fuzz/zig_sancov_shim.c` registers those sections with
        // libFuzzer at link time, and the object step verifies the sections.
        .fuzz = true,
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
