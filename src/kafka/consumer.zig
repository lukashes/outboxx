const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

const KafkaError = error{
    ConsumerCreationFailed,
    SubscriptionFailed,
    ConfigurationFailed,
    PollTimeout,
};

pub const KafkaMessage = struct {
    topic: []const u8,
    partition: i32,
    offset: i64,
    key: ?[]const u8,
    payload: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        if (self.key) |key| {
            allocator.free(key);
        }
        allocator.free(self.payload);
    }
};

pub const KafkaConsumer = struct {
    consumer: ?*c.rd_kafka_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, brokers: []const u8, group_id: []const u8) !Self {
        var errstr: [512]u8 = undefined;

        // Create configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) {
            return KafkaError.ConfigurationFailed;
        }

        // Set bootstrap servers
        const brokers_cstr = try allocator.dupeZ(u8, brokers);
        defer allocator.free(brokers_cstr);

        if (c.rd_kafka_conf_set(conf, "bootstrap.servers", brokers_cstr.ptr, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            std.log.err("Failed to set bootstrap.servers: {s}", .{errstr});
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigurationFailed;
        }

        // Set consumer group
        const group_id_cstr = try allocator.dupeZ(u8, group_id);
        defer allocator.free(group_id_cstr);

        if (c.rd_kafka_conf_set(conf, "group.id", group_id_cstr.ptr, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            std.log.err("Failed to set group.id: {s}", .{errstr});
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigurationFailed;
        }

        // Set auto offset reset to earliest for testing
        if (c.rd_kafka_conf_set(conf, "auto.offset.reset", "earliest", &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            std.log.err("Failed to set auto.offset.reset: {s}", .{errstr});
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigurationFailed;
        }

        // Create consumer
        const consumer = c.rd_kafka_new(c.RD_KAFKA_CONSUMER, conf, &errstr, errstr.len);
        if (consumer == null) {
            std.log.err("Failed to create consumer: {s}", .{errstr});
            return KafkaError.ConsumerCreationFailed;
        }

        return Self{
            .consumer = consumer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.consumer) |consumer| {
            // Close consumer
            _ = c.rd_kafka_consumer_close(consumer);
            c.rd_kafka_destroy(consumer);
        }
    }

    pub fn subscribe(self: *Self, topics: []const []const u8) !void {
        const consumer = self.consumer orelse return KafkaError.SubscriptionFailed;

        // Create topic partition list
        const topic_list = c.rd_kafka_topic_partition_list_new(@intCast(topics.len));
        if (topic_list == null) {
            return KafkaError.SubscriptionFailed;
        }
        defer c.rd_kafka_topic_partition_list_destroy(topic_list);

        // Add topics to the list
        for (topics) |topic| {
            const topic_cstr = try self.allocator.dupeZ(u8, topic);
            defer self.allocator.free(topic_cstr);

            _ = c.rd_kafka_topic_partition_list_add(topic_list, topic_cstr.ptr, c.RD_KAFKA_PARTITION_UA);
        }

        // Subscribe to topics
        const result = c.rd_kafka_subscribe(consumer, topic_list);
        if (result != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.log.err("Failed to subscribe to topics: {s}", .{c.rd_kafka_err2str(result)});
            return KafkaError.SubscriptionFailed;
        }
    }

    pub fn poll(self: *Self, timeout_ms: u32) !?KafkaMessage {
        const consumer = self.consumer orelse return KafkaError.PollTimeout;

        const message = c.rd_kafka_consumer_poll(consumer, @intCast(timeout_ms));
        if (message == null) {
            return null; // Timeout, no message
        }
        defer c.rd_kafka_message_destroy(message);

        // Check for errors
        if (message.*.err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            if (message.*.err != c.RD_KAFKA_RESP_ERR__PARTITION_EOF) {
                std.log.err("Consumer error: {s}", .{c.rd_kafka_err2str(message.*.err)});
            }
            return null;
        }

        // Extract message data
        const topic_name = c.rd_kafka_topic_name(message.*.rkt);
        const topic_copy = try self.allocator.dupe(u8, std.mem.span(topic_name));

        const payload_slice = @as([*]const u8, @ptrCast(message.*.payload))[0..message.*.len];
        const payload_copy = try self.allocator.dupe(u8, payload_slice);

        var key_copy: ?[]const u8 = null;
        if (message.*.key != null and message.*.key_len > 0) {
            const key_slice = @as([*]const u8, @ptrCast(message.*.key))[0..message.*.key_len];
            key_copy = try self.allocator.dupe(u8, key_slice);
        }

        return KafkaMessage{
            .topic = topic_copy,
            .partition = message.*.partition,
            .offset = message.*.offset,
            .key = key_copy,
            .payload = payload_copy,
        };
    }

    pub fn commitSync(self: *Self) !void {
        const consumer = self.consumer orelse return;

        const result = c.rd_kafka_commit(consumer, null, 0);
        if (result != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.log.err("Failed to commit offsets: {s}", .{c.rd_kafka_err2str(result)});
        }
    }
};

// Unit tests
test "KafkaConsumer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that we can create and destroy the consumer structure
    // without actually connecting to Kafka
    _ = allocator;
    // TODO: Add mock tests when we have a testing framework set up
}
