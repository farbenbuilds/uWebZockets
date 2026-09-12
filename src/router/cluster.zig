const std = @import("std");
const max_topic_length = @import("../ws/pubsub.zig").max_topic_length;

pub const queue_capacity = 64;

pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    is_text: bool,
};

/// Returns a bounded MPSC queue with structure-of-arrays message storage.
pub fn message_queue(comptime max_message_size: usize) type {
    if (max_message_size == 0) @compileError("cluster message capacity must be greater than zero");

    return struct {
        const Self = @This();

        mutex: std.atomic.Mutex = .unlocked,
        topics: [queue_capacity][max_topic_length]u8 = undefined,
        payloads: [queue_capacity][max_message_size]u8 = undefined,
        topic_lengths: [queue_capacity]u8 = .{0} ** queue_capacity,
        payload_lengths: [queue_capacity]usize = .{0} ** queue_capacity,
        text_flags: [queue_capacity]bool = .{false} ** queue_capacity,
        head: u8 = 0,
        count: u8 = 0,

        pub fn push(self: *Self, topic: []const u8, payload: []const u8, is_text: bool) !void {
            if (topic.len == 0) return error.EmptyTopic;
            if (topic.len > max_topic_length) return error.TopicTooLong;
            if (payload.len > max_message_size) return error.ClusterMessageTooLarge;

            self.lock();
            defer self.mutex.unlock();
            if (self.count == queue_capacity) return error.ClusterQueueFull;
            const index = (@as(usize, self.head) + self.count) % queue_capacity;
            @memcpy(self.topics[index][0..topic.len], topic);
            @memcpy(self.payloads[index][0..payload.len], payload);
            self.topic_lengths[index] = @intCast(topic.len);
            self.payload_lengths[index] = payload.len;
            self.text_flags[index] = is_text;
            self.count += 1;
        }

        pub fn pop_copy(
            self: *Self,
            topic_buffer: []u8,
            payload_buffer: []u8,
        ) ?Message {
            self.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;

            const index = self.head;
            const topic_length = self.topic_lengths[index];
            const payload_length = self.payload_lengths[index];
            std.debug.assert(topic_length <= topic_buffer.len);
            std.debug.assert(payload_length <= payload_buffer.len);
            @memcpy(topic_buffer[0..topic_length], self.topics[index][0..topic_length]);
            @memcpy(payload_buffer[0..payload_length], self.payloads[index][0..payload_length]);
            const is_text = self.text_flags[index];
            self.head = @intCast((@as(usize, self.head) + 1) % queue_capacity);
            self.count -= 1;
            return .{
                .topic = topic_buffer[0..topic_length],
                .payload = payload_buffer[0..payload_length],
                .is_text = is_text,
            };
        }

        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }
    };
}
