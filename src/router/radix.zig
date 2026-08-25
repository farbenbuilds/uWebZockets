const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const zslay = @import("zslay");

pub const Handler = *const fn (req: *Request, res: *Response) void;

// websocket route behavior interface.
// users only need to define the callbacks they care about.
pub const WsBehavior = struct {
    open: ?*const fn (ws: *WebSocket) void = null,
    message: ?*const fn (ws: *WebSocket, message: []const u8, opcode: zslay.Opcode) void = null,
    close: ?*const fn (ws: *WebSocket) void = null,
};

pub const RouteType = enum { http, websocket };

pub const RouteNode = struct {
    path: []const u8 = "",
    route_type: RouteType = .http,
    http_handler: ?Handler = null,
    ws_behavior: ?WsBehavior = null,
};

const max_nodes = 256;
const null_node: u16 = 0xFFFF;

// zero-allocation radix trie router using struct of arrays (soa)
// for maximum cpu cache locality and data-oriented design (dod).
pub const Router = struct {
    segments: [max_nodes][]const u8 = undefined,
    first_child: [max_nodes]u16 = .{null_node} ** max_nodes,
    next_sibling: [max_nodes]u16 = .{null_node} ** max_nodes,
    has_route: [max_nodes]bool = .{false} ** max_nodes,
    route_types: [max_nodes]RouteType = undefined,
    http_handlers: [max_nodes]?Handler = .{null} ** max_nodes,
    ws_behaviors: [max_nodes]?WsBehavior = .{null} ** max_nodes,

    node_count: u16 = 0,
    root_idx: u16 = null_node,

    pub fn init() Router {
        var r = Router{};
        r.root_idx = r.alloc_node("");
        return r;
    }

    fn alloc_node(self: *Router, segment: []const u8) u16 {
        if (self.node_count >= max_nodes) @panic("router nodes exhausted");
        const idx = self.node_count;
        self.node_count += 1;
        self.segments[idx] = segment;
        self.first_child[idx] = null_node;
        self.next_sibling[idx] = null_node;
        self.has_route[idx] = false;
        return idx;
    }

    fn set_route(self: *Router, idx: u16, route: RouteNode) void {
        self.has_route[idx] = true;
        self.route_types[idx] = route.route_type;
        self.http_handlers[idx] = route.http_handler;
        self.ws_behaviors[idx] = route.ws_behavior;
    }

    fn common_prefix(a: []const u8, b: []const u8) usize {
        const len = @min(a.len, b.len);
        var i: usize = 0;
        while (i < len and a[i] == b[i]) : (i += 1) {}
        return i;
    }

    fn insert(self: *Router, path: []const u8, route: RouteNode) void {
        if (self.node_count == 0) {
            self.root_idx = self.alloc_node("");
        }

        var curr = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) {
                self.set_route(curr, route);
                return;
            }

            var best_child: u16 = null_node;
            var best_prefix: usize = 0;
            var prev_sibling: u16 = null_node;

            var child = self.first_child[curr];
            while (child != null_node) : (child = self.next_sibling[child]) {
                const seg = self.segments[child];
                const prefix = common_prefix(seg, search);
                if (prefix > 0) {
                    best_child = child;
                    best_prefix = prefix;
                    break;
                }
                prev_sibling = child;
            }

            if (best_child == null_node) {
                const new_child = self.alloc_node(search);
                self.set_route(new_child, route);
                self.next_sibling[new_child] = self.first_child[curr];
                self.first_child[curr] = new_child;
                return;
            }

            const child_seg = self.segments[best_child];
            if (best_prefix < child_seg.len) {
                const split_node = self.alloc_node(child_seg[best_prefix..]);

                self.first_child[split_node] = self.first_child[best_child];
                self.has_route[split_node] = self.has_route[best_child];
                self.route_types[split_node] = self.route_types[best_child];
                self.http_handlers[split_node] = self.http_handlers[best_child];
                self.ws_behaviors[split_node] = self.ws_behaviors[best_child];

                self.segments[best_child] = child_seg[0..best_prefix];
                self.first_child[best_child] = split_node;
                self.has_route[best_child] = false;
                self.http_handlers[best_child] = null;
                self.ws_behaviors[best_child] = null;
            }

            if (best_prefix == search.len) {
                self.set_route(best_child, route);
                return;
            }

            curr = best_child;
            search = search[best_prefix..];
        }
    }

    // registers an http get route.
    pub fn get(self: *Router, path: []const u8, handler: Handler) void {
        self.insert(path, .{
            .route_type = .http,
            .http_handler = handler,
        });
    }

    // registers a websocket route.
    pub fn ws(self: *Router, path: []const u8, behavior: WsBehavior) void {
        self.insert(path, .{
            .route_type = .websocket,
            .ws_behavior = behavior,
        });
    }

    // matches a requested path against the radix trie.
    // uses fast first-character elimination for sibling checks.
    pub fn match(self: *const Router, path: []const u8) ?RouteNode {
        if (self.node_count == 0) return null;

        var curr = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) {
                if (self.has_route[curr]) {
                    return RouteNode{
                        .path = path,
                        .route_type = self.route_types[curr],
                        .http_handler = self.http_handlers[curr],
                        .ws_behavior = self.ws_behaviors[curr],
                    };
                }
                return null;
            }

            var child = self.first_child[curr];
            var found = false;
            const first_char = search[0];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const seg = self.segments[child];
                if (seg.len > 0 and seg[0] == first_char) {
                    if (std.mem.startsWith(u8, search, seg)) {
                        curr = child;
                        search = search[seg.len..];
                        found = true;
                    }
                    break; // branches are unique by first character
                }
            }

            if (!found) return null;
        }
    }
};
