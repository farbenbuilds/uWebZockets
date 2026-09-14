const builtin = @import("builtin");
const std = @import("std");

pub fn inject(b: *std.Build) *std.Build.Step {
    const step = b.step("ebpf", "Build the AF_XDP redirect eBPF object");
    if (builtin.os.tag != .linux) {
        step.dependOn(&b.addFail("the AF_XDP eBPF hook requires a Linux build host").step);
        return step;
    }

    const compile = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "cc",
        "-target",
        "bpfel-freestanding",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O2",
        "-g",
        "-c",
    });
    compile.addFileArg(b.path("src/xdp/xdp_redirect.c"));
    compile.addArg("-o");
    const object = compile.addOutputFileArg("uwz_xdp.o");
    const install = b.addInstallFile(object, "share/uwebzockets/uwz_xdp.o");
    step.dependOn(&install.step);
    return step;
}
