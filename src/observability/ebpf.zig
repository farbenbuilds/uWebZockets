const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;

/// Pinned BPF maps are optional observability state; every entry point here
/// degrades to a plain error instead of trapping when the kernel refuses.
pub const max_buckets = 16;

/// Stack ceiling for one per-CPU read. Hosts exposing more possible CPUs than
/// this report Unsupported rather than risk an undersized lookup buffer.
const max_possible_cpus = 256;

/// Summed per-CPU latency histogram read from a pinned BPF map.
pub const Histogram = struct {
    buckets: [max_buckets]u64 = .{0} ** max_buckets,
    total: u64 = 0,
    observed: bool = false,
};

pub const Error = error{
    Unsupported,
    PermissionDenied,
    InvalidArgument,
    NotFound,
    SyscallFailed,
};

// Verified against the pinned Zig 0.16.0 std tree: std.os.linux.SYS.bpf
// exists for every supported Linux architecture, so no numeric fallback.
const bpf_obj_get = 7;
const bpf_map_lookup_elem = 1;

/// `BPF_OBJ_GET` attribute block.
const ObjGetAttr = extern struct {
    pathname: u64,
    bpf_fd: u32,
    file_flags: u32,
};

/// `BPF_MAP_LOOKUP_ELEM` attribute block.
const LookupAttr = extern struct {
    map_fd: u32,
    key: u64,
    value: u64,
    flags: u64,
};

pub fn available() bool {
    return builtin.os.tag == .linux;
}

/// Opens a bpffs-pinned BPF object and returns its file descriptor.
pub fn open_pinned(path: []const u8) Error!i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    if (path.len == 0 or path.len >= std.Io.Dir.max_path_bytes) return error.InvalidArgument;

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buffer);

    const open_result = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(open_result)) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.PermissionDenied,
        .NOENT => return error.NotFound,
        .INVAL => return error.InvalidArgument,
        else => return error.SyscallFailed,
    }
    // The path descriptor only proves the mount is reachable; BPF_OBJ_GET
    // resolves the pinned object itself and returns the usable map descriptor.
    defer _ = linux.close(@intCast(open_result));

    var attr: ObjGetAttr = std.mem.zeroes(ObjGetAttr);
    attr.pathname = @intFromPtr(path_z);
    const result = linux.syscall3(
        .bpf,
        bpf_obj_get,
        @intFromPtr(&attr),
        @sizeOf(ObjGetAttr),
    );
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .PERM, .ACCES => error.PermissionDenied,
        .NOENT => error.NotFound,
        .INVAL => error.InvalidArgument,
        .NOSYS, .OPNOTSUPP => error.Unsupported,
        else => error.SyscallFailed,
    };
}

/// Reads the pinned per-CPU latency array and sums every possible CPU.
pub fn read_latency_histogram(map_fd: i32) Error!Histogram {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const cpus = try possible_cpu_count();
    if (cpus > max_possible_cpus) return error.Unsupported;

    var values: [max_possible_cpus]u64 = undefined;
    var histogram = Histogram{};
    var bucket: u32 = 0;
    while (bucket < max_buckets) : (bucket += 1) {
        try lookup_percpu(map_fd, bucket, &values);
        var cpu: usize = 0;
        while (cpu < cpus) : (cpu += 1) histogram.buckets[bucket] +|= values[cpu];
    }
    for (histogram.buckets) |count| histogram.total +|= count;
    histogram.observed = true;
    return histogram;
}

pub fn close(fd: i32) void {
    if (builtin.os.tag != .linux) return;
    _ = linux.close(fd);
}

fn lookup_percpu(map_fd: i32, key: u32, values: *[max_possible_cpus]u64) Error!void {
    var attr: LookupAttr = std.mem.zeroes(LookupAttr);
    attr.map_fd = @bitCast(map_fd);
    attr.key = @intFromPtr(&key);
    attr.value = @intFromPtr(values);
    const result = linux.syscall3(
        .bpf,
        bpf_map_lookup_elem,
        @intFromPtr(&attr),
        @sizeOf(LookupAttr),
    );
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => error.PermissionDenied,
        .NOENT => error.NotFound,
        .INVAL, .BADF => error.InvalidArgument,
        .NOSYS, .OPNOTSUPP => error.Unsupported,
        else => error.SyscallFailed,
    };
}

/// Reads the boot-time possible CPU count from sysfs. An unknown count fails
/// closed: BPF_MAP_LOOKUP_ELEM copies nr_cpu_ids slots with no size argument,
/// so guessing one CPU on a large host would overrun the fixed buffer.
fn possible_cpu_count() Error!usize {
    var buffer: [64]u8 = undefined;
    const text = try read_cpu_possible(&buffer);
    const count = try parse_possible_cpus(text);
    if (count == 0) return error.InvalidArgument;
    return count;
}

fn read_cpu_possible(buffer: *[64]u8) Error![]const u8 {
    const path = "/sys/devices/system/cpu/possible";
    const open_result = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_result) != .SUCCESS) return error.SyscallFailed;
    defer _ = linux.close(@intCast(open_result));
    const count = linux.read(@intCast(open_result), buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS) return error.SyscallFailed;
    if (count == 0 or count == buffer.len) return error.SyscallFailed;
    return buffer[0..count];
}

fn parse_possible_cpus(text: []const u8) Error!usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArgument;

    var highest: ?usize = null;
    var ranges = std.mem.splitScalar(u8, trimmed, ',');
    while (ranges.next()) |range| {
        if (range.len == 0) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            const first = std.fmt.parseInt(usize, range[0..dash], 10) catch return error.InvalidArgument;
            const last = std.fmt.parseInt(usize, range[dash + 1 ..], 10) catch return error.InvalidArgument;
            if (last < first) return error.InvalidArgument;
            if (highest == null or last > highest.?) highest = last;
        } else {
            const cpu = std.fmt.parseInt(usize, range, 10) catch return error.InvalidArgument;
            if (highest == null or cpu > highest.?) highest = cpu;
        }
    }
    if (highest == null) return error.InvalidArgument;
    if (highest.? == std.math.maxInt(usize)) return error.InvalidArgument;
    return highest.? + 1;
}
