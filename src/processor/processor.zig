const std = @import("std");

const PostgresSource = @import("postgres_source").PostgresSource;
const Batch = @import("postgres_source").Batch;

const kafka_producer = @import("kafka_producer");
const KafkaProducer = kafka_producer.KafkaProducer;
const config_module = @import("config");
const KafkaConfig = config_module.KafkaSink;
const Stream = config_module.Stream;

const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;
const constants = @import("constants");

pub const ProcessorError = error{
    ConnectionFailed,
    InitializationFailed,
    OutOfMemory,
};

pub fn matchStreams(allocator: std.mem.Allocator, streams: []const Stream, table_name: []const u8, operation: []const u8) !std.ArrayList(Stream) {
    var matched = std.ArrayList(Stream).empty;

    for (streams) |stream| {
        if (!std.mem.eql(u8, stream.source.resource, table_name)) {
            continue;
        }

        for (stream.source.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, operation)) {
                try matched.append(allocator, stream);
                break;
            }
        }
    }

    return matched;
}

/// CDC Processor that works with PostgreSQL streaming replication
pub const Processor = struct {
    allocator: std.mem.Allocator,
    source: PostgresSource,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    streams: []const Stream,
    serializer: JsonSerializer,

    events_processed: usize,
    last_flush_time: i64,
    pending_lsn: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: PostgresSource, streams: []const Stream, kafka_config: KafkaConfig) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .streams = streams,
            .serializer = JsonSerializer.init(),
            .events_processed = 0,
            .last_flush_time = std.time.timestamp(),
            .pending_lsn = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.source.deinit();
    }

    pub fn initialize(self: *Self) ProcessorError!void {
        const brokers_str = try std.mem.join(self.allocator, ",", self.kafka_config.brokers);
        defer self.allocator.free(brokers_str);

        self.kafka_producer = KafkaProducer.init(self.allocator, brokers_str) catch |err| {
            std.log.warn("Failed to initialize Kafka producer: {}", .{err});
            return ProcessorError.ConnectionFailed;
        };

        // Test Kafka connection at startup (fail-fast if unavailable)
        var producer = &self.kafka_producer.?;
        producer.testConnection() catch |err| {
            std.log.warn("Kafka connection test failed: {}", .{err});
            return ProcessorError.ConnectionFailed;
        };

        std.log.info("Processor initialized successfully", .{});
    }

    pub fn processChangesToKafka(self: *Self, batch_allocator: std.mem.Allocator, limit: u32) !void {
        var batch = try self.source.receiveBatch(batch_allocator, limit);
        defer batch.deinit();

        if (batch.changes.len == 0) {
            return;
        }

        var producer = &(self.kafka_producer orelse return ProcessorError.ConnectionFailed);

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        for (batch.changes) |change_event| {
            var matched = try matchStreams(batch_allocator, self.streams, change_event.meta.resource, change_event.op);
            defer matched.deinit(batch_allocator);

            if (matched.items.len == 0) {
                std.log.debug("No matching streams for {s}.{s} ({s})", .{
                    change_event.meta.schema,
                    change_event.meta.resource,
                    change_event.op,
                });
                continue;
            }

            const json_bytes = try self.serializer.serialize(change_event, batch_allocator);

            for (matched.items) |stream| {
                const topic_name = stream.sink.destination;
                const partition_key = try self.getPartitionKey(batch_allocator, change_event, stream);

                try producer.sendMessage(topic_name, partition_key, json_bytes);

                self.events_processed += 1;
                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }

                std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (key: {s})", .{
                    change_event.op,
                    change_event.meta.schema,
                    change_event.meta.resource,
                    topic_name,
                    partition_key,
                });
            }
        }

        producer.poll();

        if (batch.last_lsn > 0) {
            self.pending_lsn = batch.last_lsn;
        }

        const now = std.time.timestamp();
        if (now - self.last_flush_time >= constants.CDC.KAFKA_FLUSH_INTERVAL_SEC) {
            try producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS);

            if (self.pending_lsn > 0) {
                try self.source.sendFeedback(self.pending_lsn);
                std.log.debug("Successfully committed LSN: {}", .{self.pending_lsn});
                self.pending_lsn = 0;
            }

            self.last_flush_time = now;
        }
    }

    fn getPartitionKey(
        self: *Self,
        allocator: std.mem.Allocator,
        change_event: ChangeEvent,
        stream: Stream,
    ) ![]const u8 {
        _ = self;

        const key_field = stream.sink.routing_key orelse "id";

        if (change_event.getPartitionKeyValue(allocator, key_field)) |key_opt| {
            if (key_opt) |key| {
                return key;
            }
        } else |_| {}

        return try allocator.dupe(u8, change_event.meta.resource);
    }

    pub fn startStreaming(self: *Self, stop_signal: *std.atomic.Value(bool)) !void {
        while (!stop_signal.load(.monotonic)) {
            var batch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer batch_arena.deinit();

            const batch_alloc = batch_arena.allocator();

            try self.processChangesToKafka(batch_alloc, constants.CDC.BATCH_SIZE);
        }

        // Final flush on graceful shutdown
        if (self.kafka_producer) |*producer| {
            try producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS);

            if (self.pending_lsn > 0) {
                try self.source.sendFeedback(self.pending_lsn);
                std.log.debug("Final LSN commit: {}", .{self.pending_lsn});
            }
        }

        std.log.info("Streaming stopped gracefully", .{});
    }
};
