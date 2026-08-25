const std = @import("std");
const WebSocket = @import("socket.zig").WebSocket;
const zslay = @import("zslay");

// static limits for the pub/sub system
const max_topics = 1024;
const max_subscriptions = 8192;

// static pub/sub engine using struct of arrays (soa) for data locality and cpu caching
pub const PubSubEngine = struct {
    // topic data
    topic_names: [max_topics][]const u8 = undefined,
    topic_subscriber_counts: [max_topics]usize = undefined,
    topic_count: usize = 0,

    // subscription data
    sub_sockets: [max_subscriptions]*WebSocket = undefined,
    sub_topic_ids: [max_subscriptions]usize = undefined,
    sub_count: usize = 0,

    // finds or allocates a new topic
    fn get_or_create_topic(self: *PubSubEngine, name: []const u8) !usize {
        for (self.topic_names[0..self.topic_count], 0..) |topic_name, i| {
            if (std.mem.eql(u8, topic_name, name)) return i;
        }

        if (self.topic_count >= max_topics) return error.OutOfMemory;

        const id = self.topic_count;
        self.topic_names[id] = name;
        self.topic_subscriber_counts[id] = 0;
        self.topic_count += 1;
        return id;
    }

    // registers a client to a topic
    pub fn subscribe(self: *PubSubEngine, ws: *WebSocket, topic_name: []const u8) !void {
        if (self.sub_count >= max_subscriptions) return error.OutOfMemory;

        const tid = try self.get_or_create_topic(topic_name);
        const sid = self.sub_count;

        self.sub_sockets[sid] = ws;
        self.sub_topic_ids[sid] = tid;
        self.sub_count += 1;

        self.topic_subscriber_counts[tid] += 1;
    }

    // broadcasts a message to all clients in a topic
    pub fn publish(self: *PubSubEngine, topic_name: []const u8, message: []const u8, is_text: bool) void {
        var target_tid: ?usize = null;
        for (self.topic_names[0..self.topic_count], 0..) |t_name, i| {
            if (std.mem.eql(u8, t_name, topic_name)) {
                target_tid = i;
                break;
            }
        }

        const tid = target_tid orelse return;
        const opcode: zslay.Opcode = if (is_text) .text else .binary;
        const active_ids = self.sub_topic_ids[0..self.sub_count];

        // linear scan over contiguous memory; llvm will auto-vectorize this loop
        for (active_ids, 0..) |id, i| {
            if (id == tid) {
                self.sub_sockets[i].send(message, opcode);
            }
        }
    }
};
