const std = @import("std");
const boringssl = @import("boringssl.zig");
const libdeflate = @import("libdeflate.zig");
const lsquic = @import("lsquic.zig");
const sanitizers = @import("sanitizers.zig");
const zlib = @import("zlib.zig");

/// Native vendor artifacts, include roots, and the translated C module.
pub const Artifacts = struct {
    target: std.Build.ResolvedTarget,
    bssl: boringssl.Artifacts,
    lsquic: lsquic.Artifacts,
    deflate: libdeflate.Artifacts,
    z: zlib.Artifacts,
    c_module: *std.Build.Module,

    pub fn add_includes(self: Artifacts, module: *std.Build.Module) void {
        module.addIncludePath(self.bssl.include_root);
        module.addIncludePath(self.lsquic.include_root);
        module.addIncludePath(self.deflate.include_root);
        module.addIncludePath(self.z.include_root);
        if (self.target.result.os.tag == .windows) {
            module.addIncludePath(self.lsquic.wincompat_dir);
        }
    }

    pub fn link(self: Artifacts, module: *std.Build.Module) void {
        module.linkLibrary(self.bssl.ssl);
        module.linkLibrary(self.bssl.crypto);
        module.linkLibrary(self.lsquic.library);
        module.linkLibrary(self.deflate.library);
        module.linkLibrary(self.z.library);
        add_platform_libraries(module, self.target);
    }
};

/// Compiles BoringSSL, lsquic, libdeflate, and zlib with Zig's C and C++
/// toolchains. No external build system or generated-file tool runs: every
/// source list and generated artifact comes from the pinned packages, the
/// pre-generated overlay, or the source tree.
pub fn configure(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
) Artifacts {
    const bssl = boringssl.build(b, target, optimize, sanitizer);
    const deflate = libdeflate.build(b, target, optimize, sanitizer);
    const z = zlib.build(b, target, optimize, sanitizer);
    const ls = lsquic.build(b, target, optimize, sanitizer, bssl, z);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(bssl.include_root);
    translate_c.addIncludePath(ls.include_root);
    translate_c.addIncludePath(deflate.include_root);
    translate_c.addIncludePath(z.include_root);
    if (target.result.os.tag == .windows) {
        translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
        translate_c.addIncludePath(ls.wincompat_dir);
    }

    return .{
        .target = target,
        .bssl = bssl,
        .lsquic = ls,
        .deflate = deflate,
        .z = z,
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
