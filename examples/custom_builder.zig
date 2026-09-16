//! Custom builder: fluent overrides with automatic slab math.
//!
//! Build and run:
//!   zig build custom_builder -Doptimize=ReleaseSafe
//!   curl -s -X POST http://127.0.0.1:3001/upload --data-binary @large.json
//!
//! The body limit below reserves a 50 MiB request buffer per connection, so
//! only a few connections fit comfortably; the builder reports the exact slab
//! before allocating it once. A request that exceeds the configured limit is
//! answered with a structured 413 that names the limit and the knob to raise.

const std = @import("std");
const uz = @import("uWebZockets");

fn upload(req: *uz.Request, res: *uz.Response) void {
    var scratch: [128]u8 = undefined;
    res.json_buf(.{ .received_bytes = req.bytes().len }, &scratch) catch {};
}

pub fn main(init: std.process.Init) !void {
    const builder = uz.Server.builder(init.io)
        .with_max_clients(4)
        .with_max_body_size(50 * 1024 * 1024)
        .with_write_queue_size(256 * 1024)
        .with_idle_timeout_ms(60_000);

    std.debug.print(
        "custom_builder: one startup slab of {d} MiB\n",
        .{(try builder.slab_bytes()) / (1024 * 1024)},
    );

    var server = try builder.build(std.heap.page_allocator);
    defer server.deinit();

    _ = try server.post("/upload", upload);

    try server.listen("0.0.0.0", 3001);
    try server.run();
}
