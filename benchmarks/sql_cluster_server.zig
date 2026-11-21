//! Public-API SQL scaling fixture: independent worker pools and route storage.
const std = @import("std");
const uz = @import("uWebZockets");
const world = @import("sql_world");

const max_workers = 12;

pub fn main(init: std.process.Init) !void {
    const raw_workers = init.environ_map.get("UWZ_SQL_WORKERS") orelse "1";
    const workers = std.fmt.parseInt(usize, raw_workers, 10) catch return error.InvalidWorkerCount;
    if (workers == 0 or workers > max_workers) return error.InvalidWorkerCount;
    const affinity = init.environ_map.get("UWZ_SQL_AFFINITY") orelse "1";
    if (!std.mem.eql(u8, affinity, "0") and !std.mem.eql(u8, affinity, "1")) return error.InvalidAffinity;
    const contexts = try init.gpa.alloc(world.Context, workers);
    defer init.gpa.free(contexts);
    var group = try uz.Server.builder(init.io)
        .with_max_clients(128)
        .with_max_ws_message_size(1024)
        .with_write_queue_size(64 * 1024)
        .with_idle_timeout_ms(120_000)
        .build_cluster_with_worker_count(init.gpa, max_workers, workers, .{ .cpu_affinity = std.mem.eql(u8, affinity, "1") });
    defer group.deinit();
    const config = try world.configuration.load(init);
    for (contexts, 0..) |*context, index| {
        var seed: [8]u8 = undefined;
        try std.Io.randomSecure(init.io, &seed);
        try context.init(init.gpa, config, std.mem.readInt(u64, &seed, .little));
        const worker = group.worker(index).?;
        worker.provide(context.sql.hooks()) catch |err| {
            context.sql.db.deinit();
            return err;
        };
        _ = try worker.get_async_context("/db", context, world.Context.handler);
        _ = try worker.get_async_context("/queries", context, world.Context.handler);
        _ = try worker.get_async_context("/updates", context, world.Context.handler);
        std.log.info("SQL benchmark worker={d} pool={d} slab_bytes={d}", .{ index, config.connections, context.sql.db.slabs.len });
    }
    try group.listen("127.0.0.1", try world.configuration.http_port(init));
    try group.catch_shutdown_signals();
    try group.run();
}
