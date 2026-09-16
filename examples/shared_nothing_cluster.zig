//! Shared-nothing worker group: one libxev loop and slab set per core.
//!
//! Build and run:
//!   zig build shared_nothing_cluster -Doptimize=ReleaseSafe
//!   curl -s http://127.0.0.1:3000/
//!
//! Each worker binds the same port through SO_REUSEPORT and is pinned to a
//! distinct physical core where the platform allows it. No connection state,
//! request buffer, or event loop is shared between workers.

const std = @import("std");
const uz = @import("uWebZockets");

const worker_count = 4;

fn hello(_: *uz.Request, res: *uz.Response) void {
    res.text("hello from a pinned shared-nothing worker") catch {};
}

pub fn main(init: std.process.Init) !void {
    var group = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .with_write_queue_size(32 * 1024)
        .with_idle_timeout_ms(60_000)
        .build_cluster(std.heap.page_allocator, worker_count, .{});
    defer group.deinit();

    const Cluster = @TypeOf(group);
    try group.configure(struct {
        fn routes(worker: *Cluster.Worker, index: usize) !void {
            _ = index;
            _ = try worker.get("/", hello);
        }
    }.routes);

    try group.listen("0.0.0.0", 3000);
    try group.run();
}
