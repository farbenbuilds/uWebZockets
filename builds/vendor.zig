const builtin = @import("builtin");
const std = @import("std");
const sanitizers = @import("sanitizers.zig");

pub const Artifacts = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    bssl_root: std.Build.LazyPath,
    lsquic_root: std.Build.LazyPath,
    deflate_root: std.Build.LazyPath,
    bssl_build_dir: []const u8,
    lsquic_build_dir: []const u8,
    deflate_build_dir: []const u8,
    zlib_prefix: ?[]const u8,
    bssl_step: *std.Build.Step.Run,
    lsquic_step: *std.Build.Step.Run,
    deflate_step: *std.Build.Step.Run,
    c_module: *std.Build.Module,

    pub fn add_build_dependencies(self: Artifacts, compile: *std.Build.Step.Compile) void {
        compile.step.dependOn(&self.bssl_step.step);
        compile.step.dependOn(&self.lsquic_step.step);
        compile.step.dependOn(&self.deflate_step.step);
    }

    pub fn add_includes(self: Artifacts, module: *std.Build.Module) void {
        module.addIncludePath(self.bssl_root.path(self.b, "include"));
        module.addIncludePath(self.lsquic_root.path(self.b, "include"));
        module.addIncludePath(self.deflate_root);
        if (self.target.result.os.tag == .windows) {
            module.addIncludePath(self.lsquic_root.path(self.b, "wincompat"));
        }
        if (self.zlib_prefix) |prefix| {
            module.addIncludePath(.{ .cwd_relative = self.b.pathJoin(&.{ prefix, "include" }) });
        }
    }

    pub fn link(self: Artifacts, module: *std.Build.Module) void {
        module.addLibraryPath(.{ .cwd_relative = self.bssl_build_dir });
        module.addLibraryPath(.{ .cwd_relative = self.b.pathJoin(&.{
            self.lsquic_build_dir,
            "src",
            "liblsquic",
        }) });
        module.addLibraryPath(.{ .cwd_relative = self.deflate_build_dir });
        if (self.zlib_prefix) |prefix| {
            module.addLibraryPath(.{ .cwd_relative = self.b.pathJoin(&.{ prefix, "lib" }) });
        }
        module.linkSystemLibrary("ssl", .{});
        module.linkSystemLibrary("crypto", .{});
        module.linkSystemLibrary("lsquic", .{});
        module.linkSystemLibrary("deflate", .{});
        module.linkSystemLibrary("z", .{});
        add_platform_libraries(module, self.target);
    }
};

