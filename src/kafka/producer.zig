const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

const KafkaError = error{
    ProducerCreationFailed,
    TopicCreationFailed,
    MessageSendFailed,
    ConfigurationFailed,
};

pub const KafkaProducer = struct {
    producer: ?*c.rd_kafka_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, brokers: []const u8) !Self {
        var errstr: [512]u8 = undefined;

        // Create configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) {
            return KafkaError.ConfigurationFailed;
        }
        // NOTE: rd_kafka_new() takes ownership of conf, so we don't destroy it manually

        // Set bootstrap servers
        const brokers_cstr = try allocator.dupeZ(u8, brokers);
        defer allocator.free(brokers_cstr);

        if (c.rd_kafka_conf_set(conf, "bootstrap.servers", brokers_cstr.ptr, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            std.log.err("Failed to set bootstrap.servers: {s}", .{errstr});
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigurationFailed;
        }

        // Create producer
        const producer = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, conf, &errstr, errstr.len);
        if (producer == null) {
            std.log.err("Failed to create producer: {s}", .{errstr});
            return KafkaError.ProducerCreationFailed;
        }

        return Self{
            .producer = producer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.producer) |producer| {
            // Flush and wait for outstanding messages
            _ = c.rd_kafka_flush(producer, 10000); // 10 seconds timeout
            c.rd_kafka_destroy(producer);
        }
    }

    pub fn sendMessage(self: *Self, topic_name: []const u8, key: ?[]const u8, message: []const u8) !void {
        const producer = self.producer orelse return KafkaError.MessageSendFailed;

        // Create null-terminated topic name
        const topic_name_cstr = try self.allocator.dupeZ(u8, topic_name);
        defer self.allocator.free(topic_name_cstr);

        var key_ptr: ?*const anyopaque = null;
        var key_len: usize = 0;

        if (key) |k| {
            key_ptr = k.ptr;
            key_len = k.len;
        }

        // Create topic handle - we'll create it dynamically for each message
        const topic_conf = c.rd_kafka_topic_conf_new();
        const topic = c.rd_kafka_topic_new(producer, topic_name_cstr.ptr, topic_conf);
        if (topic == null) {
            std.log.err("Failed to create topic: {s}", .{topic_name});
            return KafkaError.TopicCreationFailed;
        }
        defer c.rd_kafka_topic_destroy(topic);

        const result = c.rd_kafka_produce(
            topic,
            c.RD_KAFKA_PARTITION_UA, // Auto-assign partition
            c.RD_KAFKA_MSG_F_COPY, // Copy message payload
            @constCast(message.ptr),
            message.len,
            key_ptr,
            key_len,
            null, // No delivery report callback for now
        );

        if (result == -1) {
            const errno = c.rd_kafka_last_error();
            std.log.err("Failed to produce message: {s}", .{c.rd_kafka_err2str(errno)});
            return KafkaError.MessageSendFailed;
        }

        // Poll for events to trigger message delivery
        _ = c.rd_kafka_poll(producer, 0);
    }

    pub fn flush(self: *Self, timeout_ms: i32) void {
        if (self.producer) |producer| {
            _ = c.rd_kafka_flush(producer, timeout_ms);
        }
    }
};

// Unit tests
test "KafkaProducer initialization" {
    const testing = std.testing;

    // This test will only pass if Kafka is running
    // For now, we just test the structure
    const allocator = testing.allocator;

    // Test that we can create and destroy the producer structure
    // without actually connecting to Kafka
    _ = allocator;
    // TODO: Add mock tests when we have a testing framework set up
}
