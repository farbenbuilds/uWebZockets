const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;

// placeholder for router pointer injection later.

// represents an active tcp connection.
// memory for this struct must be stable (e.g., pre-allocated in a static pool or slab),
// because libxev relies on the exact memory addresses of the `xev.Completion` fields.
pub const TcpConnection = struct {
    read_buffer: [8192]u8 = undefined,
    req: Request = .{},
    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    socket: xev.TCP,
    parser: HttpParser = .{},
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
        conn.socket.close(state) catch {};
        return .disarm;
    }

    const data = conn.read_buffer[0..result.bytes_read];

    // pass data into the fsm parser.
    _ = http_parser.consume(&conn.parser, &conn.req, data);

    // map to router and response logic here.
    // echo direct response for testing.
    var res = Response{ .conn = conn };
    http_response.end(&res, "200 OK", "Hello from Zig!");

    // re-arm the completion to keep listening for more data.
    return .rearm;
}

// executes scatter-gather i/o to send multiple buffers without allocating a mega-buffer.
pub fn writev_start(conn: *TcpConnection, loop_ptr: *xev.Loop, buffers: []const xev.WriteBuffer) void {
    conn.socket.writev(
        loop_ptr,
        &conn.write_completion,
        buffers,
        TcpConnection,
        conn,
        on_write_complete,
    );
}

// callback triggered when the kernel finishes sending data.
fn on_write_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    state: xev.State,
    result: xev.WriteBufferResult,
) xev.CallbackAction {
    _ = user_data;
    _ = loop;
    _ = completion;
    _ = state;

    if (result.err != .none) {
        std.debug.print("write error: {}\n", .{result.err});
        return .disarm;
    }

    // successfully written. wait for next request on this keep-alive connection.
    return .disarm;
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

    std.debug.print("new connection accepted: fd {}\n", .{accepted_socket.fd});

    return .rearm;
}
