const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uWebZockets", .module = mod },
            },
        }),
    });

    // --- Vendor Dependencies Orchestration ---
    const vendor_build = ".zig-cache/vendor-build";

    // 1. BoringSSL
    const bssl_src = "vendor/boringssl";
    const bssl_build_dir = b.pathJoin(&.{ vendor_build, "boringssl" });
    const bssl_cmake = b.addSystemCommand(&.{
        "cmake",   "-B",                         bssl_build_dir,            "-S", bssl_src,
        "-GNinja", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
    });
    const bssl_ninja = b.addSystemCommand(&.{ "ninja", "-C", bssl_build_dir });
    bssl_ninja.step.dependOn(&bssl_cmake.step);

    // 2. lsquic
    const lsquic_src = "vendor/lsquic";
    const lsquic_build_dir = b.pathJoin(&.{ vendor_build, "lsquic" });
    const lsquic_cmake = b.addSystemCommand(&.{
        "cmake",   "-B",                         lsquic_build_dir,          "-S",                                                      lsquic_src,
        "-GNinja", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
        // Give lsquic the path to boringssl so it finds the headers and libs
        b.fmt("-DBORINGSSL_DIR={s}", .{b.pathFromRoot(bssl_src)}),
    });
    const lsquic_ninja = b.addSystemCommand(&.{ "ninja", "-C", lsquic_build_dir });
    lsquic_ninja.step.dependOn(&lsquic_cmake.step);
    lsquic_ninja.step.dependOn(&bssl_ninja.step);

    // 3. libdeflate
    const deflate_src = "vendor/libdeflate";
    const deflate_build_dir = b.pathJoin(&.{ vendor_build, "libdeflate" });
    const deflate_cmake = b.addSystemCommand(&.{
        "cmake",   "-B",                         deflate_build_dir,             "-S",                                deflate_src,
        "-GNinja", "-DCMAKE_BUILD_TYPE=Release", "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF",
    });
    const deflate_ninja = b.addSystemCommand(&.{ "ninja", "-C", deflate_build_dir });
    deflate_ninja.step.dependOn(&deflate_cmake.step);

    // --- Linking to uWebZockets ---
    lib.step.dependOn(&bssl_ninja.step);
    lib.step.dependOn(&lsquic_ninja.step);
    lib.step.dependOn(&deflate_ninja.step);

    // Library paths (where the .a files are generated)
    lib.addLibraryPath(b.path(b.pathJoin(&.{ bssl_build_dir, "ssl" })));
    lib.addLibraryPath(b.path(b.pathJoin(&.{ bssl_build_dir, "crypto" })));
    lib.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    lib.addLibraryPath(b.path(deflate_build_dir));

    // System libraries
    lib.linkSystemLibrary("ssl");
    lib.linkSystemLibrary("crypto");
    lib.linkSystemLibrary("lsquic");
    lib.linkSystemLibrary("deflate");

    // Include paths (so src/c.zig can @cImport them)
    lib.addIncludePath(b.path(b.pathJoin(&.{ bssl_src, "include" })));
    lib.addIncludePath(b.path(b.pathJoin(&.{ lsquic_src, "include" })));
    lib.addIncludePath(b.path(deflate_src));

    b.installArtifact(lib);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_lib_tests.step);
}
