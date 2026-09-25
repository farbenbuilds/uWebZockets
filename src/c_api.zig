//! Public C ABI facade.
//!
//! The implementation is grouped by handle family under `src/c_api/`, while
//! this file keeps every exported `uwz_*` symbol and public handle type
//! importable through `@import("c_api.zig")`. `include/uWebZockets.h` remains
//! the frozen contract.

const app = @import("c_api/app.zig");
const errors = @import("c_api/errors.zig");
const request = @import("c_api/request.zig");
const response = @import("c_api/response.zig");
const types = @import("c_api/types.zig");
const websocket = @import("c_api/websocket.zig");

// Public handle types keep their original facade names.
pub const CSlice = types.CSlice;
pub const CAsyncResponse = types.CAsyncResponse;
pub const CWebSocketBehavior = types.CWebSocketBehavior;

// Version and error metadata.
pub const uwz_version = errors.uwz_version;
pub const uwz_error_name = errors.uwz_error_name;

// Application lifecycle, registration, listener, and publish entry points.
pub const uwz_app_create = app.uwz_app_create;
pub const uwz_app_create_tls = app.uwz_app_create_tls;
pub const uwz_app_create_http3 = app.uwz_app_create_http3;
pub const uwz_app_create_tls_ephemeral = app.uwz_app_create_tls_ephemeral;
pub const uwz_app_create_http3_ephemeral = app.uwz_app_create_http3_ephemeral;
pub const uwz_app_shutdown = app.uwz_app_shutdown;
pub const uwz_app_destroy = app.uwz_app_destroy;
pub const uwz_app_route = app.uwz_app_route;
pub const uwz_app_route_async = app.uwz_app_route_async;
pub const uwz_app_use = app.uwz_app_use;
pub const uwz_app_ws = app.uwz_app_ws;
pub const uwz_app_listen = app.uwz_app_listen;
pub const uwz_app_listen_udp = app.uwz_app_listen_udp;
pub const uwz_app_run = app.uwz_app_run;
pub const uwz_app_publish = app.uwz_app_publish;

// Borrowed request views.
pub const uwz_request_method = request.uwz_request_method;
pub const uwz_request_target = request.uwz_request_target;
pub const uwz_request_path = request.uwz_request_path;
pub const uwz_request_query = request.uwz_request_query;
pub const uwz_request_body = request.uwz_request_body;
pub const uwz_request_header = request.uwz_request_header;
pub const uwz_request_header_count = request.uwz_request_header_count;
pub const uwz_request_parameter = request.uwz_request_parameter;
pub const uwz_request_parameter_count = request.uwz_request_parameter_count;

// Synchronous and deferred response completion.
pub const uwz_response_end = response.uwz_response_end;
pub const uwz_response_end_with_headers = response.uwz_response_end_with_headers;
pub const uwz_response_begin_chunked = response.uwz_response_begin_chunked;
pub const uwz_response_write_chunk = response.uwz_response_write_chunk;
pub const uwz_response_end_chunks = response.uwz_response_end_chunks;
pub const uwz_async_response_end = response.uwz_async_response_end;
pub const uwz_async_response_end_with_headers = response.uwz_async_response_end_with_headers;

// WebSocket send, close, buffered amount, and pub/sub.
pub const uwz_websocket_send = websocket.uwz_websocket_send;
pub const uwz_websocket_send_close = websocket.uwz_websocket_send_close;
pub const uwz_websocket_buffered_amount = websocket.uwz_websocket_buffered_amount;
pub const uwz_websocket_subscribe = websocket.uwz_websocket_subscribe;
pub const uwz_websocket_unsubscribe = websocket.uwz_websocket_unsubscribe;
pub const uwz_websocket_publish = websocket.uwz_websocket_publish;
pub const uwz_websocket_terminate = websocket.uwz_websocket_terminate;

// Export declarations are emitted only when their declaring file is analyzed.
// Aliases are lazy, so reference every public name once to keep the complete
// symbol set in the static archive and to reject a drift in any alias target.
comptime {
    _ = CSlice;
    _ = CAsyncResponse;
    _ = CWebSocketBehavior;
    _ = uwz_version;
    _ = uwz_error_name;
    _ = uwz_app_create;
    _ = uwz_app_create_tls;
    _ = uwz_app_create_http3;
    _ = uwz_app_create_tls_ephemeral;
    _ = uwz_app_create_http3_ephemeral;
    _ = uwz_app_shutdown;
    _ = uwz_app_destroy;
    _ = uwz_app_route;
    _ = uwz_app_route_async;
    _ = uwz_app_use;
    _ = uwz_app_ws;
    _ = uwz_app_listen;
    _ = uwz_app_listen_udp;
    _ = uwz_app_run;
    _ = uwz_app_publish;
    _ = uwz_request_method;
    _ = uwz_request_target;
    _ = uwz_request_path;
    _ = uwz_request_query;
    _ = uwz_request_body;
    _ = uwz_request_header;
    _ = uwz_request_header_count;
    _ = uwz_request_parameter;
    _ = uwz_request_parameter_count;
    _ = uwz_response_end;
    _ = uwz_response_end_with_headers;
    _ = uwz_response_begin_chunked;
    _ = uwz_response_write_chunk;
    _ = uwz_response_end_chunks;
    _ = uwz_async_response_end;
    _ = uwz_async_response_end_with_headers;
    _ = uwz_websocket_send;
    _ = uwz_websocket_send_close;
    _ = uwz_websocket_buffered_amount;
    _ = uwz_websocket_subscribe;
    _ = uwz_websocket_unsubscribe;
    _ = uwz_websocket_publish;
    _ = uwz_websocket_terminate;
}
