const std = @import("std");
const uz = @import("uWebZockets");

// request handler. syntax is exactly the same as phase 2.
// whether the underlying transport is classic tcp or modern quic,
// req and res are cleanly wrapped by the api.
fn on_index(req: *uz.Request, res: *uz.Response) void {
    std.debug.print("received http/3 request to: {s}\n", .{req.path});

    // send response. underneath, res.end() automatically triggers
    // stream writes and flushes directly to udp.
    uz.end_response(res, "200 OK", "Welcome to uWebZockets super-fast HTTP/3!") catch {};
}

fn on_video_chunk(req: *uz.Request, res: *uz.Response) void {
    _ = req;
    // experimental chunked transfer over quic stream
    // (http/3 doesn't natively use chunked encoding like http/1.1,
    // this demonstrates incremental stream writing logic)

    // manually writing response headers for chunked simulation
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nTransfer-Encoding: chunked\r\n\r\n";
    res.conn.write_data(headers);

    // send each data chunk (simulated)
    uz.chunked.send_chunk(res.conn, "video_data_chunk_1...") catch {};
    uz.chunked.send_chunk(res.conn, "video_data_chunk_2...") catch {};

    // close the chunked stream
    uz.chunked.end(res.conn);
}

pub fn main(init: std.process.Init) !void {
    // initialize app with quic/http3 engine and tls keys.
    var app = try uz.App(8).init_http3(init.io, "certs/cert.pem", "certs/key.pem");
    defer app.deinit();

    // route mapping is identical to http/1.1
    _ = app.get("/", on_index);
    _ = app.get("/video", on_video_chunk);

    std.debug.print("quic/http3 server ready to receive datagrams on port 8443...\n", .{});

    // bind to udp socket instead of tcp
    try app.listen_udp("0.0.0.0", 8443);

    // run the event loop
    try app.run();
}
