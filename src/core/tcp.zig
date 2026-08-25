const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const Router = @import("../router/radix.zig").Router;

// determines the protocol of the socket.
pub const ProtocolState = enum {
    http,
    websocket,
    // tls or quic will be added in future phases.
};

// represents an active tcp connection.
// memory for this struct must be stable.
pub const TcpConnection = struct {
    read_buffer: [8192]u8 = undefined,
    write_buffer: [1024]u8 = undefined,
    req: Request = .{},
    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    parser: HttpParser = .{},
    ws: WebSocket = undefined,
    socket: xev.TCP,
    loop: *xev.Loop = undefined,
    protocol_state: ProtocolState = .http,
    router: *const Router = undefined,
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
    s: xev.TCP,
    b: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = s;
    _ = b;
    const conn = user_data.?;

    const bytes_read = result catch |err| {
        std.debug.print("read error: {}\n", .{err});
        return .disarm;
    };

    if (bytes_read == 0) return .disarm;

    const data = conn.read_buffer[0..bytes_read];

    // ensure the loop is stored on the connection for subsequent operations.
    conn.loop = loop;

    // data routing switch.
    switch (conn.protocol_state) {
        .http => {
            _ = http_parser.consume(&conn.parser, &conn.req, data);

            if (conn.parser.state == .done) {
                var res = Response{ .conn = conn };

                if (conn.router.match(conn.req.path)) |route| {
                    if (route.route_type == .websocket) {
                        conn.ws = WebSocket{ .conn = conn };
                        conn.ws.upgrade(&conn.req, &res, route.ws_behavior.?);
                    } else if (route.http_handler) |handler| {
                        handler(&conn.req, &res);
                    }
                } else {
                    res.end("404 Not Found", "Route not found");
                }
            }
        },
        .websocket => {
            // raw binary bytes are passed directly to the zslay decoder.
            conn.ws.on_data(data);
        },
    }

    return .rearm;
}

pub fn write_start(conn: *TcpConnection, loop: *xev.Loop, data: []const u8) void {
    conn.socket.write(
        loop,
        &conn.write_completion,
        .{ .slice = data },
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
    s: xev.TCP,
    b: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = user_data;
    _ = loop;
    _ = completion;
    _ = s;
    _ = b;

    _ = result catch |err| {
        std.debug.print("write error: {}\n", .{err});
        return .disarm;
    };

    return .disarm;
}

pub const AcceptCallback = *const fn (socket: xev.TCP, user_data: ?*anyopaque) void;

// tcp listener that binds to a port and accepts incoming connections.
pub const TcpServer = struct {
    accept_completion: xev.Completion = undefined,
    listener: xev.TCP,
    on_connection: AcceptCallback,
    user_data: ?*anyopaque,
};

// binds to an ipv4 address and port, and begins listening.
pub fn init_server(address: []const u8, port: u16, cb: AcceptCallback, user_data: ?*anyopaque) !TcpServer {
    const addr = try std.Io.net.IpAddress.parse(address, port);

    var listener = try xev.TCP.init(addr);
    try listener.bind(addr);
    try listener.listen(128);

    return TcpServer{
        .listener = listener,
        .on_connection = cb,
        .user_data = user_data,
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
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const server = user_data.?;

    const accepted_socket = result catch |err| {
        std.debug.print("accept error: {}\n", .{err});
        return .rearm;
    };

    server.on_connection(accepted_socket, server.user_data);

    return .rearm;
}
