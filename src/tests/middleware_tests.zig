//! Middleware suite for authentication and rate limiting.
const std = @import("std");
const support = @import("test_support");

test "middleware helpers construct" {
    _ = support.middleware.security_headers(.{});
}
