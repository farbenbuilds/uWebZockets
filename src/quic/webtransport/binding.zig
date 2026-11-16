const Request = @import("../../http/request.zig").Request;
const Response = @import("../../http/response.zig").Response;
const runtime = @import("runtime.zig");

/// Identity in the immutable application datagram registry.
pub const RouteId = @import("../../router/datagram.zig").RouteId;

/// Only an explicitly invoked CONNECT handler can approve the request.
pub const AdmissionResult = union(enum) {
    rejected,
    accepted: RouteId,
};

/// Runs synchronous admission against a bounded, not-yet-sent H3 response.
pub const AdmissionCallback = *const fn (*anyopaque, *Request, *Response) AdmissionResult;
/// Delivers borrowed bytes using an established connection and route identity.
pub const DeliveryCallback = *const fn (*anyopaque, runtime.ConnectionHandle, RouteId, u64, u64, []const u8) bool;
/// Invalidates queued application datagrams before connection identity reuse.
pub const ClearCallback = *const fn (*anyopaque, runtime.ConnectionHandle) void;
/// Supplies nonnegative monotonic microseconds at the transport boundary.
pub const ClockCallback = *const fn (*anyopaque) u64;

/// Borrowed application callbacks bound after the transport reaches its address.
pub const Binding = struct {
    context: *anyopaque,
    admit: AdmissionCallback,
    deliver: DeliveryCallback,
    clear: ClearCallback,
    clock: ClockCallback,
    /// Bound one payload, independently of the connection's complete ring slab.
    max_payload: usize,
};
