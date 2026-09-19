//! C ABI response handles: synchronous completion and generation-checked
//! deferred completion.
//!
//! Deferred tokens are event-loop-confined and complete exactly once; stale or
//! duplicate generations must fail closed exactly as before the split.

const http_response = @import("../http/response.zig");
const AsyncResponse = http_response.AsyncResponse;
const AsyncResponseState = http_response.AsyncResponseState;
const Response = http_response.Response;
const types = @import("types.zig");
const errors = @import("errors.zig");

const CSlice = types.CSlice;
const CAsyncResponse = types.CAsyncResponse;

fn cast_response(pointer: ?*anyopaque) ?*Response {
    return @ptrCast(@alignCast(pointer orelse return null));
}

/// Completes a response with a status and body.
pub export fn uwz_response_end(
    response_pointer: ?*anyopaque,
    status: CSlice,
    body: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return types.invalid_argument;
    const status_bytes = errors.slice_bytes(status) orelse return types.invalid_argument;
    const body_bytes = errors.slice_bytes(body) orelse return types.invalid_argument;
    response.end(status_bytes, body_bytes) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Completes a response with validated HTTP/1-style header lines.
pub export fn uwz_response_end_with_headers(
    response_pointer: ?*anyopaque,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return types.invalid_argument;
    const status_bytes = errors.slice_bytes(status) orelse return types.invalid_argument;
    const header_bytes = errors.slice_bytes(headers) orelse return types.invalid_argument;
    const body_bytes = errors.slice_bytes(body) orelse return types.invalid_argument;
    response.end_with_headers(status_bytes, header_bytes, body_bytes) catch |err| {
        return errors.map_error(err);
    };
    return types.ok;
}

/// Starts a bounded chunked response.
pub export fn uwz_response_begin_chunked(
    response_pointer: ?*anyopaque,
    status: CSlice,
    headers: CSlice,
) c_int {
    const response = cast_response(response_pointer) orelse return types.invalid_argument;
    const status_bytes = errors.slice_bytes(status) orelse return types.invalid_argument;
    const header_bytes = errors.slice_bytes(headers) orelse return types.invalid_argument;
    response.begin_chunked(status_bytes, header_bytes) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Appends one chunk to a response in streaming state.
pub export fn uwz_response_write_chunk(response_pointer: ?*anyopaque, chunk: CSlice) c_int {
    const response = cast_response(response_pointer) orelse return types.invalid_argument;
    const bytes = errors.slice_bytes(chunk) orelse return types.invalid_argument;
    response.write_chunk(bytes) catch |err| return errors.map_error(err);
    return types.ok;
}

/// Finishes a chunked response.
pub export fn uwz_response_end_chunks(response_pointer: ?*anyopaque) c_int {
    const response = cast_response(response_pointer) orelse return types.invalid_argument;
    response.end_chunks() catch |err| return errors.map_error(err);
    return types.ok;
}

/// Completes one deferred response generation with a status and body.
pub export fn uwz_async_response_end(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    body: CSlice,
) c_int {
    return complete_async_response(response_pointer, status, types.empty_slice, body);
}

/// Completes one deferred response generation with validated response fields.
pub export fn uwz_async_response_end_with_headers(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    return complete_async_response(response_pointer, status, headers, body);
}

pub fn fail_pending_response(response: AsyncResponse) void {
    if (!response.is_pending()) return;
    response.complete(
        "500 Internal Server Error",
        "Deferred handler returned without a valid completion state",
    ) catch {
        // Completion failures already consume the token and wake the transport.
    };
}

fn complete_async_response(
    response_pointer: ?*CAsyncResponse,
    status: CSlice,
    headers: CSlice,
    body: CSlice,
) c_int {
    const response = response_pointer orelse return types.invalid_argument;
    const state_pointer = response.state orelse return types.invalid_argument;
    if (response.generation == 0) return types.invalid_argument;

    const status_bytes = errors.slice_bytes(status) orelse return types.invalid_argument;
    const header_bytes = errors.slice_bytes(headers) orelse return types.invalid_argument;
    const body_bytes = errors.slice_bytes(body) orelse return types.invalid_argument;
    const state: *AsyncResponseState = @ptrCast(@alignCast(state_pointer));
    const token = AsyncResponse{
        .owner = state,
        .generation = response.generation,
    };
    token.complete_with_headers(status_bytes, header_bytes, body_bytes) catch |err| {
        return errors.map_error(err);
    };
    return types.ok;
}
