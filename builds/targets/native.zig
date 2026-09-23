const std = @import("std");
const examples = @import("../examples.zig");
const fuzzing = @import("../fuzzing.zig");
const sanitizers = @import("../sanitizers.zig");
const testing = @import("../testing.zig");
const vendor = @import("../vendor.zig");

/// Step handles produced by the native testing graph.
pub const Steps = testing.Steps;

pub fn inject(
    b: *std.Build,
    version: std.SemanticVersion,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    target_is_native: bool,
) Steps {
    const sanitizer = sanitizers.configure(b, target, target_is_native);
    const zslay_dependency = b.dependency("zslay", .{ .target = target, .optimize = optimize });
    const xev_dependency = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const zslay = zslay_dependency.module("zslay");
    const xev = xev_dependency.module("xev");

    const module = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    module.link_libc = true;
    module.link_libcpp = true;
    module.addImport("zslay", zslay);
    module.addImport("xev", xev);

    const archive_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
        .link_libc = true,
        .link_libcpp = true,
    });
    archive_module.addImport("zslay", zslay);
    archive_module.addImport("xev", xev);

    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = archive_module,
        .version = version,
    });
    const dependencies = vendor.configure(b, target, optimize, target_is_native, sanitizer);
    dependencies.add_includes(module);
    dependencies.add_includes(archive_module);
    module.addImport("c", dependencies.c_module);
    archive_module.addImport("c", dependencies.c_module);
    archive_module.addCSourceFile(.{
        .file = b.path("src/quic/lsquic_shim.c"),
        .flags = sanitizer.c_flags(),
    });
    vendor.add_platform_libraries(archive_module, target);
    dependencies.add_build_dependencies(library);
    module.linkLibrary(library);
    dependencies.link(module);
    sanitizer.attach(module);

    const archive_check = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/check_static_archive.sh") });
    archive_check.addFileArg(library.getEmittedBin());
    const install_library = b.addInstallArtifact(library, .{});
    install_library.step.dependOn(&archive_check.step);
    b.getInstallStep().dependOn(&install_library.step);
    const library_step = b.step("lib", "Build and install only the static library");
    library_step.dependOn(&install_library.step);

    const install_header = b.addInstallHeaderFile(b.path("include/uWebZockets.h"), "uWebZockets.h");
    b.getInstallStep().dependOn(&install_header.step);
    library_step.dependOn(&install_header.step);
    install_vendor_libraries(b, dependencies, library_step);

    examples.inject(b, target, optimize, module, dependencies, sanitizer);
    const test_steps = testing.inject(
        b,
        target,
        optimize,
        module,
        library,
        archive_check,
        dependencies,
        sanitizer,
        zslay,
        xev,
    );
    fuzzing.inject(b, target, optimize, dependencies, sanitizer, zslay, xev);
    return .{ .test_step = test_steps.test_step, .test_compile = test_steps.test_compile };
}

fn install_vendor_libraries(
    b: *std.Build,
    dependencies: vendor.Artifacts,
    library_step: *std.Build.Step,
) void {
    const ssl = b.addInstallLibFile(
        .{ .cwd_relative = b.pathJoin(&.{ dependencies.bssl_build_dir, "libssl.a" }) },
        "libssl.a",
    );
    ssl.step.dependOn(&dependencies.bssl_step.step);
    const crypto = b.addInstallLibFile(
        .{ .cwd_relative = b.pathJoin(&.{ dependencies.bssl_build_dir, "libcrypto.a" }) },
        "libcrypto.a",
    );
    crypto.step.dependOn(&dependencies.bssl_step.step);
    const lsquic = b.addInstallLibFile(
        .{ .cwd_relative = b.pathJoin(&.{
            dependencies.lsquic_build_dir,
            "src",
            "liblsquic",
            "liblsquic.a",
        }) },
        "liblsquic.a",
    );
    lsquic.step.dependOn(&dependencies.lsquic_step.step);
    const deflate = b.addInstallLibFile(
        .{ .cwd_relative = b.pathJoin(&.{ dependencies.deflate_build_dir, "libdeflate.a" }) },
        "libdeflate.a",
    );
    deflate.step.dependOn(&dependencies.deflate_step.step);
    b.getInstallStep().dependOn(&ssl.step);
    b.getInstallStep().dependOn(&crypto.step);
    b.getInstallStep().dependOn(&lsquic.step);
    b.getInstallStep().dependOn(&deflate.step);
    library_step.dependOn(&ssl.step);
    library_step.dependOn(&crypto.step);
    library_step.dependOn(&lsquic.step);
    library_step.dependOn(&deflate.step);
}
