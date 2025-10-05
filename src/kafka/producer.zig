const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

const KafkaError = error{
    ProducerCreationFailed,
    TopicCreationFailed,
    MessageSendFailed,
    ConfigurationFailed,
    ConnectionTestFailed,
};

pub const KafkaProducer = struct {
    producer: ?*c.rd_kafka_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn setConfig(conf: ?*c.rd_kafka_conf_t, key: [*:0]const u8, value: [*:0]const u8, errstr: *[512]u8) !void {
        if (c.rd_kafka_conf_set(conf, key, value, errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            std.log.warn("Failed to set {s}: {s}", .{ key, errstr });
            return KafkaError.ConfigurationFailed;
        }
    }

    pub fn init(allocator: std.mem.Allocator, brokers: []const u8) !Self {
        var errstr: [512]u8 = undefined;

        // Create configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) {
            return KafkaError.ConfigurationFailed;
        }
        errdefer c.rd_kafka_conf_destroy(conf);

        // Set bootstrap servers
        const brokers_cstr = try allocator.dupeZ(u8, brokers);
        defer allocator.free(brokers_cstr);

        try setConfig(conf, "bootstrap.servers", brokers_cstr.ptr, &errstr);

        // Connection timeout settings (fail-fast on startup)
        try setConfig(conf, "socket.connection.setup.timeout.ms", "10000", &errstr);

        // Request timeout (15s instead of default 30s)
        try setConfig(conf, "request.timeout.ms", "15000", &errstr);

        // Delivery timeout (30s instead of default 120s)
        try setConfig(conf, "delivery.timeout.ms", "30000", &errstr);

        // Retry settings (3 retries with 500ms backoff)
        try setConfig(conf, "retries", "3", &errstr);
        try setConfig(conf, "retry.backoff.ms", "500", &errstr);

        // Reliability settings
        try setConfig(conf, "enable.idempotence", "true", &errstr);
        try setConfig(conf, "acks", "all", &errstr);
        try setConfig(conf, "max.in.flight.requests.per.connection", "5", &errstr);

        // Create producer (takes ownership of conf)
        const producer = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, conf, &errstr, errstr.len);
        if (producer == null) {
            std.log.warn("Failed to create producer: {s}", .{errstr});
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
            std.log.warn("Failed to create topic: {s}", .{topic_name});
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
            std.log.warn("Failed to produce message: {s}", .{c.rd_kafka_err2str(errno)});
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

    pub fn testConnection(self: *Self) !void {
        const producer = self.producer orelse return KafkaError.ConnectionTestFailed;

        std.log.debug("Testing Kafka connection...", .{});

        const timeout_ms: i32 = 10000;
        var metadata: ?*const c.rd_kafka_metadata_t = null;

        const err = c.rd_kafka_metadata(producer, 1, null, @ptrCast(&metadata), timeout_ms);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.log.warn("Kafka connection test failed: {s}", .{c.rd_kafka_err2str(err)});
            return KafkaError.ConnectionTestFailed;
        }
        defer c.rd_kafka_metadata_destroy(metadata);

        if (metadata) |meta| {
            const broker_count = meta.*.broker_cnt;
            if (broker_count == 0) {
                std.log.warn("No Kafka brokers available", .{});
                return KafkaError.ConnectionTestFailed;
            }

            std.log.debug("Kafka connection successful: {d} broker(s) available", .{broker_count});
        } else {
            return KafkaError.ConnectionTestFailed;
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
    // Mock tests can be added when a testing framework is set up
}
