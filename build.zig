const std = @import("std");
const builtin = @import("builtin");

const SanitizerRunConfig = struct {
    enabled: bool,
    dynamic_linker: ?[]const u8,
    library_path: []const u8,
    shared_object: []const u8,
};

pub fn build(b: *std.Build) void {
    const default_target = if (b.graph.environ_map.get("UWEBZOCKETS_DEFAULT_TARGET")) |triple|
        std.Target.Query.parse(.{ .arch_os_abi = triple }) catch {
            @panic("UWEBZOCKETS_DEFAULT_TARGET is not a valid Zig target");
        }
    else
        std.Target.Query{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => @panic("uWebZockets supports POSIX targets only"),
    }
    const target_is_native = target.query.isNative() or
        (target.result.cpu.arch == builtin.cpu.arch and
            target.result.os.tag == builtin.os.tag);
    const optimize = b.standardOptimizeOption(.{});
    const sanitize = b.option(
        bool,
        "sanitize",
        "Enable native Linux ASan and UBSan instrumentation",
    ) orelse false;
    const memory_sanitize = b.option(
        bool,
        "memory-sanitize",
        "Enable native x86_64 Linux MemorySanitizer instrumentation",
    ) orelse false;
    const instrument_c = sanitize or memory_sanitize;
    const sanitizer_lib_dir = b.option(
        []const u8,
        "sanitizer-lib-dir",
        "Directory containing the LLVM ASan runtime library",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIB_DIR");
    const sanitizer_libc_dir = b.option(
        []const u8,
        "sanitizer-libc-dir",
        "Directory containing the libc used by the sanitizer runtimes",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIBC_DIR");
    const sanitizer_dynamic_linker = b.option(
        []const u8,
        "sanitizer-dynamic-linker",
        "Dynamic linker used by native sanitizer executables",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_DYNAMIC_LINKER");
    if (sanitize and memory_sanitize) {
        @panic("address/undefined and memory sanitizers are mutually exclusive");
    }
    if (instrument_c and (!target_is_native or target.result.os.tag != .linux)) {
        @panic("sanitizer instrumentation requires a native Linux target");
    }
    if (memory_sanitize and target.result.cpu.arch != .x86_64) {
        @panic("-Dmemory-sanitize=true supports native x86_64 Linux");
    }
    if (instrument_c and sanitizer_lib_dir == null) {
        @panic("sanitizers require -Dsanitizer-lib-dir or UWEBZOCKETS_SANITIZER_LIB_DIR");
    }
    if (instrument_c and (sanitizer_libc_dir == null) != (sanitizer_dynamic_linker == null)) {
        @panic("sanitizer libc directory and dynamic linker must be configured together");
    }
    const sanitizer_runtime_name = if (sanitize)
        switch (target.result.cpu.arch) {
            .x86_64 => "clang_rt.asan-x86_64",
            .aarch64 => "clang_rt.asan-aarch64",
            else => @panic("-Dsanitize=true supports x86_64 and aarch64"),
        }
    else
        "";
    const sanitizer_shared_object = if (sanitize)
        b.pathJoin(&.{
            sanitizer_lib_dir.?,
            b.fmt("lib{s}.so", .{sanitizer_runtime_name}),
        })
    else
        "";
    const sanitizer_library_path = if (!sanitize)
        ""
    else if (sanitizer_libc_dir) |libc_dir|
        b.fmt("{s}:{s}", .{ sanitizer_lib_dir.?, libc_dir })
    else
        sanitizer_lib_dir.?;
    const sanitizer_run_config: SanitizerRunConfig = .{
        .enabled = sanitize,
        .dynamic_linker = sanitizer_dynamic_linker,
        .library_path = sanitizer_library_path,
        .shared_object = sanitizer_shared_object,
    };
    const zlib_prefix = b.option(
        []const u8,
        "zlib-prefix",
        "Path containing zlib include/ and lib/ directories",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_ZLIB_PREFIX");
    const cmake_exe = b.option([]const u8, "cmake", "CMake executable") orelse "cmake";
    const ninja_exe = b.option([]const u8, "ninja", "Ninja executable") orelse "ninja";
    const patch_exe = b.option([]const u8, "patch", "Patch executable") orelse "patch";
    const c_compiler = b.option(
        []const u8,
        "c-compiler",
        "C compiler used for vendored dependencies",
    ) orelse b.pathFromRoot("zig-cc");
    const cxx_compiler = b.option(
        []const u8,
        "cxx-compiler",
        "C++ compiler used for vendored dependencies",
    ) orelse b.pathFromRoot("zig-c++");
    const asm_compiler = b.option(
        []const u8,
        "asm-compiler",
        "Assembler compiler used for vendored dependencies",
    ) orelse c_compiler;

    const mod = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (instrument_c) false else null,
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

    const archive_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (instrument_c) false else null,
        .link_libc = true,
        .link_libcpp = true,
    });
    archive_mod.addImport("zslay", zslay_dep.module("zslay"));
    archive_mod.addImport("xev", libxev_dep.module("xev"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = archive_mod,
    });
    mod.linkLibrary(lib);
    const archive_check = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("scripts/check_static_archive.sh"),
    });
    archive_check.addFileArg(lib.getEmittedBin());

    // --- Vendor Dependencies Orchestration ---
    const target_triple = target.result.zigTriple(b.allocator) catch @panic("out of memory");
    const target_key = b.fmt(
        "{s}-{s}-{s}",
        .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        },
    );
    const cmake_build_type = cmake_build_type_name(optimize);
    const vendor_build = if (sanitize)
        b.fmt(
            ".zig-cache/vendor-build-v2/{s}-{s}-address-sanitize",
            .{ target_key, @tagName(optimize) },
        )
    else if (memory_sanitize)
        b.fmt(
            ".zig-cache/vendor-build-v2/{s}-{s}-memory-sanitize",
            .{ target_key, @tagName(optimize) },
        )
    else
        b.fmt(
            ".zig-cache/vendor-build-v2/{s}-{s}",
            .{ target_key, @tagName(optimize) },
        );
    const cmake_c = b.fmt("-DCMAKE_C_COMPILER={s}", .{c_compiler});
    const cmake_cxx = b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cxx_compiler});
    const cmake_asm = b.fmt("-DCMAKE_ASM_COMPILER={s}", .{asm_compiler});
    const cmake_type = b.fmt("-DCMAKE_BUILD_TYPE={s}", .{cmake_build_type});
    const cmake_make = b.fmt("-DCMAKE_MAKE_PROGRAM={s}", .{ninja_exe});
    const sanitizer_link_flags = if (!sanitize)
        ""
    else if (sanitizer_libc_dir) |libc_dir|
        b.fmt(
            "-DCMAKE_EXE_LINKER_FLAGS=-L{s} -Wl,-rpath,{s} -Wl,-rpath,{s} -Wl,--no-as-needed -l{s}",
            .{
                sanitizer_lib_dir.?,
                sanitizer_lib_dir.?,
                libc_dir,
                sanitizer_runtime_name,
            },
        )
    else
        b.fmt(
            "-DCMAKE_EXE_LINKER_FLAGS=-L{s} -Wl,-rpath,{s} -Wl,--no-as-needed -l{s}",
            .{ sanitizer_lib_dir.?, sanitizer_lib_dir.?, sanitizer_runtime_name },
        );
    const memory_sanitizer_link_flags = if (memory_sanitize)
        "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer"
    else
        "";

    // 1. BoringSSL
    const bssl_dependency = b.dependency("boringssl", .{});
    const bssl_root = bssl_dependency.path("");
    const bssl_src = bssl_root.getPath(b);
    const bssl_build_dir = b.pathJoin(&.{ vendor_build, "boringssl" });
    const bssl_cmake = b.addSystemCommand(&.{ cmake_exe, "-B", bssl_build_dir, "-S", bssl_src, "-GNinja", cmake_make, cmake_type, "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", cmake_c, cmake_cxx, cmake_asm });
    if (sanitize) {
        bssl_cmake.addArgs(&.{
            "-DASAN=ON",
            "-DUBSAN=ON",
            "-DUBSAN_RECOVER=OFF",
            sanitizer_link_flags,
        });
    } else if (memory_sanitize) {
        bssl_cmake.addArgs(&.{
            "-DMSAN=ON",
            memory_sanitizer_link_flags,
        });
    }
    add_cross_cmake_args(b, bssl_cmake, target, target_is_native, instrument_c);
    set_vendor_environment(b, bssl_cmake, target_triple);
    const bssl_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", bssl_build_dir, "ssl", "crypto" });
    set_vendor_environment(b, bssl_ninja, target_triple);
    bssl_ninja.step.dependOn(&bssl_cmake.step);

    // 2. lsquic
    const lsquic_dependency = b.dependency("lsquic", .{});
    const lsqpack_dependency = b.dependency("lsqpack", .{});
    const lshpack_dependency = b.dependency("lshpack", .{});
    const lsquic_source = b.addWriteFiles();
    _ = lsquic_source.addCopyDirectory(lsquic_dependency.path(""), "", .{});
    _ = lsquic_source.addCopyDirectory(
        lsqpack_dependency.path(""),
        "src/liblsquic/ls-qpack",
        .{},
    );
    _ = lsquic_source.addCopyDirectory(
        lshpack_dependency.path(""),
        "src/lshpack",
        .{},
    );
    if (target.result.abi.isMusl()) {
        _ = lsquic_source.addCopyFile(
            lshpack_dependency.path("compat/queue/sys/queue.h"),
            "include/sys/queue.h",
        );
    }
    const lsquic_unpatched_root = lsquic_source.getDirectory();
    const prepare_lsquic = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("scripts/prepare_lsquic_source.sh"),
    });
    prepare_lsquic.addDirectoryArg(lsquic_unpatched_root);
    const lsquic_source_dir = b.pathJoin(&.{ vendor_build, "lsquic-source" });
    prepare_lsquic.addArg(lsquic_source_dir);
    prepare_lsquic.addFileArg(b.path("patches/lsquic_h3_message_error.patch"));
    prepare_lsquic.addArg(patch_exe);
    const lsquic_root: std.Build.LazyPath = .{ .cwd_relative = lsquic_source_dir };
    const lsquic_build_dir = b.pathJoin(&.{ vendor_build, "lsquic" });
    const lsquic_cmake = b.addSystemCommand(&.{
        cmake_exe, "-B", lsquic_build_dir, "-S", lsquic_source_dir,
    });
    lsquic_cmake.addArgs(&.{
        "-GNinja",
        cmake_make,
        cmake_type,
        "-DBUILD_SHARED_LIBS=OFF",
        cmake_c,
        cmake_cxx,
        cmake_asm,
        "-DLSQUIC_BIN=OFF",
        "-DLSQUIC_TESTS=OFF",
        b.fmt("-DBORINGSSL_DIR={s}", .{bssl_src}),
    });
    if (sanitize) {
        lsquic_cmake.addArgs(&.{
            "-DLSQUIC_ASAN=OFF",
            "-DCMAKE_C_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            "-DCMAKE_CXX_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            sanitizer_link_flags,
        });
    } else if (memory_sanitize) {
        lsquic_cmake.addArgs(&.{
            "-DCMAKE_C_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer",
            "-DCMAKE_CXX_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer",
            memory_sanitizer_link_flags,
        });
    }
    add_cross_cmake_args(b, lsquic_cmake, target, target_is_native, instrument_c);
    set_vendor_environment(b, lsquic_cmake, target_triple);
    if (zlib_prefix) |prefix| {
        lsquic_cmake.addArg(b.fmt("-DZLIB_INCLUDE_DIR={s}/include", .{prefix}));
        lsquic_cmake.addArg(b.fmt("-DZLIB_LIB={s}/lib/libz.a", .{prefix}));
    }
    const lsquic_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", lsquic_build_dir });
    set_vendor_environment(b, lsquic_ninja, target_triple);
    lsquic_cmake.step.dependOn(&prepare_lsquic.step);
    lsquic_cmake.step.dependOn(&bssl_ninja.step);
    lsquic_ninja.step.dependOn(&lsquic_cmake.step);
    lsquic_ninja.step.dependOn(&bssl_ninja.step);

    // 3. libdeflate
    const deflate_dependency = b.dependency("libdeflate", .{});
    const deflate_root = deflate_dependency.path("");
    const deflate_src = deflate_root.getPath(b);
    const deflate_build_dir = b.pathJoin(&.{ vendor_build, "libdeflate" });
    const deflate_c_flags = if (sanitize)
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI -fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
    else if (memory_sanitize)
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI -fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer"
    else
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI";
    const deflate_cmake = b.addSystemCommand(&.{ cmake_exe, "-B", deflate_build_dir, "-S", deflate_src, "-GNinja", cmake_make, cmake_type, "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_TESTS=OFF", "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF", b.fmt("-DCMAKE_C_FLAGS={s}", .{deflate_c_flags}), cmake_c, cmake_cxx, cmake_asm });
    if (sanitize) deflate_cmake.addArg(sanitizer_link_flags);
    if (memory_sanitize) deflate_cmake.addArg(memory_sanitizer_link_flags);
    add_cross_cmake_args(b, deflate_cmake, target, target_is_native, instrument_c);
    set_vendor_environment(b, deflate_cmake, target_triple);
    const deflate_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", deflate_build_dir });
    set_vendor_environment(b, deflate_ninja, target_triple);
    deflate_ninja.step.dependOn(&deflate_cmake.step);

    // --- Linking to uWebZockets ---
    lib.step.dependOn(&bssl_ninja.step);
    lib.step.dependOn(&lsquic_ninja.step);
    lib.step.dependOn(&deflate_ninja.step);

    // Library paths (where the .a files are generated)
    mod.addLibraryPath(b.path(bssl_build_dir));
    mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    mod.addLibraryPath(b.path(deflate_build_dir));
    if (zlib_prefix) |prefix| {
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    // LLVM ASan must precede libc and every instrumented dependency.
    if (sanitize) {
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        mod.addLibraryPath(runtime_path);
        mod.addRPath(runtime_path);
        if (sanitizer_libc_dir) |libc_dir| {
            const libc_path: std.Build.LazyPath = .{ .cwd_relative = libc_dir };
            mod.addLibraryPath(libc_path);
            mod.addRPath(libc_path);
        }
        mod.linkSystemLibrary(sanitizer_runtime_name, .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .no_fallback,
        });
    } else if (memory_sanitize) {
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        mod.addLibraryPath(runtime_path);
        mod.linkSystemLibrary("clang_rt.msan-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
        mod.linkSystemLibrary("clang_rt.msan_cxx-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
    }

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
    translate_c.step.dependOn(&prepare_lsquic.step);
    translate_c.addIncludePath(bssl_root.path(b, "include"));
    translate_c.addIncludePath(lsquic_root.path(b, "include"));
    translate_c.addIncludePath(deflate_root);
    if (zlib_prefix) |prefix| {
        translate_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }

    mod.addIncludePath(bssl_root.path(b, "include"));
    mod.addIncludePath(lsquic_root.path(b, "include"));
    mod.addIncludePath(deflate_root);
    archive_mod.addIncludePath(bssl_root.path(b, "include"));
    archive_mod.addIncludePath(lsquic_root.path(b, "include"));
    archive_mod.addIncludePath(deflate_root);
    if (zlib_prefix) |prefix| {
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        archive_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }
    archive_mod.addCSourceFile(.{
        .file = b.path("src/quic/lsquic_shim.c"),
        .flags = if (sanitize)
            &.{ "-std=c11", "-fsanitize=address", "-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer" }
        else if (memory_sanitize)
            &.{ "-std=c11", "-fsanitize=memory", "-fsanitize-memory-track-origins", "-fno-omit-frame-pointer" }
        else
            &.{"-std=c11"},
    });

    const c_module = translate_c.createModule();
    mod.addImport("c", c_module);
    archive_mod.addImport("c", c_module);

    const install_lib = b.addInstallArtifact(lib, .{});
    install_lib.step.dependOn(&archive_check.step);
    b.getInstallStep().dependOn(&install_lib.step);
    const library_step = b.step("lib", "Build and install only the static library");
    library_step.dependOn(&install_lib.step);

    const install_c_header = b.addInstallHeaderFile(
        b.path("include/uWebZockets.h"),
        "uWebZockets.h",
    );
    b.getInstallStep().dependOn(&install_c_header.step);
    library_step.dependOn(&install_c_header.step);

    const install_ssl = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ bssl_build_dir, "libssl.a" })) },
        "libssl.a",
    );
    install_ssl.step.dependOn(&bssl_ninja.step);
    b.getInstallStep().dependOn(&install_ssl.step);
    library_step.dependOn(&install_ssl.step);

    const install_crypto = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ bssl_build_dir, "libcrypto.a" })) },
        "libcrypto.a",
    );
    install_crypto.step.dependOn(&bssl_ninja.step);
    b.getInstallStep().dependOn(&install_crypto.step);
    library_step.dependOn(&install_crypto.step);

    const install_lsquic = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic", "liblsquic.a" })) },
        "liblsquic.a",
    );
    install_lsquic.step.dependOn(&lsquic_ninja.step);
    b.getInstallStep().dependOn(&install_lsquic.step);
    library_step.dependOn(&install_lsquic.step);

    const install_deflate = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ deflate_build_dir, "libdeflate.a" })) },
        "libdeflate.a",
    );
    install_deflate.step.dependOn(&deflate_ninja.step);
    b.getInstallStep().dependOn(&install_deflate.step);
    library_step.dependOn(&install_deflate.step);

    const msan_step = b.step(
        "msan",
        "Run the fully instrumented C/C++ dependency boundary smoke test",
    );
    if (!memory_sanitize) {
        const require_msan = b.addFail("msan requires -Dmemory-sanitize=true");
        msan_step.dependOn(&require_msan.step);
    } else {
        const msan_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
            .omit_frame_pointer = false,
        });
        msan_mod.addIncludePath(bssl_root.path(b, "include"));
        msan_mod.addIncludePath(lsquic_root.path(b, "include"));
        msan_mod.addIncludePath(deflate_root);
        msan_mod.addCSourceFile(.{
            .file = b.path("tests/sanitizers/msan_smoke.c"),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fsanitize=memory",
                "-fsanitize-memory-track-origins",
                "-fno-omit-frame-pointer",
                "-fPIE",
            },
        });
        msan_mod.addLibraryPath(b.path(bssl_build_dir));
        msan_mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
        msan_mod.addLibraryPath(b.path(deflate_build_dir));
        if (zlib_prefix) |prefix| {
            msan_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        }
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        msan_mod.addLibraryPath(runtime_path);
        msan_mod.linkSystemLibrary("ssl", .{});
        msan_mod.linkSystemLibrary("crypto", .{});
        msan_mod.linkSystemLibrary("lsquic", .{});
        msan_mod.linkSystemLibrary("deflate", .{});
        msan_mod.linkSystemLibrary("z", .{});
        msan_mod.linkSystemLibrary("clang_rt.msan_cxx-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
        msan_mod.linkSystemLibrary("clang_rt.msan-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });

        const msan_smoke = b.addExecutable(.{
            .name = "msan_smoke",
            .root_module = msan_mod,
        });
        msan_smoke.pie = true;
        msan_smoke.step.dependOn(&bssl_ninja.step);
        msan_smoke.step.dependOn(&lsquic_ninja.step);
        msan_smoke.step.dependOn(&deflate_ninja.step);
        msan_smoke.step.dependOn(&lib.step);
        const run_msan_smoke = add_run_artifact(b, msan_smoke, .{
            .enabled = false,
            .dynamic_linker = null,
            .library_path = "",
            .shared_object = "",
        });
        msan_step.dependOn(&run_msan_smoke.step);
    }

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

    const run_hello_world = add_run_artifact(b, hello_world_exe, sanitizer_run_config);
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
    chat_server_exe.step.dependOn(&bssl_ninja.step);
    chat_server_exe.step.dependOn(&lsquic_ninja.step);
    chat_server_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(chat_server_exe);

    const run_chat_server = add_run_artifact(b, chat_server_exe, sanitizer_run_config);
    const chat_server_step = b.step("chat_server", "Run the chat_server example");
    chat_server_step.dependOn(&run_chat_server.step);

    const http3_server_exe = b.addExecutable(.{
        .name = "http3_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http3_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http3_server_exe.root_module.addImport("uWebZockets", mod);
    http3_server_exe.step.dependOn(&bssl_ninja.step);
    http3_server_exe.step.dependOn(&lsquic_ninja.step);
    http3_server_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(http3_server_exe);
    const run_http3_server = add_run_artifact(b, http3_server_exe, sanitizer_run_config);
    const http3_server_step = b.step("http3_server", "Run the HTTP/3 example server");
    http3_server_step.dependOn(&run_http3_server.step);

    const h1spec_exe = b.addExecutable(.{
        .name = "h1spec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/h1spec/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    h1spec_exe.root_module.addImport("uWebZockets", mod);
    h1spec_exe.step.dependOn(&bssl_ninja.step);
    h1spec_exe.step.dependOn(&lsquic_ninja.step);
    h1spec_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(h1spec_exe);

    const run_h1spec = add_run_artifact(b, h1spec_exe, sanitizer_run_config);
    const h1spec_step = b.step("h1spec", "Run the h1spec compliance server");
    h1spec_step.dependOn(&run_h1spec.step);

    const autobahn_exe = b.addExecutable(.{
        .name = "autobahn_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/autobahn/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    autobahn_exe.root_module.addImport("uWebZockets", mod);
    autobahn_exe.step.dependOn(&bssl_ninja.step);
    autobahn_exe.step.dependOn(&lsquic_ninja.step);
    autobahn_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(autobahn_exe);

    const run_autobahn = add_run_artifact(b, autobahn_exe, sanitizer_run_config);
    const autobahn_step = b.step("autobahn", "Run the Autobahn compliance server");
    autobahn_step.dependOn(&run_autobahn.step);

    const http2_mod = b.createModule(.{
        .root_source_file = b.path("src/http2/connection.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http2_hpack_mod = b.createModule(.{
        .root_source_file = b.path("src/http2/hpack.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_support_mod = b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support_mod.addImport("c", c_module);
    test_support_mod.addImport("xev", libxev_dep.module("xev"));
    test_support_mod.addImport("zslay", zslay_dep.module("zslay"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (instrument_c) false else null,
    });
    test_mod.addImport("c", c_module);
    test_mod.addImport("xev", libxev_dep.module("xev"));
    test_mod.addImport("zslay", zslay_dep.module("zslay"));
    test_mod.addImport("http2", http2_mod);
    test_mod.addImport("http2_hpack", http2_hpack_mod);
    test_mod.addImport("test_support", test_support_mod);
    test_mod.linkLibrary(lib);
    test_mod.addLibraryPath(b.path(bssl_build_dir));
    test_mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    test_mod.addLibraryPath(b.path(deflate_build_dir));
    if (zlib_prefix) |prefix| {
        test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }
    test_mod.linkSystemLibrary("ssl", .{});
    test_mod.linkSystemLibrary("crypto", .{});
    test_mod.linkSystemLibrary("lsquic", .{});
    test_mod.linkSystemLibrary("deflate", .{});
    test_mod.linkSystemLibrary("z", .{});
    if (sanitize) {
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        test_mod.addLibraryPath(runtime_path);
        test_mod.addRPath(runtime_path);
        if (sanitizer_libc_dir) |libc_dir| {
            const libc_path: std.Build.LazyPath = .{ .cwd_relative = libc_dir };
            test_mod.addLibraryPath(libc_path);
            test_mod.addRPath(libc_path);
        }
        test_mod.linkSystemLibrary(sanitizer_runtime_name, .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .no_fallback,
        });
    } else if (memory_sanitize) {
        test_mod.addLibraryPath(.{ .cwd_relative = sanitizer_lib_dir.? });
        test_mod.linkSystemLibrary("clang_rt.msan-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
        test_mod.linkSystemLibrary("clang_rt.msan_cxx-x86_64", .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .static,
            .search_strategy = .no_fallback,
        });
    }

    const centralized_tests = b.addTest(.{
        .root_module = test_mod,
    });
    centralized_tests.step.dependOn(&bssl_ninja.step);
    centralized_tests.step.dependOn(&lsquic_ninja.step);
    centralized_tests.step.dependOn(&deflate_ninja.step);
    const run_centralized_tests = add_run_artifact(
        b,
        centralized_tests,
        sanitizer_run_config,
    );

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_centralized_tests.step);
    test_step.dependOn(&archive_check.step);

    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&centralized_tests.step);
    test_compile_step.dependOn(&archive_check.step);

    const c_api_smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (instrument_c) false else null,
    });
    c_api_smoke_mod.addIncludePath(b.path("include"));
    c_api_smoke_mod.addCSourceFile(.{
        .file = b.path("tests/c_api/smoke.c"),
        .flags = if (sanitize)
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-fsanitize=address", "-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer" }
        else
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    c_api_smoke_mod.linkLibrary(lib);
    c_api_smoke_mod.addLibraryPath(b.path(bssl_build_dir));
    c_api_smoke_mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    c_api_smoke_mod.addLibraryPath(b.path(deflate_build_dir));
    if (zlib_prefix) |prefix| {
        c_api_smoke_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }
    c_api_smoke_mod.linkSystemLibrary("ssl", .{});
    c_api_smoke_mod.linkSystemLibrary("crypto", .{});
    c_api_smoke_mod.linkSystemLibrary("lsquic", .{});
    c_api_smoke_mod.linkSystemLibrary("deflate", .{});
    c_api_smoke_mod.linkSystemLibrary("z", .{});
    if (sanitize) {
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        c_api_smoke_mod.addLibraryPath(runtime_path);
        c_api_smoke_mod.addRPath(runtime_path);
        if (sanitizer_libc_dir) |libc_dir| {
            const libc_path: std.Build.LazyPath = .{ .cwd_relative = libc_dir };
            c_api_smoke_mod.addLibraryPath(libc_path);
            c_api_smoke_mod.addRPath(libc_path);
        }
        c_api_smoke_mod.linkSystemLibrary(sanitizer_runtime_name, .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .no_fallback,
        });
    }
    const c_api_smoke = b.addExecutable(.{
        .name = "c_api_smoke",
        .root_module = c_api_smoke_mod,
    });
    const run_c_api_smoke = add_run_artifact(b, c_api_smoke, sanitizer_run_config);
    test_step.dependOn(&run_c_api_smoke.step);
    test_compile_step.dependOn(&c_api_smoke.step);

    const c_api_cpp_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    c_api_cpp_mod.addIncludePath(b.path("include"));
    c_api_cpp_mod.addCSourceFile(.{
        .file = b.path("tests/c_api/header_cpp.cc"),
        .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    const c_api_cpp = b.addObject(.{
        .name = "c_api_header_cpp",
        .root_module = c_api_cpp_mod,
    });
    test_step.dependOn(&c_api_cpp.step);
    test_compile_step.dependOn(&c_api_cpp.step);

    const legacy_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/fuzz_main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (instrument_c) false else null,
    });
    legacy_fuzz_mod.addImport("test_support", test_support_mod);
    legacy_fuzz_mod.addImport("zslay", zslay_dep.module("zslay"));
    const legacy_fuzz_tests = b.addTest(.{ .root_module = legacy_fuzz_mod });
    const run_legacy_fuzz_tests = add_run_artifact(
        b,
        legacy_fuzz_tests,
        sanitizer_run_config,
    );

    const fuzz_support_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_support_mod.addImport("zslay", zslay_dep.module("zslay"));

    const http_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/http_framing.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_fuzz_mod.addImport("fuzz_support", fuzz_support_mod);
    const http_fuzz_object = b.addObject(.{
        .name = "http_framing",
        .root_module = http_fuzz_mod,
    });
    http_fuzz_object.sanitize_coverage_trace_pc_guard = true;

    const ws_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/ws_masking.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_fuzz_mod.addImport("fuzz_support", fuzz_support_mod);
    const ws_fuzz_object = b.addObject(.{
        .name = "ws_masking",
        .root_module = ws_fuzz_mod,
    });
    ws_fuzz_object.sanitize_coverage_trace_pc_guard = true;

    const quic_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/quic_packets.zig"),
        .target = target,
        .optimize = optimize,
    });
    quic_fuzz_mod.addImport("fuzz_support", fuzz_support_mod);
    const quic_fuzz_object = b.addObject(.{
        .name = "quic_packets",
        .root_module = quic_fuzz_mod,
    });
    quic_fuzz_object.sanitize_coverage_trace_pc_guard = true;

    const install_http_fuzz_object = b.addInstallArtifact(http_fuzz_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "http_framing.o",
    });
    const install_ws_fuzz_object = b.addInstallArtifact(ws_fuzz_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "ws_masking.o",
    });
    const install_quic_fuzz_object = b.addInstallArtifact(quic_fuzz_object, .{
        .dest_dir = .{ .override = .{ .custom = "oss-fuzz" } },
        .dest_sub_path = "quic_packets.o",
    });
    const oss_fuzz_objects_step = b.step(
        "oss-fuzz-objects",
        "Build libFuzzer ABI objects with sanitizer coverage",
    );
    oss_fuzz_objects_step.dependOn(&install_http_fuzz_object.step);
    oss_fuzz_objects_step.dependOn(&install_ws_fuzz_object.step);
    oss_fuzz_objects_step.dependOn(&install_quic_fuzz_object.step);

    const http_smoke_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/smoke_http.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_smoke_mod.addImport("fuzz_support", fuzz_support_mod);
    const http_smoke = b.addExecutable(.{
        .name = "http_framing_smoke",
        .root_module = http_smoke_mod,
    });

    const ws_smoke_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/smoke_ws.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_smoke_mod.addImport("fuzz_support", fuzz_support_mod);
    const ws_smoke = b.addExecutable(.{
        .name = "ws_masking_smoke",
        .root_module = ws_smoke_mod,
    });

    const quic_smoke_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/smoke_quic.zig"),
        .target = target,
        .optimize = optimize,
    });
    quic_smoke_mod.addImport("fuzz_support", fuzz_support_mod);
    const quic_smoke = b.addExecutable(.{
        .name = "quic_packets_smoke",
        .root_module = quic_smoke_mod,
    });

    const run_http_smoke = add_run_artifact(b, http_smoke, sanitizer_run_config);
    const run_ws_smoke = add_run_artifact(b, ws_smoke, sanitizer_run_config);
    const run_quic_smoke = add_run_artifact(b, quic_smoke, sanitizer_run_config);
    const oss_fuzz_smoke_step = b.step(
        "oss-fuzz-smoke",
        "Run deterministic protocol-boundary fuzz smoke inputs",
    );
    oss_fuzz_smoke_step.dependOn(&run_http_smoke.step);
    oss_fuzz_smoke_step.dependOn(&run_ws_smoke.step);
    oss_fuzz_smoke_step.dependOn(&run_quic_smoke.step);

    const oss_fuzz_step = b.step(
        "oss-fuzz",
        "Build OSS-Fuzz objects and run deterministic smoke inputs",
    );
    oss_fuzz_step.dependOn(oss_fuzz_objects_step);
    oss_fuzz_step.dependOn(oss_fuzz_smoke_step);

    const fuzz_step = b.step("fuzz", "Run deterministic parser fuzz smoke inputs");
    fuzz_step.dependOn(&run_legacy_fuzz_tests.step);
    fuzz_step.dependOn(oss_fuzz_smoke_step);
}

