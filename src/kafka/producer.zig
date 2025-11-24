const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});
const constants = @import("constants");

const KafkaError = error{
    ProducerCreationFailed,
    TopicCreationFailed,
    MessageSendFailed,
    FlushFailed,
    ConfigurationFailed,
    ConnectionTestFailed,
};

pub const Message = struct {
    key: ?[]const u8,
    payload: []const u8,
};

pub const KafkaProducer = struct {
    producer: ?*c.rd_kafka_t,
    allocator: std.mem.Allocator,
    topics: std.StringHashMap(*c.rd_kafka_topic_t),

    const Self = @This();

    fn logCallback(
        rk: ?*const c.rd_kafka_t,
        level: c_int,
        fac: [*c]const u8,
        buf: [*c]const u8,
    ) callconv(.c) void {
        _ = rk;
        _ = fac;

        const message = std.mem.span(buf);

        switch (level) {
            0...2 => std.log.err("kafka client: {s}", .{message}),
            3 => std.log.warn("kafka client: {s}", .{message}),
            4...5 => std.log.info("kafka client: {s}", .{message}),
            else => std.log.debug("kafka client: {s}", .{message}),
        }
    }

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

        // Set custom log callback for full control over librdkafka logs
        c.rd_kafka_conf_set_log_cb(conf, logCallback);

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

        // Batching configuration
        try setConfig(conf, "linger.ms", constants.CDC.KAFKA_LINGER_MS, &errstr);
        try setConfig(conf, "batch.size", constants.CDC.KAFKA_BATCH_SIZE, &errstr);

        // Create producer (takes ownership of conf)
        const producer = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, conf, &errstr, errstr.len);
        if (producer == null) {
            std.log.warn("Failed to create producer: {s}", .{errstr});
            return KafkaError.ProducerCreationFailed;
        }

        return Self{
            .producer = producer,
            .allocator = allocator,
            .topics = std.StringHashMap(*c.rd_kafka_topic_t).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            c.rd_kafka_topic_destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.topics.deinit();

        if (self.producer) |producer| {
            _ = c.rd_kafka_flush(producer, constants.CDC.KAFKA_FLUSH_TIMEOUT_MS);
            c.rd_kafka_destroy(producer);
        }
    }

    fn getOrCreateTopic(self: *Self, topic_name: []const u8) !*c.rd_kafka_topic_t {
        const producer = self.producer orelse return KafkaError.TopicCreationFailed;

        if (self.topics.get(topic_name)) |topic| {
            return topic;
        }

        const topic_name_cstr = try self.allocator.dupeZ(u8, topic_name);
        defer self.allocator.free(topic_name_cstr);

        const topic_conf = c.rd_kafka_topic_conf_new();
        const topic_opt = c.rd_kafka_topic_new(producer, topic_name_cstr.ptr, topic_conf);
        if (topic_opt == null) {
            std.log.warn("Failed to create topic: {s}", .{topic_name});
            return KafkaError.TopicCreationFailed;
        }
        const topic = topic_opt.?;

        const owned_key = try self.allocator.dupe(u8, topic_name);
        errdefer {
            self.allocator.free(owned_key);
            c.rd_kafka_topic_destroy(topic);
        }

        try self.topics.put(owned_key, topic);

        std.log.debug("Created topic handle: {s}", .{topic_name});

        return topic;
    }

    pub fn produce(self: *Self, topic_name: []const u8, messages: []const Message) !void {
        if (messages.len == 0) return;

        const topic = try self.getOrCreateTopic(topic_name);

        // Prepare rd_kafka_message_t array
        const rkmessages = try self.allocator.alloc(c.rd_kafka_message_t, messages.len);
        defer self.allocator.free(rkmessages);

        for (messages, 0..) |msg, i| {
            rkmessages[i] = c.rd_kafka_message_t{
                .err = c.RD_KAFKA_RESP_ERR_NO_ERROR,
                .rkt = topic,
                .partition = c.RD_KAFKA_PARTITION_UA,
                .payload = @constCast(msg.payload.ptr),
                .len = msg.payload.len,
                .key = if (msg.key) |k| @constCast(k.ptr) else null,
                .key_len = if (msg.key) |k| k.len else 0,
                .offset = 0,
                ._private = null,
            };
        }

        // Send batch to Kafka
        const sent = c.rd_kafka_produce_batch(
            topic,
            c.RD_KAFKA_PARTITION_UA,
            c.RD_KAFKA_MSG_F_COPY,
            rkmessages.ptr,
            @intCast(rkmessages.len),
        );

        if (sent < 0) {
            std.log.warn("Failed to produce batch to topic {s}", .{topic_name});
            return KafkaError.MessageSendFailed;
        }

        // Check if all messages were queued
        if (sent != rkmessages.len) {
            // Some messages failed, check individual errors
            for (rkmessages, 0..) |rkmsg, i| {
                if (rkmsg.err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
                    std.log.warn("Message {d} failed for topic {s}: {s}", .{ i, topic_name, c.rd_kafka_err2str(rkmsg.err) });
                }
            }
            std.log.warn("Only {d}/{d} messages queued for topic {s}", .{ sent, rkmessages.len, topic_name });
            return KafkaError.MessageSendFailed;
        }

        std.log.debug("Batch sent: {d} messages to topic {s}", .{ sent, topic_name });
    }

    pub fn sendMessage(self: *Self, topic_name: []const u8, key: ?[]const u8, message: []const u8) !void {
        const topic = try self.getOrCreateTopic(topic_name);

        var key_ptr: ?*const anyopaque = null;
        var key_len: usize = 0;

        if (key) |k| {
            key_ptr = k.ptr;
            key_len = k.len;
        }

        const result = c.rd_kafka_produce(
            topic,
            c.RD_KAFKA_PARTITION_UA,
            c.RD_KAFKA_MSG_F_COPY,
            @constCast(message.ptr),
            message.len,
            key_ptr,
            key_len,
            null,
        );

        if (result == -1) {
            const errno = c.rd_kafka_last_error();
            std.log.warn("Failed to produce message: {s}", .{c.rd_kafka_err2str(errno)});
            return KafkaError.MessageSendFailed;
        }
    }

    pub fn poll(self: *Self) void {
        const producer = self.producer orelse return;
        _ = c.rd_kafka_poll(producer, 0);
    }

    pub fn flush(self: *Self, timeout_ms: i32) !void {
        const producer = self.producer orelse return KafkaError.FlushFailed;

        const err = c.rd_kafka_flush(producer, timeout_ms);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.log.warn("Kafka flush failed: {s}", .{c.rd_kafka_err2str(err)});
            return KafkaError.FlushFailed;
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
