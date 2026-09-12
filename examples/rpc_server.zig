const std = @import("std");
const uz = @import("uWebZockets");

const AddParams = struct {
    left: i64,
    right: i64,
};

const AddResult = struct {
    sum: i64,
};

fn add(params: AddParams) uz.json_rpc.HandlerError!AddResult {
    return .{ .sum = params.left + params.right };
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init(init.io);
    defer server.deinit();

    var rpc = uz.json_rpc.Service{};
    try rpc.register_typed("math.add", AddParams, AddResult, add);
    _ = try server.rpc("/rpc", &rpc);

    try server.listen("0.0.0.0", 3000);
    try server.run();
}
