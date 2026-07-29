const std = @import("std");
const c = @import("c"); // C bindings (build-system translate-c)
const constants = @import("constants");

const KafkaError = error{
    ProducerCreationFailed,
    TopicCreationFailed,
    MessageSendFailed,
    QueueFull,
    FlushFailed,
    ConfigurationFailed,
    ConnectionTestFailed,
};

/// A Kafka message: optional partition key and payload.
pub const Message = struct {
    key: ?[]const u8,
    payload: []const u8,
};

/// Broker security options mapped onto librdkafka config keys. The password is
/// the resolved secret, not an environment variable name.
pub const Security = struct {
    protocol: []const u8,
    sasl_mechanism: ?[]const u8 = null,
    sasl_username: ?[]const u8 = null,
    sasl_password: ?[]const u8 = null,
    ssl_ca_location: ?[]const u8 = null,
};

/// Minimal librdkafka producer wrapper.
pub const KafkaProducer = struct {
    producer: ?*c.rd_kafka_t,
    allocator: std.mem.Allocator,
    topics: std.StringHashMap(*c.rd_kafka_topic_t),
    // Heap-allocated so its address stays stable when the struct is moved into
    // the Processor: it is handed to librdkafka as the delivery-callback opaque.
    delivery_errors: *std.atomic.Value(u64),

    const Self = @This();

    // librdkafka's delivery report, served during poll/flush on the calling
    // thread. A non-zero err means the message permanently failed, so count it.
    fn deliveryReportCallback(
        rk: ?*c.rd_kafka_t,
        rkmessage: [*c]const c.rd_kafka_message_t,
        opaque_ctx: ?*anyopaque,
    ) callconv(.c) void {
        _ = rk;
        if (rkmessage == null or opaque_ctx == null) return;
        if (rkmessage[0].err == c.RD_KAFKA_RESP_ERR_NO_ERROR) return;

        const counter: *std.atomic.Value(u64) = @ptrCast(@alignCast(opaque_ctx.?));
        _ = counter.fetchAdd(1, .monotonic);
        std.log.warn("Kafka delivery failed: {s}", .{c.rd_kafka_err2str(rkmessage[0].err)});
    }

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

    // Set a config key whose value is a runtime slice, duped to a C string for librdkafka.
    fn setConfigSlice(allocator: std.mem.Allocator, conf: ?*c.rd_kafka_conf_t, key: [*:0]const u8, value: []const u8, errstr: *[512]u8) !void {
        const value_cstr = try allocator.dupeZ(u8, value);
        defer allocator.free(value_cstr);
        try setConfig(conf, key, value_cstr.ptr, errstr);
    }

    fn applySecurity(allocator: std.mem.Allocator, conf: ?*c.rd_kafka_conf_t, security: Security, errstr: *[512]u8) !void {
        try setConfigSlice(allocator, conf, "security.protocol", security.protocol, errstr);
        if (security.sasl_mechanism) |mechanism| {
            try setConfigSlice(allocator, conf, "sasl.mechanism", mechanism, errstr);
        }
        if (security.sasl_username) |username| {
            try setConfigSlice(allocator, conf, "sasl.username", username, errstr);
        }
        if (security.sasl_password) |password| {
            try setConfigSlice(allocator, conf, "sasl.password", password, errstr);
        }
        if (security.ssl_ca_location) |ca_location| {
            try setConfigSlice(allocator, conf, "ssl.ca.location", ca_location, errstr);
        }
    }

    pub fn init(allocator: std.mem.Allocator, brokers: []const u8, security: ?Security) !Self {
        var errstr: [512]u8 = undefined;

        // Create configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) {
            return KafkaError.ConfigurationFailed;
        }
        errdefer c.rd_kafka_conf_destroy(conf);

        // Set custom log callback for full control over librdkafka logs
        c.rd_kafka_conf_set_log_cb(conf, logCallback);

        // Without dr_msg_cb, librdkafka discards delivery reports and flush()
        // reports success even for messages that permanently failed. Count them
        // via the callback opaque so the worker won't confirm unsent data.
        const delivery_errors = try allocator.create(std.atomic.Value(u64));
        errdefer allocator.destroy(delivery_errors);
        delivery_errors.* = std.atomic.Value(u64).init(0);
        c.rd_kafka_conf_set_dr_msg_cb(conf, deliveryReportCallback);
        c.rd_kafka_conf_set_opaque(conf, delivery_errors);

        // Set bootstrap servers
        try setConfigSlice(allocator, conf, "bootstrap.servers", brokers, &errstr);

        // Broker security (TLS/SASL); plaintext when unset
        if (security) |sec| {
            try applySecurity(allocator, conf, sec, &errstr);
        }

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
            .delivery_errors = delivery_errors,
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
            std.log.debug("producer.deinit: flush (timeout {d}ms)", .{constants.CDC.KAFKA_FLUSH_TIMEOUT_MS});
            _ = c.rd_kafka_flush(producer, constants.CDC.KAFKA_FLUSH_TIMEOUT_MS);
            std.log.debug("producer.deinit: flush returned, destroying", .{});
            c.rd_kafka_destroy(producer);
            std.log.debug("producer.deinit: destroyed", .{});
        }

        // After rd_kafka_destroy: no callback can touch the counter anymore.
        self.allocator.destroy(self.delivery_errors);
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

    /// Batch-produce messages to a topic. Reserved for future optimizations.
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
            // A full local queue is backpressure, not a failure: the processor
            // drains delivery reports and retries. Keep it a distinct error.
            if (errno == c.RD_KAFKA_RESP_ERR__QUEUE_FULL) return KafkaError.QueueFull;
            std.log.warn("Failed to produce message: {s}", .{c.rd_kafka_err2str(errno)});
            return KafkaError.MessageSendFailed;
        }
    }

    pub fn poll(self: *Self) void {
        const producer = self.producer orelse return;
        _ = c.rd_kafka_poll(producer, 0);
    }

    // Blocking drain used only for backpressure: wait up to timeout_ms while
    // serving delivery reports, so the queue can free up before we retry.
    pub fn drainFor(self: *Self, timeout_ms: i32) void {
        const producer = self.producer orelse return;
        _ = c.rd_kafka_poll(producer, timeout_ms);
    }

    pub fn flush(self: *Self, timeout_ms: i32) !void {
        const producer = self.producer orelse return KafkaError.FlushFailed;

        const err = c.rd_kafka_flush(producer, timeout_ms);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.log.warn("Kafka flush failed: {s}", .{c.rd_kafka_err2str(err)});
            return KafkaError.FlushFailed;
        }
    }

    /// Count of messages that permanently failed delivery over the producer's
    /// lifetime, as reported by the delivery callback. Monotonic: a non-zero
    /// value means the at-least-once guarantee is broken and demands a restart.
    pub fn deliveryErrorCount(self: *Self) u64 {
        return self.delivery_errors.load(.monotonic);
    }

    /// Whether the producer hit an unrecoverable error. Idempotent-producer
    /// fatal errors surface only here, not on individual messages. Logs the
    /// librdkafka reason when fatal; the producer must be recreated after.
    pub fn fatalError(self: *Self) bool {
        const producer = self.producer orelse return false;

        var errstr: [512]u8 = undefined;
        const err = c.rd_kafka_fatal_error(producer, &errstr, errstr.len);
        if (err == c.RD_KAFKA_RESP_ERR_NO_ERROR) return false;

        std.log.err("Kafka producer fatal error: {s}", .{std.mem.sliceTo(&errstr, 0)});
        return true;
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
test "delivery callback counts a permanently failed message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock cluster to point the producer at; its own rd_kafka_t only hosts it.
    var errstr: [512]u8 = undefined;
    const mock_rk = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, c.rd_kafka_conf_new(), &errstr, errstr.len);
    try testing.expect(mock_rk != null);
    defer c.rd_kafka_destroy(mock_rk);

    const mcluster = c.rd_kafka_mock_cluster_new(mock_rk, 1);
    try testing.expect(mcluster != null);
    defer c.rd_kafka_mock_cluster_destroy(mcluster);

    const bootstraps = std.mem.span(c.rd_kafka_mock_cluster_bootstraps(mcluster));
    try testing.expect(c.rd_kafka_mock_topic_create(mcluster, "t", 1, 1) == c.RD_KAFKA_RESP_ERR_NO_ERROR);

    // Reject the next Produce with a non-retriable error, so the message fails
    // delivery at once instead of retrying for delivery.timeout.ms. The ApiKey
    // for ProduceRequest is 0; RD_KAFKAP_* names are not in the public headers.
    const produce_api_key: i16 = 0;
    c.rd_kafka_mock_push_request_errors(mcluster, produce_api_key, 1, c.RD_KAFKA_RESP_ERR_TOPIC_AUTHORIZATION_FAILED);

    var producer = try KafkaProducer.init(allocator, bootstraps, null);
    defer producer.deinit();

    try producer.sendMessage("t", "k", "{}");
    // flush serves the delivery callback on this thread, counting the failure.
    producer.flush(5000) catch {};

    try testing.expect(producer.deliveryErrorCount() > 0);
}

