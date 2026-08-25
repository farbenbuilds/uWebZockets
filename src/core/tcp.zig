const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;

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

            // temporary routing logic.
            // if app router decides this is an upgrade endpoint,
            // it will call ws.upgrade(&req, &res) and change protocol_state to .websocket

            var res = Response{ .conn = conn };
            http_response.end(&res, "200 OK", "Hello from Zig!");
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

// tcp listener that binds to a port and accepts incoming connections.
pub const TcpServer = struct {
    accept_completion: xev.Completion = undefined,
    listener: xev.TCP,
};

// binds to an ipv4 address and port, and begins listening.
pub fn init_server(address: []const u8, port: u16) !TcpServer {
    const addr = try std.Io.net.IpAddress.parse(address, port);

    var listener = try xev.TCP.init(addr);
    try listener.bind(addr);
    try listener.listen(128);

    return TcpServer{
        .listener = listener,
    };
}

// starts accepting incoming connections asynchronously.
pub fn accept_start(server: *TcpServer, loop: *Loop) void {
    server.listener.accept(
        @import("loop.zig").get_xev_loop(loop),
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
    _ = user_data;
    _ = loop;
    _ = completion;

    const accepted_socket = result catch |err| {
        std.debug.print("accept error: {}\n", .{err});
        return .rearm;
    };

    std.debug.print("new connection accepted: fd {}\n", .{accepted_socket.fd});

    return .rearm;
}
