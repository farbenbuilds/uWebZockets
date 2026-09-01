comptime {
    _ = @import("c_api_tests.zig");
    _ = @import("c_tests.zig");
    _ = @import("core_tests.zig");
    _ = @import("fuzz_main.zig");
    _ = @import("http_tests.zig");
    _ = @import("http2_tests.zig");
    _ = @import("http2_hpack_tests.zig");
    _ = @import("http2_server_tests.zig");
    _ = @import("quic_tests.zig");
    _ = @import("quic_phase3_tests.zig");
    _ = @import("router_tests.zig");
    _ = @import("udp_tests.zig");
    _ = @import("ws_tests.zig");
}
