const builtin = @import("builtin");
const std = @import("std");

pub fn inject(b: *std.Build) *std.Build.Step {
    const step = b.step("ebpf", "Build the AF_XDP redirect and latency eBPF objects");
    if (builtin.os.tag != .linux) {
        step.dependOn(&b.addFail("the AF_XDP eBPF hooks require a Linux build host").step);
        return step;
    }

    const redirect = add_object(b, "src/xdp/xdp_redirect.c", "uwz_xdp.o");
    step.dependOn(&b.addInstallFile(redirect, "share/uwebzockets/uwz_xdp.o").step);

    const latency = add_object(b, "src/observability/uwz_latency_bpf.c", "uwz_latency.o");
    step.dependOn(&b.addInstallFile(latency, "share/uwebzockets/uwz_latency.o").step);
    return step;
}

fn add_object(b: *std.Build, source: []const u8, name: []const u8) std.Build.LazyPath {
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
    compile.addFileArg(b.path(source));
    compile.addArg("-o");
    return compile.addOutputFileArg(name);
}
