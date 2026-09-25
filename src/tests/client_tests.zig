//! Client suite: loopback HTTP/1.1 and WebSocket behavior.
const std = @import("std");
const support = @import("test_support");

test "client module is reachable" {
    _ = support.client;
}
