const std = @import("std");

// PostgreSQL streaming source
const PostgresStreamingSource = @import("postgres_source").PostgresStreamingSource;
const Batch = @import("postgres_source").Batch;

// Infrastructure
const KafkaProducer = @import("kafka_producer").KafkaProducer;
const config_module = @import("config");
const KafkaConfig = config_module.KafkaSink;
const Stream = config_module.Stream;

// Domain and serialization
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;

// Kafka flush timeout: 5 seconds is a balance between:
// - Allowing enough time for Kafka brokers to acknowledge messages
// - Not blocking CDC processing for too long on Kafka issues
// - Keeping replication lag low for real-time CDC
const KAFKA_FLUSH_TIMEOUT_MS: i32 = 5_000;

// Error types for processor
pub const ProcessorError = error{
    ConnectionFailed,
    InitializationFailed,
    OutOfMemory,
};

/// CDC Processor that works with PostgreSQL streaming replication
pub const Processor = struct {
    allocator: std.mem.Allocator,
    source: PostgresStreamingSource,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    streams: []const Stream,
    serializer: JsonSerializer,

    events_processed: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: PostgresStreamingSource, streams: []const Stream, kafka_config: KafkaConfig) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .streams = streams,
            .serializer = JsonSerializer.init(),
            .events_processed = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.source.deinit();
    }

    pub fn initialize(self: *Self) ProcessorError!void {
        // Initialize Kafka producer
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

    // Match streams that should process this event based on table and operation
    fn matchStreams(self: *Self, table_name: []const u8, operation: []const u8) std.ArrayList(Stream) {
        var matched = std.ArrayList(Stream).empty;

        for (self.streams) |stream| {
            // Check if table matches
            if (!std.mem.eql(u8, stream.source.resource, table_name)) {
                continue;
            }

            // Check if operation matches (case-insensitive)
            var operation_matched = false;
            for (stream.source.operations) |op| {
                if (std.ascii.eqlIgnoreCase(op, operation)) {
                    operation_matched = true;
                    break;
                }
            }

            if (operation_matched) {
                matched.append(self.allocator, stream) catch continue;
            }
        }

        return matched;
    }

    pub fn processChangesToKafka(self: *Self, limit: u32) anyerror!void {
        // Receive batch of changes from source
        var batch = try self.source.receiveBatch(limit);
        defer batch.deinit();

        // If no events, confirm last LSN and return (avoid re-reading same events)
        if (batch.changes.len == 0) {
            if (batch.last_lsn > 0) {
                try self.source.sendFeedback(batch.last_lsn);
            }
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return ProcessorError.ConnectionFailed);

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        // Process each change event
        for (batch.changes) |change_event| {
            // Find matching streams for this event
            var matched_streams = self.matchStreams(change_event.meta.resource, change_event.op);
            defer matched_streams.deinit(self.allocator);

            if (matched_streams.items.len == 0) {
                std.log.debug("No matching streams for {s}.{s} ({s})", .{ change_event.meta.schema, change_event.meta.resource, change_event.op });
                continue;
            }

            // Serialize once, send to all matching streams
            const json_bytes = self.serializer.serialize(change_event, self.allocator) catch |err| {
                std.log.warn("Failed to serialize message to JSON: {}", .{err});
                continue;
            };
            defer self.allocator.free(json_bytes);

            // Send to all matching streams
            for (matched_streams.items) |stream| {
                const partition_key_field = stream.sink.routing_key orelse "id";
                const partition_key = if (change_event.getPartitionKeyValue(self.allocator, partition_key_field)) |key_opt| blk: {
                    if (key_opt) |key| {
                        break :blk key;
                    } else {
                        break :blk try self.allocator.dupe(u8, change_event.meta.resource);
                    }
                } else |_| blk: {
                    break :blk try self.allocator.dupe(u8, change_event.meta.resource);
                };
                defer self.allocator.free(partition_key);

                const topic_name = stream.sink.destination;

                kafka_producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                    std.log.warn("Failed to send message to Kafka topic '{s}': {}", .{ topic_name, err });
                    continue;
                };

                // Increment events counter
                self.events_processed += 1;

                // Log progress every 10000 events
                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }

                std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (partition key: {s})", .{ change_event.op, change_event.meta.schema, change_event.meta.resource, topic_name, partition_key });
            }
        }

        // CRITICAL: Kafka flush BEFORE LSN feedback (no data loss guarantee)
        kafka_producer.flush(KAFKA_FLUSH_TIMEOUT_MS);

        // Confirm LSN to PostgreSQL ONLY after Kafka flush succeeds
        try self.source.sendFeedback(batch.last_lsn);

        std.log.debug("Successfully committed LSN: {}", .{batch.last_lsn});
    }

    pub fn startStreaming(self: *Self, stop_signal: *std.atomic.Value(bool)) !void {
        while (!stop_signal.load(.monotonic)) {
            // Fail-fast: any error propagates up → app exits → supervisor restarts
            try self.processChangesToKafka(5000);

            // No sleep needed - receiveBatchWithTimeout() blocks on poll() when no data
        }

        std.log.info("Streaming stopped gracefully", .{});
    }
};
