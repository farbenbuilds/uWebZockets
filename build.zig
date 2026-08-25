const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.link_libc = true;
    mod.link_libcpp = true;

    // --- Zig Dependencies ---
    const zslay_dep = b.dependency("zslay", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zslay", zslay_dep.module("zslay"));

    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("xev", libxev_dep.module("xev"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = mod,
    });

    // --- Vendor Dependencies Orchestration ---
    const vendor_build = ".zig-cache/vendor-build";

    // 1. BoringSSL
    const bssl_src = "vendor/boringssl";
    const bssl_build_dir = b.pathJoin(&.{ vendor_build, "boringssl" });
    const bssl_cmake = b.addSystemCommand(&.{ "cmake", "-B", bssl_build_dir, "-S", bssl_src, "-GNinja", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_C_COMPILER=/home/noah/uWebZockets/zig-cc", "-DCMAKE_CXX_COMPILER=/home/noah/uWebZockets/zig-c++", "-DCMAKE_ASM_COMPILER=/home/noah/uWebZockets/zig-cc" });
    const bssl_ninja = b.addSystemCommand(&.{ "ninja", "-C", bssl_build_dir, "ssl", "crypto" });
    bssl_ninja.step.dependOn(&bssl_cmake.step);

    // 2. lsquic
    const lsquic_src = "vendor/lsquic";
    const lsquic_build_dir = b.pathJoin(&.{ vendor_build, "lsquic" });
    const lsquic_cmake = b.addSystemCommand(&.{
        "cmake",                                              "-B",                                                      lsquic_build_dir,          "-S",                                               lsquic_src,
        "-GNinja",                                            "-DCMAKE_BUILD_TYPE=Release",                              "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_C_COMPILER=/home/noah/uWebZockets/zig-cc", "-DCMAKE_CXX_COMPILER=/home/noah/uWebZockets/zig-c++",
        "-DCMAKE_ASM_COMPILER=/home/noah/uWebZockets/zig-cc",
        // Give lsquic the path to boringssl so it finds the headers and libs
        b.fmt("-DBORINGSSL_DIR={s}", .{b.pathFromRoot(bssl_src)}),
    });
    const lsquic_ninja = b.addSystemCommand(&.{ "ninja", "-C", lsquic_build_dir });
    lsquic_ninja.step.dependOn(&lsquic_cmake.step);
    lsquic_ninja.step.dependOn(&bssl_ninja.step);

    // 3. libdeflate
    const deflate_src = "vendor/libdeflate";
    const deflate_build_dir = b.pathJoin(&.{ vendor_build, "libdeflate" });
    const deflate_cmake = b.addSystemCommand(&.{ "cmake", "-B", deflate_build_dir, "-S", deflate_src, "-GNinja", "-DCMAKE_BUILD_TYPE=Release", "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF", "-DCMAKE_C_COMPILER=/home/noah/uWebZockets/zig-cc", "-DCMAKE_CXX_COMPILER=/home/noah/uWebZockets/zig-c++", "-DCMAKE_ASM_COMPILER=/home/noah/uWebZockets/zig-cc" });
    const deflate_ninja = b.addSystemCommand(&.{ "ninja", "-C", deflate_build_dir });
    deflate_ninja.step.dependOn(&deflate_cmake.step);

    // --- Linking to uWebZockets ---
    lib.step.dependOn(&bssl_ninja.step);
    lib.step.dependOn(&lsquic_ninja.step);
    lib.step.dependOn(&deflate_ninja.step);

    // Library paths (where the .a files are generated)
    mod.addLibraryPath(b.path(bssl_build_dir));
    mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    mod.addLibraryPath(b.path(deflate_build_dir));

    // System libraries
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});
    mod.linkSystemLibrary("lsquic", .{});
    mod.linkSystemLibrary("deflate", .{});
    mod.linkSystemLibrary("z", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path(b.pathJoin(&.{ bssl_src, "include" })));
    translate_c.addIncludePath(b.path(b.pathJoin(&.{ lsquic_src, "include" })));
    translate_c.addIncludePath(b.path(deflate_src));
    mod.addImport("c", translate_c.createModule());

    b.installArtifact(lib);

    // --- Examples ---
    const hello_world_exe = b.addExecutable(.{
        .name = "hello_world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_world.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello_world_exe.root_module.addImport("uWebZockets", mod);
    hello_world_exe.step.dependOn(&bssl_ninja.step);
    hello_world_exe.step.dependOn(&lsquic_ninja.step);
    hello_world_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(hello_world_exe);

    const run_hello_world = b.addRunArtifact(hello_world_exe);
    const hello_world_step = b.step("hello_world", "Run the hello_world example");
    hello_world_step.dependOn(&run_hello_world.step);

    const chat_server_exe = b.addExecutable(.{
        .name = "chat_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chat_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    chat_server_exe.root_module.addImport("uWebZockets", mod);
    // Note: mod's C library links and paths are transitive, but we must ensure ninja runs first.
    chat_server_exe.root_module.addImport("zslay", zslay_dep.module("zslay"));
    chat_server_exe.step.dependOn(&bssl_ninja.step);
    chat_server_exe.step.dependOn(&lsquic_ninja.step);
    chat_server_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(chat_server_exe);

    const run_chat_server = b.addRunArtifact(chat_server_exe);
    const chat_server_step = b.step("chat_server", "Run the chat_server example");
    chat_server_step.dependOn(&run_chat_server.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.step.dependOn(&bssl_ninja.step);
    mod_tests.step.dependOn(&lsquic_ninja.step);
    mod_tests.step.dependOn(&deflate_ninja.step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });
    lib_tests.step.dependOn(&bssl_ninja.step);
    lib_tests.step.dependOn(&lsquic_ninja.step);
    lib_tests.step.dependOn(&deflate_ninja.step);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_lib_tests.step);
}
