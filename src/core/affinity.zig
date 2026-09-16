//! Physical-core selection and thread pinning for shared-nothing workers.
//!
//! Linux reads the allowed CPU set and the sysfs sibling lists so worker `i`
//! lands on a distinct physical core. Windows uses the process affinity mask
//! and `SetThreadAffinityMask`. Platforms without a hard-affinity API report
//! `error.UnsupportedPlatform`, letting worker startup continue unpinned.
//!
//! Every function here is allocation-free and runs during startup only.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const windows = std.os.windows;

/// Upper bound on tracked CPUs; covers current server-class machines.
pub const max_tracked_cpus = 256;

pub const Error = error{
    UnsupportedPlatform,
    NoEligibleCpu,
    AffinityFailed,
};

/// One representative CPU per physical core, drawn from the allowed set.
///
/// Built once before worker threads spawn. Extra workers beyond the physical
/// core count reuse entries so no worker floats across cores unpinned.
pub const CoreSelection = struct {
    cpus: [max_tracked_cpus]usize = undefined,
    len: usize = 0,

    /// Builds the selection from the process's allowed CPU set.
    pub fn init() CoreSelection {
        var selection = CoreSelection{};
        const allowed = allowed_cpus(&selection.cpus);
        selection.len = if (builtin.os.tag == .linux)
            keep_primary_threads(selection.cpus[0..allowed])
        else
            allowed;
        return selection;
    }

    /// Returns the CPU for worker `index`, or null when pinning is unavailable.
    pub fn cpu(self: *const CoreSelection, index: usize) ?usize {
        if (self.len == 0) return null;
        return self.cpus[index % self.len];
    }
};

/// Pins the calling thread to `cpu`.
///
/// The CPU must come from `CoreSelection`; a CPU outside the process's cpuset
/// fails with `error.AffinityFailed`.
pub fn pin_current_thread(cpu: usize) Error!void {
    switch (builtin.os.tag) {
        .linux => {
            if (cpu >= @bitSizeOf(linux.cpu_set_t)) return error.NoEligibleCpu;
            var set = std.mem.zeroes(linux.cpu_set_t);
            const word_bits = @bitSizeOf(usize);
            set[cpu / word_bits] |= @as(usize, 1) << @intCast(cpu % word_bits);
            linux.sched_setaffinity(0, &set) catch return error.AffinityFailed;
        },
        .windows => {
            if (cpu >= @bitSizeOf(usize)) return error.NoEligibleCpu;
            const mask = @as(usize, 1) << @intCast(cpu);
            if (SetThreadAffinityMask(windows.GetCurrentThread(), mask) == 0) {
                return error.AffinityFailed;
            }
        },
        else => return error.UnsupportedPlatform,
    }
}

/// Fills `out` with the allowed CPUs in ascending order; returns the count.
fn allowed_cpus(out: *[max_tracked_cpus]usize) usize {
    return switch (builtin.os.tag) {
        .linux => allowed_cpus_linux(out),
        .windows => allowed_cpus_windows(out),
        else => 0,
    };
}

fn allowed_cpus_linux(out: *[max_tracked_cpus]usize) usize {
    var set = std.mem.zeroes(linux.cpu_set_t);
    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (@as(isize, @bitCast(rc)) < 0) return 0;

    var count: usize = 0;
    for (set, 0..) |word, word_index| {
        var bits = word;
        while (bits != 0) {
            const bit = @ctz(bits);
            const cpu = word_index * @bitSizeOf(usize) + bit;
            if (cpu < max_tracked_cpus) {
                out[count] = cpu;
                count += 1;
            }
            bits &= bits - 1;
        }
    }
    return count;
}

fn allowed_cpus_windows(out: *[max_tracked_cpus]usize) usize {
    var process_mask: usize = 0;
    var system_mask: usize = 0;
    const succeeded = GetProcessAffinityMask(
        windows.GetCurrentProcess(),
        &process_mask,
        &system_mask,
    );
    if (!succeeded.toBool()) return 0;

    var count: usize = 0;
    while (process_mask != 0 and count < max_tracked_cpus) {
        const bit = @ctz(process_mask);
        out[count] = bit;
        count += 1;
        process_mask &= process_mask - 1;
    }
    return count;
}

/// Compacts Linux logical CPUs down to the lowest allowed sibling per core.
///
/// CPUs ascend, so the first allowed sibling of a core is also the primary one.
fn keep_primary_threads(cpus: []usize) usize {
    if (cpus.len < 2) return cpus.len;

    var allowed = CpuBitmap{};
    for (cpus) |cpu| allowed.set(cpu);

    var kept: usize = 0;
    for (cpus) |cpu| {
        if (has_lower_allowed_sibling(cpu, &allowed)) continue;
        cpus[kept] = cpu;
        kept += 1;
    }
    return kept;
}

const CpuBitmap = struct {
    words: [max_tracked_cpus / @bitSizeOf(usize)]usize = .{0} ** (max_tracked_cpus / @bitSizeOf(usize)),

    fn set(self: *CpuBitmap, cpu: usize) void {
        if (cpu >= max_tracked_cpus) return;
        self.words[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }

    fn isSet(self: *const CpuBitmap, cpu: usize) bool {
        if (cpu >= max_tracked_cpus) return false;
        const mask = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
        return self.words[cpu / @bitSizeOf(usize)] & mask != 0;
    }
};

/// Reports whether `cpu` shares a core with a lower-numbered allowed CPU.
///
/// A missing or unparsable topology entry is treated as a primary thread so a
/// restricted sysfs never removes usable CPUs.
fn has_lower_allowed_sibling(cpu: usize, allowed: *const CpuBitmap) bool {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list",
        .{cpu},
    ) catch return false;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch return false;
    defer _ = std.posix.system.close(fd);

    var buffer: [128]u8 = undefined;
    const length = std.posix.read(fd, &buffer) catch return false;
    return sibling_list_has_lower(buffer[0..length], cpu, allowed);
}

fn sibling_list_has_lower(list: []const u8, cpu: usize, allowed: *const CpuBitmap) bool {
    var index: usize = 0;
    while (index < list.len) {
        const token_end = std.mem.indexOfScalarPos(u8, list, index, ',') orelse list.len;
        const token = list[index..token_end];
        index = token_end + 1;

        if (std.mem.indexOfScalar(u8, token, '-')) |dash| {
            const first = std.fmt.parseInt(usize, token[0..dash], 10) catch continue;
            const last = std.fmt.parseInt(usize, token[dash + 1 ..], 10) catch continue;
            if (last > max_tracked_cpus * 2) continue;
            var sibling = first;
            while (sibling <= last) : (sibling += 1) {
                if (sibling >= cpu) break;
                if (allowed.isSet(sibling)) return true;
            }
            continue;
        }

        const sibling = std.fmt.parseInt(usize, token, 10) catch continue;
        if (sibling < cpu and allowed.isSet(sibling)) return true;
    }
    return false;
}

extern "kernel32" fn GetProcessAffinityMask(
    process: windows.HANDLE,
    process_mask: *usize,
    system_mask: *usize,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetThreadAffinityMask(
    thread: windows.HANDLE,
    thread_affinity_mask: usize,
) callconv(.winapi) usize;
