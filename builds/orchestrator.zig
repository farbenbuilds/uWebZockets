const builtin = @import("builtin");
const std = @import("std");
const ebpf = @import("targets/ebpf.zig");
const native = @import("targets/native.zig");
const wasm = @import("targets/wasm.zig");

pub fn inject(b: *std.Build, version: std.SemanticVersion) void {
    const default_target = if (b.graph.environ_map.get("UWEBZOCKETS_DEFAULT_TARGET")) |triple|
        std.Target.Query.parse(.{ .arch_os_abi = triple }) catch {
            @panic("UWEBZOCKETS_DEFAULT_TARGET is not a valid Zig target");
        }
    else
        std.Target.Query{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.cpu.arch == .wasm32) {
        if (target.result.os.tag != .freestanding and target.result.os.tag != .wasi) {
            @panic("wasm32 builds must target freestanding or WASI");
        }
        wasm.inject_selected(b, version, target, optimize);
        return;
    }
    switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .windows => {},
        else => @panic("uWebZockets supports native POSIX, Windows, and wasm32 targets"),
    }

    const target_is_native = target.query.isNative() or
        (target.result.cpu.arch == builtin.cpu.arch and target.result.os.tag == builtin.os.tag);
    _ = native.inject(b, version, target, optimize, target_is_native);
    const wasm_steps = wasm.inject_named(b, version, optimize);
    const ebpf_step = ebpf.inject(b);
    const all_targets = b.step("all-targets", "Build native, WASM/WASI, and eBPF artifacts");
    all_targets.dependOn(b.getInstallStep());
    all_targets.dependOn(wasm_steps.freestanding);
    all_targets.dependOn(wasm_steps.wasi);
    all_targets.dependOn(ebpf_step);
}
