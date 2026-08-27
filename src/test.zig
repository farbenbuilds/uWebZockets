comptime {
    _ = @import("tests/c_tests.zig");
    _ = @import("tests/core_tests.zig");
    _ = @import("tests/http_tests.zig");
    _ = @import("tests/ws_tests.zig");
    _ = @import("tests/router_tests.zig");
    _ = @import("core/udp.zig");
}
