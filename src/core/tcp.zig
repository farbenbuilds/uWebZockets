const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;

// represents an active tcp connection.
// memory for this struct must be stable (e.g., pre-allocated in a static pool or slab),
// because libxev relies on the exact memory addresses of the `xev.Completion` fields.
pub const TcpConnection = struct {
    read_buffer: [8192]u8 = undefined,
    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    socket: xev.TCP,
};

// initiates an asynchronous read operation.
pub fn read_start(conn: *TcpConnection, loop: *Loop) void {
    conn.socket.read(
        loop.get_xev_loop(),
        &conn.read_completion,
        .{ .slice = &conn.read_buffer },
        TcpConnection,
        conn,
        on_read_complete,
    );
}

// callback triggered by libxev when a read completes or fails.
fn on_read_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    state: xev.State,
    result: xev.ReadBufferResult,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const conn = user_data.?;

    if (result.err != .none or result.bytes_read == 0) {
        // eof or error indicates client disconnected.
        // in a full implementation, this slot returns to the memory pool.
        conn.socket.close(state) catch {};
        return .disarm;
    }

    const data = conn.read_buffer[0..result.bytes_read];

    // pass `data` into the http/1.1 fsm parser (phase 2).
    std.debug.print("received {} bytes\n", .{data.len});

    // re-arm the completion to keep listening for more data.
    return .rearm;
}

// tcp listener that binds to a port and accepts incoming connections.
pub const TcpServer = struct {
    accept_completion: xev.Completion = undefined,
    listener: xev.TCP,
};

// binds to an ipv4 address and port, and begins listening.
pub fn init_server(address: []const u8, port: u16) !TcpServer {
    const addr = try std.Io.net.IpAddress.parse(address, port);

    // initialize a non-blocking tcp socket
    var listener = try xev.TCP.init(addr);
    try listener.bind(addr);
    try listener.listen(128); // backlog size

    return TcpServer{
        .listener = listener,
    };
}

// starts accepting incoming connections asynchronously.
pub fn accept_start(server: *TcpServer, loop: *Loop) void {
    server.listener.accept(
        loop.get_xev_loop(),
        &server.accept_completion,
        TcpServer,
        server,
        on_accept_complete,
    );
}

// callback triggered when a new client connects.
fn on_accept_complete(
    user_data: ?*TcpServer,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptResult,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const server = user_data.?;
    _ = server;

    if (result.err != .none) {
        std.debug.print("accept error: {}\n", .{result.err});
        return .rearm;
    }

    const accepted_socket = result.socket;

    // claim a free `TcpConnection` slot from a pre-allocated array (memory pool)
    // to avoid allocation on the hot path.
    std.debug.print("new connection accepted: fd {}\n", .{accepted_socket.fd});

    // note: the new connection needs to be stored stably in memory,
    // then `read_start(conn, loop_wrapper)` is called.

    return .rearm;
}
