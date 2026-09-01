const uwebzockets = @import("uWebZockets");

pub fn main() void {
    comptime {
        _ = uwebzockets.App;
        _ = uwebzockets.ConfiguredApp;
        _ = uwebzockets.Request;
        _ = uwebzockets.Response;
        _ = uwebzockets.WebSocket;
        _ = uwebzockets.http2;
        _ = uwebzockets.http2_hpack;
        _ = uwebzockets.http3_extensions;
        _ = uwebzockets.webtransport;
        _ = uwebzockets.udp;
    }
}