pub fn configure(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    target_is_native: bool,
    sanitizer: sanitizers.Config,
) Artifacts {
    const zlib_prefix = b.option(
        []const u8,
        "zlib-prefix",
        "Path containing zlib include/ and lib/ directories",
    ) orelse if (target_is_native) b.graph.environ_map.get("UWEBZOCKETS_ZLIB_PREFIX") else null;
    const cmake_exe = b.option([]const u8, "cmake", "CMake executable") orelse "cmake";
    const ninja_exe = b.option([]const u8, "ninja", "Ninja executable") orelse "ninja";
    const patch_exe = b.option([]const u8, "patch", "Patch executable") orelse "patch";
    const default_c_compiler = if (builtin.os.tag == .windows)
        b.pathFromRoot("scripts/windows/zig_cc.cmd")
    else
        b.pathFromRoot("zig-cc");
    const default_cxx_compiler = if (builtin.os.tag == .windows)
        b.pathFromRoot("scripts/windows/zig_cxx.cmd")
    else
        b.pathFromRoot("zig-c++");
    const c_compiler = b.option(
        []const u8,
        "c-compiler",
        "C compiler used for vendored dependencies",
    ) orelse default_c_compiler;
    const cxx_compiler = b.option(
        []const u8,
        "cxx-compiler",
        "C++ compiler used for vendored dependencies",
    ) orelse default_cxx_compiler;
    const asm_compiler = b.option(
        []const u8,
        "asm-compiler",
        "Assembler compiler used for vendored dependencies",
    ) orelse c_compiler;

    const target_triple = target.result.zigTriple(b.allocator) catch @panic("out of memory");
    const target_key = b.fmt("{s}-{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
    });
    const vendor_build = if (sanitizer.sanitize)
        b.fmt(".zig-cache/vendor-build-v4/{s}-{s}-address-sanitize", .{ target_key, @tagName(optimize) })
    else if (sanitizer.memory_sanitize)
        b.fmt(".zig-cache/vendor-build-v4/{s}-{s}-memory-sanitize", .{ target_key, @tagName(optimize) })
    else
        b.fmt(".zig-cache/vendor-build-v4/{s}-{s}", .{ target_key, @tagName(optimize) });
    const cmake_c = b.fmt("-DCMAKE_C_COMPILER={s}", .{c_compiler});
    const cmake_cxx = b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cxx_compiler});
    const cmake_asm = b.fmt("-DCMAKE_ASM_COMPILER={s}", .{asm_compiler});
    const cmake_type = b.fmt("-DCMAKE_BUILD_TYPE={s}", .{cmake_build_type_name(optimize)});
    const cmake_make = b.fmt("-DCMAKE_MAKE_PROGRAM={s}", .{ninja_exe});
    const cmake_ar = b.fmt("-DCMAKE_AR={s}", .{b.pathFromRoot("scripts/windows/zig_ar.cmd")});
    const cmake_ranlib = b.fmt("-DCMAKE_RANLIB={s}", .{b.pathFromRoot("scripts/windows/zig_ranlib.cmd")});

    const bssl_dependency = b.dependency("boringssl", .{});
    const bssl_root = bssl_dependency.path("");
    const bssl_source = bssl_root.getPath(b);
    const bssl_build_dir = b.pathJoin(&.{ vendor_build, "boringssl" });
    const bssl_cmake = b.addSystemCommand(&.{
        cmake_exe,
        "-B",
        bssl_build_dir,
        "-S",
        bssl_source,
        "-GNinja",
        cmake_make,
        cmake_type,
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DCMAKE_C_STANDARD=11",
        "-DCMAKE_C_STANDARD_REQUIRED=ON",
        "-DCMAKE_CXX_STANDARD=17",
        "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
        "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
        cmake_c,
        cmake_cxx,
        cmake_asm,
    });
    if (sanitizer.sanitize) {
        bssl_cmake.addArgs(&.{
            "-DASAN=ON",
            "-DUBSAN=ON",
            "-DUBSAN_RECOVER=OFF",
            sanitizer.cmake_link_flags(),
        });
    } else if (sanitizer.memory_sanitize) {
        bssl_cmake.addArgs(&.{ "-DMSAN=ON", sanitizer.cmake_link_flags() });
    }
    if (target.result.os.tag == .windows) bssl_cmake.addArg("-DOPENSSL_NO_ASM=ON");
    if (builtin.os.tag == .windows) bssl_cmake.addArgs(&.{ cmake_ar, cmake_ranlib });
    add_cross_cmake_args(b, bssl_cmake, target, target_is_native, sanitizer.instrument_c);
    set_vendor_environment(b, bssl_cmake, target_triple);
    const bssl_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", bssl_build_dir, "ssl", "crypto" });
    set_vendor_environment(b, bssl_ninja, target_triple);
    bssl_ninja.step.dependOn(&bssl_cmake.step);

    const lsquic_dependency = b.dependency("lsquic", .{});
    const lsqpack_dependency = b.dependency("lsqpack", .{});
    const lshpack_dependency = b.dependency("lshpack", .{});
    const lsquic_source = b.addWriteFiles();
    _ = lsquic_source.addCopyDirectory(lsquic_dependency.path(""), "", .{});
    _ = lsquic_source.addCopyDirectory(lsqpack_dependency.path(""), "src/liblsquic/ls-qpack", .{});
    _ = lsquic_source.addCopyDirectory(lshpack_dependency.path(""), "src/lshpack", .{});
    if (target.result.abi.isMusl()) {
        _ = lsquic_source.addCopyFile(
            lshpack_dependency.path("compat/queue/sys/queue.h"),
            "include/sys/queue.h",
        );
    }
    const prepare_lsquic = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/prepare_lsquic_source.sh") });
    prepare_lsquic.addDirectoryArg(lsquic_source.getDirectory());
    const lsquic_source_dir = b.pathJoin(&.{ vendor_build, "lsquic-source" });
    prepare_lsquic.addArg(lsquic_source_dir);
    prepare_lsquic.addFileArg(b.path("patches/lsquic_h3_message_error.patch"));
    prepare_lsquic.addArg(patch_exe);
    const lsquic_root: std.Build.LazyPath = .{ .cwd_relative = lsquic_source_dir };
    const lsquic_build_dir = b.pathJoin(&.{ vendor_build, "lsquic" });
    const lsquic_cmake = b.addSystemCommand(&.{ cmake_exe, "-B", lsquic_build_dir, "-S", lsquic_source_dir });
    lsquic_cmake.addArgs(&.{
        "-GNinja",
        cmake_make,
        cmake_type,
        "-DBUILD_SHARED_LIBS=OFF",
        "-DCMAKE_C_STANDARD=11",
        "-DCMAKE_C_STANDARD_REQUIRED=ON",
        "-DCMAKE_CXX_STANDARD=17",
        "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
        cmake_c,
        cmake_cxx,
        cmake_asm,
        "-DLSQUIC_BIN=OFF",
        "-DLSQUIC_TESTS=OFF",
        b.fmt("-DBORINGSSL_DIR={s}", .{bssl_source}),
    });
    if (sanitizer.sanitize) {
        lsquic_cmake.addArgs(&.{
            "-DLSQUIC_ASAN=OFF",
            "-DCMAKE_C_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            "-DCMAKE_CXX_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            sanitizer.cmake_link_flags(),
        });
    } else if (sanitizer.memory_sanitize) {
        lsquic_cmake.addArgs(&.{
            "-DCMAKE_C_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer",
            "-DCMAKE_CXX_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer",
            sanitizer.cmake_link_flags(),
        });
    }
    if (builtin.os.tag == .windows) lsquic_cmake.addArgs(&.{ cmake_ar, cmake_ranlib });
    add_cross_cmake_args(b, lsquic_cmake, target, target_is_native, sanitizer.instrument_c);
    set_vendor_environment(b, lsquic_cmake, target_triple);
    if (zlib_prefix) |prefix| {
        lsquic_cmake.addArg(b.fmt("-DZLIB_INCLUDE_DIR={s}/include", .{prefix}));
        lsquic_cmake.addArg(b.fmt("-DZLIB_LIB={s}/lib/libz.a", .{prefix}));
    }
    lsquic_cmake.step.dependOn(&prepare_lsquic.step);
    lsquic_cmake.step.dependOn(&bssl_ninja.step);
    const lsquic_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", lsquic_build_dir });
    set_vendor_environment(b, lsquic_ninja, target_triple);
    lsquic_ninja.step.dependOn(&lsquic_cmake.step);
    lsquic_ninja.step.dependOn(&bssl_ninja.step);

    const deflate_dependency = b.dependency("libdeflate", .{});
    const deflate_root = deflate_dependency.path("");
    const deflate_build_dir = b.pathJoin(&.{ vendor_build, "libdeflate" });
    const deflate_c_flags = if (sanitizer.sanitize)
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI -fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
    else if (sanitizer.memory_sanitize)
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI -fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer"
    else
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI";
    const deflate_cmake = b.addSystemCommand(&.{
        cmake_exe,
        "-B",
        deflate_build_dir,
        "-S",
        deflate_root.getPath(b),
        "-GNinja",
        cmake_make,
        cmake_type,
        "-DCMAKE_C_STANDARD=11",
        "-DCMAKE_C_STANDARD_REQUIRED=ON",
        "-DLIBDEFLATE_BUILD_GZIP=OFF",
        "-DLIBDEFLATE_BUILD_TESTS=OFF",
        "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF",
        b.fmt("-DCMAKE_C_FLAGS={s}", .{deflate_c_flags}),
        cmake_c,
        cmake_cxx,
        cmake_asm,
    });
    if (sanitizer.instrument_c) deflate_cmake.addArg(sanitizer.cmake_link_flags());
    if (builtin.os.tag == .windows) deflate_cmake.addArgs(&.{ cmake_ar, cmake_ranlib });
    add_cross_cmake_args(b, deflate_cmake, target, target_is_native, sanitizer.instrument_c);
    set_vendor_environment(b, deflate_cmake, target_triple);
    const deflate_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", deflate_build_dir });
    set_vendor_environment(b, deflate_ninja, target_triple);
    deflate_ninja.step.dependOn(&deflate_cmake.step);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.step.dependOn(&prepare_lsquic.step);
    translate_c.addIncludePath(bssl_root.path(b, "include"));
    translate_c.addIncludePath(lsquic_root.path(b, "include"));
    translate_c.addIncludePath(deflate_root);
    if (target.result.os.tag == .windows) {
        translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
        translate_c.addIncludePath(lsquic_root.path(b, "wincompat"));
    }
    if (zlib_prefix) |prefix| {
        translate_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }

    return .{
        .b = b,
        .target = target,
        .bssl_root = bssl_root,
        .lsquic_root = lsquic_root,
        .deflate_root = deflate_root,
        .bssl_build_dir = bssl_build_dir,
        .lsquic_build_dir = lsquic_build_dir,
        .deflate_build_dir = deflate_build_dir,
        .zlib_prefix = zlib_prefix,
        .bssl_step = bssl_ninja,
        .lsquic_step = lsquic_ninja,
        .deflate_step = deflate_ninja,
        .c_module = translate_c.createModule(),
    };
}

pub fn add_platform_libraries(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) return;
    module.linkSystemLibrary("ws2_32", .{});
    module.linkSystemLibrary("mswsock", .{});
    module.linkSystemLibrary("crypt32", .{});
    module.linkSystemLibrary("advapi32", .{});
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
    instrument_c: bool,
) void {
    if (target_is_native) {
        if (instrument_c) command.addArg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
        return;
    }
    const system_name: []const u8 = switch (target.result.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFlyBSD",
        .windows => "Windows",
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
