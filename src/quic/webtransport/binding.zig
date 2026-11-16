const Request = @import("../../http/request.zig").Request;
const Response = @import("../../http/response.zig").Response;
const runtime = @import("runtime.zig");
const child = @import("child_runtime.zig");

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

/// Admits one associated child before any borrowed payload is delivered.
pub const ChildOpenCallback = *const fn (*anyopaque, child.Info) bool;
/// True consumes the complete borrowed chunk; false cancels this child.
pub const ChildDataCallback = *const fn (*anyopaque, child.Key, []const u8) bool;
/// Reports native read EOF after all final payload bytes were consumed.
pub const ChildEofCallback = *const fn (*anyopaque, child.Key, u64) void;
/// Reports one visible receive reset and its prefix-excluded final size.
pub const ChildResetCallback = *const fn (*anyopaque, child.Key, u64, u64) void;
/// Reports a peer request to stop the independent sending half.
pub const ChildStopCallback = *const fn (*anyopaque, child.Key, u64) void;
/// Releases consumer ownership after native close, including parent teardown.
pub const ChildClosedCallback = *const fn (*anyopaque, child.ClosedEvent) void;

/// Private receive-only candidate consumer; context must outlive native close.
pub const ChildConsumer = struct {
    context: *anyopaque,
    open: ChildOpenCallback,
    data: ChildDataCallback,
    eof: ChildEofCallback,
    reset: ChildResetCallback,
    stop: ChildStopCallback,
    closed: ChildClosedCallback,
};

/// Borrowed application callbacks bound after the transport reaches its address.
pub const Binding = struct {
    context: *anyopaque,
    admit: AdmissionCallback,
    deliver: DeliveryCallback,
    clear: ClearCallback,
    clock: ClockCallback,
    /// Bound one payload, independently of the connection's complete ring slab.
    max_payload: usize,
    /// Optional candidate consumer with userdata independent of App admission.
    child_consumer: ?ChildConsumer = null,
};
