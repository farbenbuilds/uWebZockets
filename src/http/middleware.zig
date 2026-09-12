const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const radix = @import("../router/radix.zig");

pub const CorsOptions = struct {
    origins: []const []const u8,
    methods: []const radix.HttpMethod = &.{ .get, .head, .post },
    allow_headers: []const []const u8 = &.{},
    expose_headers: []const []const u8 = &.{},
    allow_credentials: bool = false,
    max_age: ?u32 = null,
};

pub const Cors = struct {
    options: CorsOptions,

    pub fn handler(context: *anyopaque, request: *Request, response: *Response) radix.MiddlewareResult {
        const self: *const Cors = @ptrCast(@alignCast(context));
        const origin = request.get_unique_header("origin") orelse return .continue_dispatch;
        if (!contains_exact(self.options.origins, origin)) return .continue_dispatch;

        response.append_header("Access-Control-Allow-Origin", origin) catch {
            fail_response(response);
            return .stop;
        };
        response.append_header("Vary", "Origin") catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.allow_credentials) {
            response.append_header("Access-Control-Allow-Credentials", "true") catch {
                fail_response(response);
                return .stop;
            };
        }
        append_list(response, "Access-Control-Expose-Headers", self.options.expose_headers) catch {
            fail_response(response);
            return .stop;
        };

        if (!std.mem.eql(u8, request.method, "OPTIONS")) return .continue_dispatch;
        const requested_method = request.get_unique_header("access-control-request-method") orelse {
            return .continue_dispatch;
        };
        const method = radix.HttpMethod.parse(requested_method) orelse {
            end_best_effort(response, "403 Forbidden");
            return .stop;
        };
        if (!contains_method(self.options.methods, method) or
            !requested_headers_allowed(request, self.options.allow_headers))
        {
            end_best_effort(response, "403 Forbidden");
            return .stop;
        }

        append_methods(response, self.options.methods) catch {
            fail_response(response);
            return .stop;
        };
        append_list(response, "Access-Control-Allow-Headers", self.options.allow_headers) catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.max_age) |max_age| {
            var value_buffer: [16]u8 = undefined;
            const value = std.fmt.bufPrint(&value_buffer, "{d}", .{max_age}) catch {
                fail_response(response);
                return .stop;
            };
            response.append_header("Access-Control-Max-Age", value) catch {
                fail_response(response);
                return .stop;
            };
        }
        end_best_effort(response, "204 No Content");
        return .stop;
    }
};

pub fn cors(options: CorsOptions) Cors {
    return .{ .options = options };
}

pub const SecurityHeadersOptions = struct {
    strict_transport_security: ?[]const u8 = "max-age=31536000; includeSubDomains",
    content_security_policy: ?[]const u8 = "default-src 'self'",
    x_content_type_options: bool = true,
    x_frame_options: ?[]const u8 = "DENY",
    referrer_policy: ?[]const u8 = "no-referrer",
};

pub const SecurityHeaders = struct {
    options: SecurityHeadersOptions,

    pub fn handler(context: *anyopaque, _: *Request, response: *Response) radix.MiddlewareResult {
        const self: *const SecurityHeaders = @ptrCast(@alignCast(context));
        append(response, "Strict-Transport-Security", self.options.strict_transport_security) catch {
            fail_response(response);
            return .stop;
        };
        append(response, "Content-Security-Policy", self.options.content_security_policy) catch {
            fail_response(response);
            return .stop;
        };
        if (self.options.x_content_type_options) {
            response.append_header("X-Content-Type-Options", "nosniff") catch {
                fail_response(response);
                return .stop;
            };
        }
        append(response, "X-Frame-Options", self.options.x_frame_options) catch {
            fail_response(response);
            return .stop;
        };
        append(response, "Referrer-Policy", self.options.referrer_policy) catch {
            fail_response(response);
            return .stop;
        };
        return .continue_dispatch;
    }
};

pub fn security_headers(options: SecurityHeadersOptions) SecurityHeaders {
    return .{ .options = options };
}

fn requested_headers_allowed(request: *const Request, allowed: []const []const u8) bool {
    const value = request.get_unique_header("access-control-request-headers") orelse return true;
    var headers = std.mem.splitScalar(u8, value, ',');
    while (headers.next()) |raw_header| {
        const header = std.mem.trim(u8, raw_header, " \t");
        var found = false;
        for (allowed) |candidate| {
            if (!std.ascii.eqlIgnoreCase(candidate, header)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn contains_exact(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn contains_method(methods: []const radix.HttpMethod, expected: radix.HttpMethod) bool {
    for (methods) |method| {
        if (method == expected or method == .any) return true;
    }
    return false;
}

fn append(response: *Response, name: []const u8, value: ?[]const u8) !void {
    if (value) |present| try response.append_header(name, present);
}

fn append_list(response: *Response, name: []const u8, values: []const []const u8) !void {
    if (values.len == 0) return;
    var buffer: [1024]u8 = undefined;
    const value = try format_list(&buffer, values);
    try response.append_header(name, value);
}

fn append_methods(response: *Response, methods: []const radix.HttpMethod) !void {
    var names: [10][]const u8 = undefined;
    if (methods.len > names.len) return error.TooManyCorsMethods;
    for (methods, 0..) |method, index| names[index] = method.name();
    try append_list(response, "Access-Control-Allow-Methods", names[0..methods.len]);
}

fn format_list(buffer: []u8, values: []const []const u8) ![]const u8 {
    var offset: usize = 0;
    for (values, 0..) |value, index| {
        if (std.mem.indexOfAny(u8, value, "\r\n,") != null) return error.InvalidHeaderValue;
        const separator = if (index == 0) "" else ", ";
        if (separator.len + value.len > buffer.len - offset) return error.BufferTooSmall;
        @memcpy(buffer[offset..][0..separator.len], separator);
        offset += separator.len;
        @memcpy(buffer[offset..][0..value.len], value);
        offset += value.len;
    }
    return buffer[0..offset];
}

fn fail_response(response: *Response) void {
    end_best_effort(response, "500 Internal Server Error");
}

fn end_best_effort(response: *Response, status: []const u8) void {
    // The middleware ABI cannot report a response failure after dispatch stops.
    response.end(status, "") catch {};
}