fn cmake_build_type_name(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast, .ReleaseSmall => "Release",
    };
}

fn add_cross_cmake_args(
    b: *std.Build,
    command: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
    target_is_native: bool,
    sanitize: bool,
) void {
    if (target_is_native) {
        if (sanitize) command.addArg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
        return;
    }

    const system_name: []const u8 = switch (target.result.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFlyBSD",
        else => return,
    };
    const processor: []const u8 = switch (target.result.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm",
        .aarch64 => "aarch64",
        else => @tagName(target.result.cpu.arch),
    };

    command.addArg(b.fmt("-DCMAKE_SYSTEM_NAME={s}", .{system_name}));
    command.addArg(b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{processor}));
    command.addArg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
}

fn set_vendor_environment(
    b: *std.Build,
    command: *std.Build.Step.Run,
    target_triple: []const u8,
) void {
    command.setEnvironmentVariable("UWEBZOCKETS_ZIG", b.graph.zig_exe);
    command.setEnvironmentVariable("UWEBZOCKETS_TARGET", target_triple);
}

fn add_run_artifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    sanitizer: SanitizerRunConfig,
) *std.Build.Step.Run {
    if (!sanitizer.enabled) {
        const dynamic_linker = b.graph.environ_map.get(
            "UWEBZOCKETS_RUNTIME_DYNAMIC_LINKER",
        ) orelse return b.addRunArtifact(artifact);
        const library_path = b.graph.environ_map.get(
            "UWEBZOCKETS_RUNTIME_LIBRARY_PATH",
        ) orelse @panic("Nix runtime loader requires its library path");

        if (artifact.kind == .@"test") {
            artifact.setExecCmd(&.{
                dynamic_linker,
                "--library-path",
                library_path,
                null,
            });
            return b.addRunArtifact(artifact);
        }

        const command = b.addSystemCommand(&.{
            dynamic_linker,
            "--library-path",
            library_path,
        });
        command.addArtifactArg(artifact);
        return command;
    }

    const dynamic_linker = sanitizer.dynamic_linker orelse {
        const command = b.addRunArtifact(artifact);
        command.setEnvironmentVariable("LD_PRELOAD", sanitizer.shared_object);
        return command;
    };
    if (artifact.kind == .@"test") {
        artifact.setExecCmd(&.{
            dynamic_linker,
            "--library-path",
            sanitizer.library_path,
            "--preload",
            sanitizer.shared_object,
            null,
        });
        return b.addRunArtifact(artifact);
    }

    const command = b.addSystemCommand(&.{
        dynamic_linker,
        "--library-path",
        sanitizer.library_path,
        "--preload",
        sanitizer.shared_object,
    });
    command.addArtifactArg(artifact);
    return command;
}