test "sendMessage reports a full queue as error.QueueFull" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var errstr: [512]u8 = undefined;
    const mock_rk = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, c.rd_kafka_conf_new(), &errstr, errstr.len);
    try testing.expect(mock_rk != null);
    defer c.rd_kafka_destroy(mock_rk);

    const mcluster = c.rd_kafka_mock_cluster_new(mock_rk, 1);
    try testing.expect(mcluster != null);
    defer c.rd_kafka_mock_cluster_destroy(mcluster);

    const bootstraps = std.mem.span(c.rd_kafka_mock_cluster_bootstraps(mcluster));
    try testing.expect(c.rd_kafka_mock_topic_create(mcluster, "t", 1, 1) == c.RD_KAFKA_RESP_ERR_NO_ERROR);

    // Broker down: nothing drains, so the local queue fills and rd_kafka_produce
    // returns QUEUE_FULL. sendMessage must surface that as the distinct
    // error.QueueFull (backpressure), not MessageSendFailed.
    c.rd_kafka_mock_broker_set_down(mcluster, 1);

    var producer = try KafkaProducer.init(allocator, bootstraps, null);
    defer producer.deinit();
    // The queue holds up to queue.buffering.max.messages undeliverable messages;
    // purge before deinit so the final flush doesn't block on the downed broker.
    defer _ = c.rd_kafka_purge(producer.producer.?, c.RD_KAFKA_PURGE_F_QUEUE | c.RD_KAFKA_PURGE_F_INFLIGHT);

    // Fill past the default 100k queue; QueueFull must arrive before this bound.
    var got_queue_full = false;
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        producer.sendMessage("t", null, "{}") catch |err| {
            try testing.expectEqual(error.QueueFull, err);
            got_queue_full = true;
            break;
        };
    }
    try testing.expect(got_queue_full);
}
